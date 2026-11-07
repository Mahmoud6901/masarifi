-- Upgrade regression: UNEXECUTED locally. Run with psql -v ON_ERROR_STOP=1
-- as a Supabase administrator on a disposable database with 001/002/003 ONLY.
-- This script applies 004 transactionally, checks legacy preservation, and rolls
-- back both the fixtures and migration. Do not run against an existing 004 schema.
begin;

do $$
declare
  owner_id constant uuid := '00000000-0000-4000-a000-000000000041';
begin
  if exists (select 1 from auth.users where id = owner_id) then
    raise exception 'Upgrade fixture UUID already exists';
  end if;
  insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at)
  values (owner_id, 'authenticated', 'authenticated', 'phase3-upgrade@example.invalid', '', pg_catalog.now());
  update public.profiles set currency = 'KWD', monthly_income = 123.45 where id = owner_id;
  insert into public.expenses (user_id, amount, currency, merchant)
  values (owner_id, 123.45, 'USD', 'Upgrade fixture');
  insert into public.installment_plans
    (user_id, name, total_amount, monthly_amount, total_count, paid_count, due_day, active)
  values
    (owner_id, 'Unfinished legacy', 301.23, 100.41, 3, 1, 28, true),
    (owner_id, 'Completed legacy', 301.23, 100.41, 3, 3, 28, true),
    (owner_id, 'Inactive legacy', 301.23, 100.41, 3, 1, 28, false);
end;
$$;

\ir ../migrations/004_phase3_installments.sql

do $$
declare
  owner_id constant uuid := '00000000-0000-4000-a000-000000000041';
begin
  if (select count(*) from public.installment_plans where user_id = owner_id) <> 3
     or exists (select 1 from public.installment_plans where user_id = owner_id
       and (currency <> 'KWD' or total_amount <> 301.23 or monthly_amount <> 100.41
         or total_count <> 3 or due_day <> 28 or next_due_date is not null)) then
    raise exception 'Upgrade changed legacy money, currency, terms or invented dates';
  end if;
  if not exists (select 1 from public.installment_plans where user_id = owner_id
       and name = 'Unfinished legacy' and paid_count = 1 and active)
     or not exists (select 1 from public.installment_plans where user_id = owner_id
       and name = 'Completed legacy' and paid_count = 3 and not active)
     or not exists (select 1 from public.installment_plans where user_id = owner_id
       and name = 'Inactive legacy' and paid_count = 1 and not active) then
    raise exception 'Upgrade changed legacy counts or lifecycle incorrectly';
  end if;
  if (select monthly_income from public.profiles where id = owner_id) <> 123.45
     or not exists (select 1 from public.expenses where user_id = owner_id
       and amount = 123.45 and currency = 'USD' and merchant = 'Upgrade fixture') then
    raise exception 'Upgrade changed existing profile or expense values';
  end if;
  if (select count(*) from information_schema.columns
      where table_schema = 'public' and numeric_precision = 14 and numeric_scale = 3
        and ((table_name = 'profiles' and column_name = 'monthly_income')
          or (table_name = 'expenses' and column_name = 'amount')
          or (table_name = 'installment_plans' and column_name in ('total_amount', 'monthly_amount')))) <> 4 then
    raise exception 'Upgrade did not widen all four money columns';
  end if;
end;
$$;
rollback;
