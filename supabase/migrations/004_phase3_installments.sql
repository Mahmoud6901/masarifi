-- Phase 3: preserve existing money, retain currency, and persist installment
-- schedules and atomic payment transitions. Apply after 001/002/003.

-- Widening numeric(12,2) to numeric(14,3) preserves existing values exactly.
alter table public.expenses
  alter column amount type numeric(14,3);
alter table public.installment_plans
  alter column monthly_amount type numeric(14,3),
  alter column total_amount type numeric(14,3);
alter table public.profiles
  alter column monthly_income type numeric(14,3);

alter table public.profiles
  drop constraint if exists profiles_monthly_income_check;
alter table public.profiles
  add constraint profiles_monthly_income_check
  check (
    monthly_income >= 0
    and monthly_income::text not in ('NaN', 'Infinity', '-Infinity')
    and monthly_income <= 99999999999.999
    and (currency in ('KWD', 'BHD', 'OMR') or monthly_income = pg_catalog.trunc(monthly_income, 2))
  );

alter table public.expenses
  drop constraint if exists expenses_amount_check;
alter table public.expenses
  add constraint expenses_currency_check check (currency ~ '^[A-Z]{3}$'),
  add constraint expenses_amount_check
  check (
    amount >= 0
    and amount::text not in ('NaN', 'Infinity', '-Infinity')
    and amount <= 99999999999.999
    and (currency in ('KWD', 'BHD', 'OMR') or amount = pg_catalog.trunc(amount, 2))
  );

-- Add nullable first so existing rows can be backfilled from the preference
-- that the app previously used to interpret every plan.
alter table public.installment_plans add column currency text;
update public.installment_plans as plan
set currency = profile.currency
from public.profiles as profile
where profile.id = plan.user_id;
alter table public.installment_plans
  alter column currency set default 'SAR',
  alter column currency set not null,
  add column next_due_date date;

-- Finished legacy records have no remaining date. Preserve their historical
-- counts and amounts while bringing lifecycle flags into the new invariant.
update public.installment_plans
set active = false, next_due_date = null
where paid_count >= total_count;

alter table public.installment_plans
  drop constraint if exists installment_plans_monthly_amount_check,
  drop constraint if exists installment_plans_total_amount_check,
  drop constraint if exists installment_plans_due_day_check;
alter table public.installment_plans
  add constraint installment_plans_currency_check check (currency ~ '^[A-Z]{3}$'),
  add constraint installment_plans_monthly_amount_check check (
    monthly_amount >= 0
    and monthly_amount::text not in ('NaN', 'Infinity', '-Infinity')
    and monthly_amount <= 99999999999.999
    and (currency in ('KWD', 'BHD', 'OMR') or monthly_amount = pg_catalog.trunc(monthly_amount, 2))
  ),
  add constraint installment_plans_total_amount_check check (
    total_amount >= 0
    and total_amount::text not in ('NaN', 'Infinity', '-Infinity')
    and total_amount <= 99999999999.999
    and (currency in ('KWD', 'BHD', 'OMR') or total_amount = pg_catalog.trunc(total_amount, 2))
  ),
  add constraint installment_plans_due_day_check check (due_day between 1 and 31),
  add constraint installment_plans_next_due_nominal_day_check check (
    next_due_date is null
    or (pg_catalog.isfinite(next_due_date)
      and next_due_date between date '0001-01-01' and date '9999-12-31'
      and extract(day from next_due_date) = least(
      due_day,
      extract(day from (date_trunc('month', next_due_date::timestamp) + interval '1 month - 1 day'))::integer
    ))
  ),
  add constraint installment_plans_finished_state_check check (
    paid_count < total_count or (not active and next_due_date is null)
  );

