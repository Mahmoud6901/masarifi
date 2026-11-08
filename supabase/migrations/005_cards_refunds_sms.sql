-- Cards, refunds and SMS capture. Apply after 001-004.
--
-- One Shortcut reports both Apple Pay taps (Wallet automation) and bank SMS
-- (Message automation). capture_payment() is the single, atomic entry point:
-- it authenticates the ingest token, finds or creates the card, merges the
-- same payment reported by both automations, and applies refunds.

create table public.cards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  -- Name Apple Wallet shows, e.g. "AlRajhi mada-Visa Classic".
  wallet_name text check (wallet_name is null or pg_catalog.char_length(wallet_name) between 1 and 120),
  -- Bank and last four digits read from SMS.
  bank text check (bank is null or pg_catalog.char_length(bank) between 1 and 80),
  last4 text check (last4 is null or last4 ~ '^[0-9]{4}$'),
  nickname text check (nickname is null or pg_catalog.char_length(nickname) between 1 and 60),
  created_at timestamptz not null default pg_catalog.now(),
  check (wallet_name is not null or last4 is not null),
  unique (id, user_id)
);
create unique index cards_user_wallet_uidx on public.cards (user_id, wallet_name) where wallet_name is not null;
create unique index cards_user_last4_uidx on public.cards (user_id, last4) where last4 is not null;

alter table public.expenses
  add column card_id uuid,
  add column refunded_amount numeric(14,3) not null default 0,
  -- True once both automations reported this payment (Wallet + SMS).
  add column matched boolean not null default false,
  -- The composite key keeps an expense from pointing at another user's card.
  add constraint expenses_card_fk foreign key (card_id, user_id)
    references public.cards (id, user_id) on delete set null (card_id),
  add constraint expenses_refunded_amount_check
    check (refunded_amount >= 0 and refunded_amount <= amount);
alter table public.expenses drop constraint if exists expenses_source_check;
alter table public.expenses
  add constraint expenses_source_check check (source in ('apple_pay', 'manual', 'sms'));
create index expenses_user_card on public.expenses (user_id, card_id);

-- Every refund SMS is kept once, matched to a purchase or not.
create table public.refunds (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  expense_id uuid references public.expenses on delete set null,
  card_id uuid,
  amount numeric(14,3) not null check (amount > 0 and amount <= 99999999999.999),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  merchant text not null default '' check (pg_catalog.char_length(merchant) <= 200),
  refunded_at timestamptz not null,
  created_at timestamptz not null default pg_catalog.now(),
  foreign key (card_id, user_id) references public.cards (id, user_id) on delete set null (card_id)
);
-- A resent refund SMS (same amount and time) applies once.
create unique index refunds_once_uidx on public.refunds (user_id, currency, amount, refunded_at);

-- Each purchase report as sent (source, amount, merchant, time). Retries are
-- recognised here even after a report was merged into the other source's
-- expense, whose merchant and source differ from the retried report.
create table public.capture_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  expense_id uuid not null references public.expenses on delete cascade,
  source text not null check (source in ('apple_pay', 'sms')),
  amount numeric(14,3) not null,
  currency text not null,
  merchant text not null,
  reported_at timestamptz not null,
  created_at timestamptz not null default pg_catalog.now()
);
create index capture_reports_lookup on public.capture_reports (user_id, source, amount, reported_at);

alter table public.cards enable row level security;
alter table public.refunds enable row level security;
alter table public.capture_reports enable row level security;
create policy "own cards" on public.cards
  for select to authenticated using (auth.uid() = user_id);
create policy "rename own cards" on public.cards
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own refunds" on public.refunds
  for select to authenticated using (auth.uid() = user_id);

revoke all privileges on table public.cards, public.refunds from public, anon, authenticated;
grant select on table public.cards, public.refunds to authenticated;
grant update (nickname) on table public.cards to authenticated;
grant all privileges on table public.cards, public.refunds to service_role;
revoke all privileges on table public.capture_reports from public, anon, authenticated;
grant all privileges on table public.capture_reports to service_role;

