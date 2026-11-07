-- Apple Pay ingest authentication, token rotation, and atomic de-duplication.
-- Apply after 001_init.sql and 002_profile_privileges.sql.

alter table public.profiles
  add column ingest_token_hash text generated always as (
    pg_catalog.encode(
      -- Tokens are ASCII hex, so their database bytes are also exact UTF8.
      -- digest(text,text) is immutable; convert_to is only stable and cannot
      -- appear in a stored generated expression.
      extensions.digest(ingest_token, 'sha256'),
      'hex'
    )
  ) stored;

create unique index profiles_ingest_token_hash_uidx
  on public.profiles (ingest_token_hash);

-- Keep the profile preference-only update grant established in 001/002.
-- The generated digest cannot be directly written, and clients cannot replace
-- the source token either.
revoke update (ingest_token, ingest_token_hash)
  on table public.profiles from public, anon, authenticated;

create or replace function public.rotate_ingest_token()
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
  fresh_token text;
begin
  if caller_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  fresh_token := pg_catalog.encode(extensions.gen_random_bytes(24), 'hex');

  update public.profiles
  set ingest_token = fresh_token
  where id = caller_id
  returning ingest_token into fresh_token;

  if not found then
    raise exception 'Profile not found' using errcode = '28000';
  end if;

  return fresh_token;
end;
$$;

revoke all on function public.rotate_ingest_token() from public, anon, service_role;
grant execute on function public.rotate_ingest_token() to authenticated;

create or replace function public.record_apple_pay(
  p_user_id uuid,
  p_token_hash text,
  p_amount numeric,
  p_merchant text,
  p_spent_at timestamptz,
  p_category text
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
  duplicate_id uuid;
  inserted_id uuid;
  stored_amount numeric(12,2);
begin
  if p_user_id is null
     or p_token_hash is null
     or p_amount is null
     or p_merchant is null
     or p_spent_at is null
     or p_category is null then
    raise exception 'Invalid Apple Pay payload' using errcode = '22023';
  end if;

  if p_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'Invalid Apple Pay payload' using errcode = '22023';
  end if;

  if p_amount::text in ('NaN', 'Infinity', '-Infinity')
     or p_amount < 0
     or p_amount > 9999999999.99 then
    raise exception 'Invalid Apple Pay amount' using errcode = '22023';
  end if;
  if p_amount <> pg_catalog.trunc(p_amount, 2) then
    raise exception 'Apple Pay amount has more than two decimal places' using errcode = '22023';
  end if;
  stored_amount := p_amount::numeric(12,2);

  if not pg_catalog.isfinite(p_spent_at) then
    raise exception 'Invalid Apple Pay time' using errcode = '22023';
  end if;

  if p_merchant <> pg_catalog.btrim(p_merchant, E' \t\n\r\f' || pg_catalog.chr(11))
     or pg_catalog.char_length(p_merchant) < 1
     or pg_catalog.char_length(p_merchant) > 200 then
    raise exception 'Invalid Apple Pay merchant' using errcode = '22023';
  end if;

  if p_category not in (
    'food', 'groceries', 'transport', 'health', 'bills', 'shopping',
    'entertainment', 'other'
  ) then
    raise exception 'Invalid Apple Pay category' using errcode = '22023';
  end if;

  -- This statement serializes incoming records for one profile and reads the
  -- current token digest/currency after any concurrent rotation or preference
  -- update has completed.
  select profile.ingest_token_hash, profile.currency
  into profile_token_hash, profile_currency
  from public.profiles as profile
  where profile.id = p_user_id
  for update;

  if not found or profile_token_hash is distinct from p_token_hash then
    raise exception 'Invalid ingest credentials' using errcode = '28000';
  end if;

  -- Kept as a separate statement after the profile lock so concurrent calls
  -- observe the prior committed insert. Both event-time boundaries are inclusive.
  select expense.id
  into duplicate_id
  from public.expenses as expense
  where expense.user_id = p_user_id
    and expense.source = 'apple_pay'
    and expense.amount = stored_amount
    and expense.merchant = p_merchant
    and expense.spent_at between p_spent_at - interval '120 seconds'
                             and p_spent_at + interval '120 seconds'
  limit 1;

  if duplicate_id is not null then
    return pg_catalog.jsonb_build_object(
      'ok', true,
      'duplicate', true,
      'id', duplicate_id
    );
  end if;

  insert into public.expenses (
    user_id, amount, currency, merchant, category, source, spent_at
  ) values (
    p_user_id, stored_amount, profile_currency, p_merchant, p_category,
    'apple_pay', p_spent_at
  )
  returning id into inserted_id;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'duplicate', false,
    'id', inserted_id
  );
end;
$$;

revoke all on function public.record_apple_pay(uuid, text, numeric, text, timestamptz, text)
  from public, anon, authenticated;
grant execute on function public.record_apple_pay(uuid, text, numeric, text, timestamptz, text)
  to service_role;