-- This is the single currency-aware signature. The trailing default preserves
-- source compatibility for existing six-argument service callers.
drop function if exists public.record_apple_pay(uuid, text, numeric, text, timestamptz, text);
create function public.record_apple_pay(
  p_user_id uuid,
  p_token_hash text,
  p_amount numeric,
  p_merchant text,
  p_spent_at timestamptz,
  p_category text,
  p_currency text default null
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
  duplicate_id uuid;
  inserted_id uuid;
  stored_amount numeric(14,3);
begin
  if p_user_id is null or p_token_hash is null or p_amount is null
     or p_merchant is null or p_spent_at is null or p_category is null then
    raise exception 'Invalid Apple Pay payload' using errcode = '22023';
  end if;
  if p_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'Invalid Apple Pay payload' using errcode = '22023';
  end if;
  if p_amount::text in ('NaN', 'Infinity', '-Infinity')
     or p_amount < 0 or p_amount > 99999999999.999 then
    raise exception 'Invalid Apple Pay amount' using errcode = '22023';
  end if;
  if p_currency is not null and p_currency !~ '^[A-Z]{3}$' then
    raise exception 'Invalid Apple Pay currency' using errcode = '22023';
  end if;
  if not pg_catalog.isfinite(p_spent_at) then
    raise exception 'Invalid Apple Pay time' using errcode = '22023';
  end if;
  if p_merchant <> pg_catalog.btrim(p_merchant, E' \t\n\r\f' || pg_catalog.chr(11))
     or pg_catalog.char_length(p_merchant) < 1 or pg_catalog.char_length(p_merchant) > 200 then
    raise exception 'Invalid Apple Pay merchant' using errcode = '22023';
  end if;
  if p_category not in ('food', 'groceries', 'transport', 'health', 'bills', 'shopping', 'entertainment', 'other') then
    raise exception 'Invalid Apple Pay category' using errcode = '22023';
  end if;

  -- Lock before resolving omitted currency, validating its precision, and
  -- rechecking the token so concurrent rotation/preferences serialize here.
  select profile.ingest_token_hash, profile.currency
  into profile_token_hash, profile_currency
  from public.profiles as profile
  where profile.id = p_user_id
  for update;
  if not found or profile_token_hash is distinct from p_token_hash then
    raise exception 'Invalid ingest credentials' using errcode = '28000';
  end if;
  resolved_currency := coalesce(p_currency, profile_currency);
  if p_amount <> pg_catalog.trunc(p_amount, case when resolved_currency in ('KWD', 'BHD', 'OMR') then 3 else 2 end) then
    raise exception 'Apple Pay amount exceeds currency precision' using errcode = '22023';
  end if;
  stored_amount := p_amount::numeric(14,3);

  select expense.id into duplicate_id
  from public.expenses as expense
  where expense.user_id = p_user_id and expense.source = 'apple_pay'
    and expense.amount = stored_amount and expense.currency = resolved_currency
    and expense.merchant = p_merchant
    and expense.spent_at between p_spent_at - interval '120 seconds'
                             and p_spent_at + interval '120 seconds'
  limit 1;
  if duplicate_id is not null then
    return pg_catalog.jsonb_build_object('ok', true, 'duplicate', true, 'id', duplicate_id);
  end if;
  insert into public.expenses (user_id, amount, currency, merchant, category, source, spent_at)
  values (p_user_id, stored_amount, resolved_currency, p_merchant, p_category, 'apple_pay', p_spent_at)
  returning id into inserted_id;
  return pg_catalog.jsonb_build_object('ok', true, 'duplicate', false, 'id', inserted_id);
end;
$$;
revoke all on function public.record_apple_pay(uuid, text, numeric, text, timestamptz, text, text)
  from public, anon, authenticated;
grant execute on function public.record_apple_pay(uuid, text, numeric, text, timestamptz, text, text)
  to service_role;

create function public.mark_installment_paid(
  p_plan_id uuid,
  p_expected_paid_count integer,
  p_expected_next_due_date date
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
  current_plan public.installment_plans%rowtype;
  advanced_date date;
begin
  if caller_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if p_plan_id is null or p_expected_paid_count is null or p_expected_paid_count < 0 then
    raise exception 'Invalid expected installment state' using errcode = '22023';
  end if;
  select plan.* into current_plan
  from public.installment_plans as plan
  where plan.id = p_plan_id and plan.user_id = caller_id
  for update;
  if not found then
    raise exception 'Installment plan not found' using errcode = 'P0002';
  end if;

  if not current_plan.active or current_plan.paid_count >= current_plan.total_count then
    return pg_catalog.jsonb_build_object('applied', false, 'plan', pg_catalog.to_jsonb(current_plan));
  end if;
  if current_plan.next_due_date is null then
    raise exception 'Installment schedule requires owner confirmation' using errcode = '22023';
  end if;
  if current_plan.paid_count is distinct from p_expected_paid_count
     or current_plan.next_due_date is distinct from p_expected_next_due_date then
    return pg_catalog.jsonb_build_object('applied', false, 'plan', pg_catalog.to_jsonb(current_plan));
  end if;

  if current_plan.paid_count + 1 = current_plan.total_count then
    update public.installment_plans as plan
    set paid_count = current_plan.paid_count + 1, active = false, next_due_date = null
    where plan.id = current_plan.id and plan.user_id = caller_id
    returning plan.* into current_plan;
  else
    advanced_date := (
      date_trunc('month', current_plan.next_due_date::timestamp) + interval '1 month'
    )::date;
    advanced_date := advanced_date + (
      least(
        current_plan.due_day,
        extract(day from (advanced_date + interval '1 month - 1 day'))::integer
      ) - 1
    );
    update public.installment_plans as plan
    set paid_count = current_plan.paid_count + 1, next_due_date = advanced_date
    where plan.id = current_plan.id and plan.user_id = caller_id
    returning plan.* into current_plan;
  end if;
  return pg_catalog.jsonb_build_object('applied', true, 'plan', pg_catalog.to_jsonb(current_plan));
end;
$$;
revoke all on function public.mark_installment_paid(uuid, integer, date) from public, anon, service_role;
grant execute on function public.mark_installment_paid(uuid, integer, date) to authenticated;
