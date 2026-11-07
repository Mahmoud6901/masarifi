-- Run as a Supabase database administrator after 001_init.sql is applied.
-- Every fixture and assertion is inside one transaction and is rolled back.
-- UNEXECUTED locally: requires a disposable Supabase database with both migrations.
-- With psql, use -v ON_ERROR_STOP=1 so any failure aborts this run.
begin;

do $$
declare
  owner_id constant uuid := '00000000-0000-4000-a000-000000000001';
  other_id constant uuid := '00000000-0000-4000-a000-000000000002';
begin
  if exists (select 1 from auth.users where id in (owner_id, other_id)) then
    raise exception 'Regression fixture UUID already exists';
  end if;

  insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at)
  values
    (owner_id, 'authenticated', 'authenticated', 'phase1-regression-owner@example.invalid', '', pg_catalog.now()),
    (other_id, 'authenticated', 'authenticated', 'phase1-regression-other@example.invalid', '', pg_catalog.now());

  if (select count(*) from public.profiles where id in (owner_id, other_id)) <> 2 then
    raise exception 'New-user trigger did not create both profiles';
  end if;
  if exists (
    select 1 from public.profiles
    where id in (owner_id, other_id)
      and (currency <> 'SAR' or monthly_income <> 0 or ingest_token !~ '^[0-9a-f]{48}$')
  ) then
    raise exception 'Profile defaults or ingest-token generation are incorrect';
  end if;
end $$;

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-a000-000000000001', true);

do $$
declare
  expense_id uuid;
  plan_id uuid;
  profile_count integer;
begin
  select count(*) into profile_count
  from public.profiles where id = '00000000-0000-4000-a000-000000000001';
  if profile_count <> 1 then raise exception 'Owner cannot read their profile'; end if;
  if exists (
    select 1 from pg_catalog.pg_class
    where oid in ('public.profiles'::regclass, 'public.expenses'::regclass,
                  'public.installment_plans'::regclass) and not relrowsecurity
  ) then raise exception 'A foundation table does not enable RLS'; end if;

  update public.profiles set currency = 'USD', monthly_income = 1250.00
  where id = '00000000-0000-4000-a000-000000000001';
  if not found then raise exception 'Owner cannot update allowed profile preferences'; end if;

  begin
    update public.profiles set ingest_token = 'client-replaced-token'
    where id = '00000000-0000-4000-a000-000000000001';
    raise exception 'Client unexpectedly updated ingest_token';
  exception when insufficient_privilege then null;
  end;

  begin
    update public.profiles set id = '00000000-0000-4000-a000-000000000002';
    raise exception 'Client unexpectedly updated profile id';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.profiles set created_at = pg_catalog.now();
    raise exception 'Client unexpectedly updated profile created_at';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.profiles set monthly_income = -1;
    raise exception 'Negative income accepted';
  exception when check_violation then null;
  end;
  begin
    update public.profiles set currency = 'invalid';
    raise exception 'Invalid currency accepted';
  exception when check_violation then null;
  end;

  begin
    insert into public.profiles (id) values ('00000000-0000-4000-a000-000000000001');
    raise exception 'Client unexpectedly inserted a profile';
  exception when insufficient_privilege then null;
  end;

  begin
    delete from public.profiles where id = '00000000-0000-4000-a000-000000000001';
    raise exception 'Client unexpectedly deleted a profile';
  exception when insufficient_privilege then null;
  end;

  insert into public.expenses (user_id, amount, merchant)
  values ('00000000-0000-4000-a000-000000000001', 10, 'Regression shop')
  returning id into expense_id;
  select count(*) into profile_count from public.expenses where id = expense_id;
  if profile_count <> 1 then raise exception 'Owner cannot read their expense'; end if;
  update public.expenses set note = 'updated' where id = expense_id;
  if not found then raise exception 'Owner cannot update their expense'; end if;
  delete from public.expenses where id = expense_id;
  if not found then raise exception 'Owner cannot delete their expense'; end if;

  insert into public.installment_plans
    (user_id, name, total_amount, monthly_amount, total_count, due_day)
  values ('00000000-0000-4000-a000-000000000001', 'Regression plan', 100, 10, 10, 1)
  returning id into plan_id;
  select count(*) into profile_count from public.installment_plans where id = plan_id;
  if profile_count <> 1 then raise exception 'Owner cannot read their installment'; end if;
  update public.installment_plans set paid_count = 1 where id = plan_id;
  if not found then raise exception 'Owner cannot update their installment'; end if;
  delete from public.installment_plans where id = plan_id;
  if not found then raise exception 'Owner cannot delete their installment'; end if;

  -- Keep nonempty owner fixtures for the second-user checks below.
  insert into public.expenses (user_id, amount, merchant)
  values ('00000000-0000-4000-a000-000000000001', 20, 'Retained owner expense')
  returning id into expense_id;
  insert into public.installment_plans
    (user_id, name, total_amount, monthly_amount, total_count, due_day)
  values ('00000000-0000-4000-a000-000000000001', 'Retained owner plan', 100, 10, 10, 1)
  returning id into plan_id;
  begin
    update public.expenses set user_id = '00000000-0000-4000-a000-000000000002'
    where id = expense_id;
    raise exception 'Owner unexpectedly reassigned an expense';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.installment_plans set user_id = '00000000-0000-4000-a000-000000000002'
    where id = plan_id;
    raise exception 'Owner unexpectedly reassigned an installment';
  exception when insufficient_privilege then null;
  end;