create function public.capture_payment(
  p_user_id uuid,
  p_token_hash text,
  p_kind text,            -- 'purchase' | 'refund'
  p_source text,          -- 'apple_pay' | 'sms'
  p_amount numeric,
  p_currency text,
  p_merchant text,
  p_spent_at timestamptz,
  p_category text,
  p_wallet_name text default null,
  p_bank text default null,
  p_last4 text default null
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  profile_token_hash text;
  profile_currency text;
  resolved_currency text;
  stored_amount numeric(14,3);
  card_row public.cards%rowtype;
  other_card public.cards%rowtype;
  card_uuid uuid;
  found_id uuid;
  found_card uuid;
  inserted_id uuid;
  refund_id uuid;
begin
  if p_user_id is null or p_token_hash is null or p_amount is null or p_spent_at is null
     or p_kind is null or p_kind not in ('purchase', 'refund')
     or p_source is null or p_source not in ('apple_pay', 'sms')
     or p_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'Invalid capture payload' using errcode = '22023';
  end if;
  if p_amount::text in ('NaN', 'Infinity', '-Infinity') or p_amount < 0 or p_amount > 99999999999.999
     or (p_kind = 'refund' and p_amount = 0) then
    raise exception 'Invalid capture amount' using errcode = '22023';
  end if;
  if p_currency is not null and p_currency !~ '^[A-Z]{3}$' then
    raise exception 'Invalid capture currency' using errcode = '22023';
  end if;
  if not pg_catalog.isfinite(p_spent_at) then
    raise exception 'Invalid capture time' using errcode = '22023';
  end if;
  if p_kind = 'purchase' and (
       p_merchant is null or p_category is null
       or p_merchant <> pg_catalog.btrim(p_merchant, E' \t\n\r\f' || pg_catalog.chr(11))
       or pg_catalog.char_length(p_merchant) not between 1 and 200
       or p_category not in ('food', 'groceries', 'transport', 'health', 'bills', 'shopping', 'entertainment', 'other')) then
    raise exception 'Invalid capture merchant' using errcode = '22023';
  end if;
  if p_merchant is not null and pg_catalog.char_length(p_merchant) > 200 then
    raise exception 'Invalid capture merchant' using errcode = '22023';
  end if;
  if p_last4 is not null and p_last4 !~ '^[0-9]{4}$' then
    raise exception 'Invalid card digits' using errcode = '22023';
  end if;

  -- Lock the profile: serializes captures per user and rechecks the token.
  select profile.ingest_token_hash, profile.currency into profile_token_hash, profile_currency
  from public.profiles as profile where profile.id = p_user_id for update;
  if not found or profile_token_hash is distinct from p_token_hash then
    raise exception 'Invalid ingest credentials' using errcode = '28000';
  end if;
  resolved_currency := coalesce(p_currency, profile_currency);
  if p_amount <> pg_catalog.trunc(p_amount, case when resolved_currency in ('KWD', 'BHD', 'OMR') then 3 else 2 end) then
    raise exception 'Amount exceeds currency precision' using errcode = '22023';
  end if;
  stored_amount := p_amount::numeric(14,3);

  -- Find or create the card. SMS identifies it by last four digits, Wallet
  -- by its display name; the two are linked when one payment carries both.
  if p_last4 is not null then
    select * into card_row from public.cards where user_id = p_user_id and last4 = p_last4;
  elsif p_wallet_name is not null then
    select * into card_row from public.cards where user_id = p_user_id and wallet_name = p_wallet_name;
  end if;
  if card_row.id is null and (p_last4 is not null or p_wallet_name is not null) then
    insert into public.cards (user_id, wallet_name, bank, last4)
    values (p_user_id, case when p_last4 is null then p_wallet_name end, p_bank, p_last4)
    returning * into card_row;
  elsif card_row.id is not null and card_row.bank is null and p_bank is not null then
    update public.cards set bank = p_bank where id = card_row.id returning * into card_row;
  end if;
  card_uuid := card_row.id;

  if p_kind = 'refund' then
    select refund.id into refund_id from public.refunds as refund
    where refund.user_id = p_user_id and refund.currency = resolved_currency
      and refund.amount = stored_amount and refund.refunded_at = p_spent_at;
    if refund_id is not null then
      return pg_catalog.jsonb_build_object('ok', true, 'kind', 'refund', 'duplicate', true, 'id', refund_id);
    end if;
    -- The most likely original: unrefunded balance covers the refund, within
    -- 60 days, same card when both are known; exact amount and newest first.
    select expense.id into found_id
    from public.expenses as expense
    where expense.user_id = p_user_id and expense.currency = resolved_currency
      and expense.amount - expense.refunded_amount >= stored_amount
      and expense.spent_at between p_spent_at - interval '60 days' and p_spent_at
      and (card_uuid is null or expense.card_id is null or expense.card_id = card_uuid)
    order by (expense.amount - expense.refunded_amount = stored_amount) desc,
             (card_uuid is not null and expense.card_id is not distinct from card_uuid) desc,
             (p_merchant is not null and p_merchant <> ''
               and pg_catalog.strpos(pg_catalog.lower(expense.merchant), pg_catalog.lower(pg_catalog.left(p_merchant, 6))) = 1) desc,
             expense.spent_at desc
    limit 1
    for update;
    if found_id is not null then
      update public.expenses set refunded_amount = refunded_amount + stored_amount where id = found_id;
    end if;
    insert into public.refunds (user_id, expense_id, card_id, amount, currency, merchant, refunded_at)
    values (p_user_id, found_id, card_uuid, stored_amount, resolved_currency, coalesce(p_merchant, ''), p_spent_at)
    returning id into refund_id;
    return pg_catalog.jsonb_build_object('ok', true, 'kind', 'refund', 'duplicate', false,
      'id', refund_id, 'matched', found_id is not null, 'expense_id', found_id);
  end if;

  -- Purchase: a retry of the same report (same source, amount, merchant, 2 min).
  select report.expense_id into found_id
  from public.capture_reports as report
  where report.user_id = p_user_id and report.source = p_source
    and report.amount = stored_amount and report.currency = resolved_currency
    and report.merchant = p_merchant
    and report.reported_at between p_spent_at - interval '120 seconds' and p_spent_at + interval '120 seconds'
  limit 1;
  if found_id is not null then
    return pg_catalog.jsonb_build_object('ok', true, 'kind', 'purchase', 'duplicate', true, 'id', found_id);
  end if;

  -- The same payment from the other automation: other capture source, same
  -- amount, within 10 minutes, not already paired, and cards compatible.
  select expense.id, expense.card_id into found_id, found_card
  from public.expenses as expense
  left join public.cards as card on card.id = expense.card_id
  where expense.user_id = p_user_id and expense.source in ('apple_pay', 'sms')
    and expense.source <> p_source and not expense.matched
    and expense.amount = stored_amount and expense.currency = resolved_currency
    and expense.spent_at between p_spent_at - interval '10 minutes' and p_spent_at + interval '10 minutes'
    and (card_uuid is null or expense.card_id is null or expense.card_id = card_uuid
         -- A Wallet-only card and an SMS-only card can be the same card.
         or ((card.last4 is null) <> (card_row.last4 is null)
             and (card.wallet_name is null or card_row.wallet_name is null)))
  order by pg_catalog.abs(extract(epoch from expense.spent_at - p_spent_at))
  limit 1
  for update of expense;
  if found_id is not null then
    if card_uuid is not null and found_card is not null and found_card <> card_uuid then
      -- Merge the two records into the one with the digits.
      select * into other_card from public.cards where id = found_card;
      if card_row.last4 is null then
        update public.expenses set card_id = other_card.id where user_id = p_user_id and card_id = card_row.id;
        update public.refunds set card_id = other_card.id where user_id = p_user_id and card_id = card_row.id;
        delete from public.cards where id = card_row.id;
        update public.cards set wallet_name = card_row.wallet_name,
          nickname = coalesce(other_card.nickname, card_row.nickname) where id = other_card.id;
        card_uuid := other_card.id;
      else
        update public.expenses set card_id = card_row.id where user_id = p_user_id and card_id = other_card.id;
        update public.refunds set card_id = card_row.id where user_id = p_user_id and card_id = other_card.id;
        delete from public.cards where id = other_card.id;
        update public.cards set wallet_name = other_card.wallet_name,
          nickname = coalesce(card_row.nickname, other_card.nickname) where id = card_row.id;
      end if;
    end if;
    -- Keep Wallet's merchant name (SMS often truncates it).
    update public.expenses set matched = true,
      card_id = coalesce(card_uuid, card_id),
      merchant = case when p_source = 'apple_pay' then p_merchant else merchant end,
      category = case when p_source = 'apple_pay' then p_category else category end
    where id = found_id;
    insert into public.capture_reports (user_id, expense_id, source, amount, currency, merchant, reported_at)
    values (p_user_id, found_id, p_source, stored_amount, resolved_currency, p_merchant, p_spent_at);
    return pg_catalog.jsonb_build_object('ok', true, 'kind', 'purchase', 'duplicate', true, 'merged', true, 'id', found_id);
  end if;

  insert into public.expenses (user_id, amount, currency, merchant, category, source, spent_at, card_id)
  values (p_user_id, stored_amount, resolved_currency, p_merchant, p_category, p_source, p_spent_at, card_uuid)
  returning id into inserted_id;
  insert into public.capture_reports (user_id, expense_id, source, amount, currency, merchant, reported_at)
  values (p_user_id, inserted_id, p_source, stored_amount, resolved_currency, p_merchant, p_spent_at);
  return pg_catalog.jsonb_build_object('ok', true, 'kind', 'purchase', 'duplicate', false, 'id', inserted_id);
end;
$$;
revoke all on function public.capture_payment(uuid, text, text, text, numeric, text, text, timestamptz, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.capture_payment(uuid, text, text, text, numeric, text, text, timestamptz, text, text, text, text)
  to service_role;