end $$;

select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-a000-000000000002', true);
do $$
declare
  visible_count integer;
begin
  select count(*) into visible_count from public.profiles
  where id = '00000000-0000-4000-a000-000000000001';
  if visible_count <> 0 then raise exception 'Second user can read the owner profile'; end if;

  select count(*) into visible_count from public.expenses
  where user_id = '00000000-0000-4000-a000-000000000001';
  if visible_count <> 0 then raise exception 'Second user can read owner expenses'; end if;

  select count(*) into visible_count from public.installment_plans
  where user_id = '00000000-0000-4000-a000-000000000001';
  if visible_count <> 0 then raise exception 'Second user can read owner installments'; end if;

  begin
    insert into public.expenses (user_id, amount, merchant)
    values ('00000000-0000-4000-a000-000000000001', 10, 'Cross-user write');
    raise exception 'Second user unexpectedly inserted an owner expense';
  exception when insufficient_privilege then null;
  end;

  begin
    insert into public.installment_plans
      (user_id, name, total_amount, monthly_amount, total_count, due_day)
    values ('00000000-0000-4000-a000-000000000001', 'Cross-user plan', 100, 10, 10, 1);
    raise exception 'Second user unexpectedly inserted an owner installment';
  exception when insufficient_privilege then null;
  end;

  update public.expenses set merchant = 'Cross-user update'
  where user_id = '00000000-0000-4000-a000-000000000001';
  if found then raise exception 'Second user updated owner expenses'; end if;
  delete from public.expenses where user_id = '00000000-0000-4000-a000-000000000001';
  if found then raise exception 'Second user deleted owner expenses'; end if;
  update public.installment_plans set paid_count = 1
  where user_id = '00000000-0000-4000-a000-000000000001';
  if found then raise exception 'Second user updated owner installments'; end if;
  delete from public.installment_plans where user_id = '00000000-0000-4000-a000-000000000001';
  if found then raise exception 'Second user deleted owner installments'; end if;

  begin
    update public.profiles set currency = 'EUR'
    where id = '00000000-0000-4000-a000-000000000001';
    if found then raise exception 'Second user unexpectedly updated owner profile'; end if;
  end;
end $$;

set local role anon;
select pg_catalog.set_config('request.jwt.claim.sub', '', true);
do $$
begin
  begin
    perform 1 from public.profiles;
    raise exception 'Anonymous role unexpectedly read profiles';
  exception when insufficient_privilege then null;
  end;

  begin
    perform 1 from public.expenses;
    raise exception 'Anonymous role unexpectedly read expenses';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.installment_plans;
    raise exception 'Anonymous role unexpectedly read installments';
  exception when insufficient_privilege then null;
  end;

  begin
    insert into public.expenses (user_id, amount, merchant)
    values ('00000000-0000-4000-a000-000000000001', 10, 'Anonymous write');
    raise exception 'Anonymous role unexpectedly inserted an expense';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.installment_plans
      (user_id, name, total_amount, monthly_amount, total_count, due_day)
    values ('00000000-0000-4000-a000-000000000001', 'Anonymous plan', 100, 10, 10, 1);
    raise exception 'Anonymous role unexpectedly inserted an installment';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;
do $$
begin
  if (select count(*) from public.expenses
      where user_id = '00000000-0000-4000-a000-000000000001') <> 1
  or (select count(*) from public.installment_plans
      where user_id = '00000000-0000-4000-a000-000000000001') <> 1 then
    raise exception 'Owner fixtures did not survive cross-user operations';
  end if;
end $$;

rollback;
