-- Rollback-only regression for 004_phase3_installments.sql.
-- Run as a Supabase database administrator after 001/002/003/004 have been
-- applied, with psql -v ON_ERROR_STOP=1 against a disposable database.
-- UNEXECUTED locally: live PostgreSQL/Supabase SQL and RLS checks are unavailable.
begin;

create temporary table phase3_test_state (
  user_id uuid primary key,
  token_hash text not null
);
grant select, insert on phase3_test_state to service_role;

do $$
declare
  owner_id constant uuid := '00000000-0000-4000-a000-000000000031';
  other_id constant uuid := '00000000-0000-4000-a000-000000000032';
begin
  if exists (select 1 from auth.users where id in (owner_id, other_id)) then
    raise exception 'Phase 3 regression fixture UUID already exists';
  end if;
  insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at)
  values
    (owner_id, 'authenticated', 'authenticated', 'phase3-owner@example.invalid', '', pg_catalog.now()),
    (other_id, 'authenticated', 'authenticated', 'phase3-other@example.invalid', '', pg_catalog.now());
  update public.profiles set currency = 'KWD', monthly_income = 123.456 where id = owner_id;
  insert into phase3_test_state (user_id, token_hash)
  select id, ingest_token_hash from public.profiles where id in (owner_id, other_id);
  if (select count(*) from phase3_test_state) <> 2 then
    raise exception 'Profile trigger did not create both regression profiles';
  end if;
end;
$$;

-- Storage retains real fils precision and the widened maximum without rounding.
set local role service_role;
do $$
declare
  owner_id constant uuid := '00000000-0000-4000-a000-000000000031';
  other_id constant uuid := '00000000-0000-4000-a000-000000000032';
  owner_hash text;
  other_hash text;
  result jsonb;
  first_id uuid;
begin
  select token_hash into owner_hash from phase3_test_state where user_id = owner_id;
  select token_hash into other_hash from phase3_test_state where user_id = other_id;

  insert into public.expenses (user_id, amount, currency, merchant, category, source)
  values (owner_id, 99999999999.999, 'KWD', 'Max', 'other', 'manual');
  if (select amount from public.expenses where user_id = owner_id and merchant = 'Max') <> 99999999999.999 then
    raise exception 'Widened numeric storage changed the maximum amount';
  end if;
  begin
    insert into public.expenses (user_id, amount, currency, merchant, category, source)
    values (owner_id, 1.001, 'SAR', 'Bad precision', 'other', 'manual');
    raise exception 'Two-decimal currency accepted a nonzero third decimal';
  exception when check_violation then null;
  end;
  begin
    insert into public.expenses (user_id, amount, currency, merchant, category, source)
    values (owner_id, 1.00, 'usd', 'Bad currency', 'other', 'manual');
    raise exception 'Non-normalized currency code was accepted';
  exception when check_violation then null;
  end;

  -- Six-argument callers omit p_currency and resolve it under the profile lock.
  result := public.record_apple_pay(owner_id, owner_hash, 1.255, 'Currency Duplicate', '2026-02-01 10:00:00+00', 'other');
  if result->>'duplicate' <> 'false' then raise exception 'Legacy six-argument call failed to insert'; end if;
  first_id := (result->>'id')::uuid;
  if (select currency from public.expenses where id = first_id) <> 'KWD'
     or (select amount from public.expenses where id = first_id) <> 1.255 then
    raise exception 'Omitted currency did not resolve to profile KWD or fils were rounded';
  end if;
  result := public.record_apple_pay(owner_id, owner_hash, 1.255, 'Currency Duplicate', '2026-02-01 10:00:00+00', 'other', 'KWD');
  if result->>'duplicate' <> 'true' or (result->>'id')::uuid <> first_id then
    raise exception 'Same-currency Apple Pay duplicate was not suppressed';
  end if;
  result := public.record_apple_pay(owner_id, owner_hash, 1.255, 'Currency Duplicate', '2026-02-01 10:00:00+00', 'other', 'BHD');
  if result->>'duplicate' <> 'false' then raise exception 'Different currency was incorrectly deduplicated'; end if;
  begin
    perform public.record_apple_pay(owner_id, owner_hash, 1.001, 'Bad SAR precision', '2026-02-01 10:00:00+00', 'other', 'SAR');
    raise exception 'Recorder accepted a third decimal for SAR';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.record_apple_pay(owner_id, owner_hash, 1.001, 'Bad USD precision', '2026-02-01 10:00:00+00', 'other', 'USD');
    raise exception 'Recorder accepted a third decimal for a two-decimal code';
  exception when sqlstate '22023' then null;
  end;
  result := public.record_apple_pay(owner_id, owner_hash, 1.255, 'Foreign valid', '2026-02-01 10:00:00+00', 'other', 'OMR');
  if (select currency from public.expenses where id = (result->>'id')::uuid) <> 'OMR' then
    raise exception 'Explicit foreign currency was not persisted';
  end if;
  begin
    perform public.record_apple_pay(owner_id, owner_hash, 1.00, 'Bad explicit code', '2026-02-01 10:00:00+00', 'other', 'usd');
    raise exception 'Recorder accepted a non-normalized currency code';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.record_apple_pay(other_id, owner_hash, 1.00, 'Wrong owner token', '2026-02-01 10:00:00+00', 'other');
    raise exception 'Recorder accepted another profile token';
  exception when sqlstate '28000' then null;
  end;
end;
$$;

-- The recorder remains service-only and the payment transition remains owner-only.
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-a000-000000000031', true);
do $$
declare
  owner_id constant uuid := '00000000-0000-4000-a000-000000000031';
  other_id constant uuid := '00000000-0000-4000-a000-000000000032';
  schedule_id uuid;
  finish_id uuid;
  result jsonb;
  plan jsonb;
begin
  if has_function_privilege('authenticated', 'public.record_apple_pay(uuid,text,numeric,text,timestamptz,text,text)', 'execute') then
    raise exception 'Authenticated role can execute the service-only recorder';
  end if;
  if has_function_privilege('anon', 'public.record_apple_pay(uuid,text,numeric,text,timestamptz,text,text)', 'execute') then
    raise exception 'Anonymous role can execute the service-only recorder';
  end if;
  if exists (
       select 1 from pg_catalog.pg_proc as proc
       cross join lateral pg_catalog.aclexplode(coalesce(proc.proacl, pg_catalog.acldefault('f', proc.proowner))) as acl
       where proc.oid = 'public.mark_installment_paid(uuid,integer,date)'::regprocedure
         and acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
     )
     or has_function_privilege('anon', 'public.mark_installment_paid(uuid,integer,date)', 'execute')
     or has_function_privilege('service_role', 'public.mark_installment_paid(uuid,integer,date)', 'execute') then
    raise exception 'Unauthorized role can execute mark_installment_paid';
  end if;
  if not has_function_privilege('authenticated', 'public.mark_installment_paid(uuid,integer,date)', 'execute') then
    raise exception 'Authenticated role cannot execute mark_installment_paid';
  end if;
  if (select count(*) from pg_catalog.pg_proc as proc
      where proc.pronamespace = 'public'::regnamespace and proc.proname = 'record_apple_pay') <> 1
     or to_regprocedure('public.record_apple_pay(uuid,text,numeric,text,timestamptz,text)') is not null then
    raise exception 'Recorder has an ambiguous or obsolete overload';
  end if;

  -- Legacy unfinished rows remain schedulable only after owner confirmation.
  insert into public.installment_plans
    (user_id, name, kind, total_amount, monthly_amount, total_count, paid_count, due_day, currency)
  values (owner_id, 'Legacy unset', 'other', 37.035, 12.345, 3, 1, 31, 'KWD')
  returning id into schedule_id;
  perform pg_catalog.set_config('phase3.owner_plan_id', schedule_id::text, true);
  begin
    perform public.mark_installment_paid(schedule_id, 1, null);
    raise exception 'Unset schedule was accepted for payment';
  exception when sqlstate '22023' then null;
  end;
  update public.installment_plans set next_due_date = '2026-02-28' where id = schedule_id;
  result := public.mark_installment_paid(schedule_id, 1, '2026-02-28');
  if result->>'applied' <> 'true' then raise exception 'Expected payment did not apply'; end if;
  plan := result->'plan';
  if (plan->>'paid_count')::integer <> 2 or plan->>'next_due_date' <> '2026-03-31'
     or plan->>'due_day' <> '31' or plan->>'currency' <> 'KWD' then
    raise exception 'Nominal day 31 was not restored after February clamping';
  end if;
  result := public.mark_installment_paid(schedule_id, 1, '2026-02-28');
  if result->>'applied' <> 'false' or (result->'plan'->>'paid_count')::integer <> 2 then
    raise exception 'Stale retry incremented the payment count';
  end if;
  result := public.mark_installment_paid(schedule_id, 2, '2026-03-31');
  plan := result->'plan';
  if result->>'applied' <> 'true' or (plan->>'paid_count')::integer <> 3
     or plan->>'active' <> 'false' or plan->>'next_due_date' is not null then
    raise exception 'Final payment did not deactivate and clear the schedule';
  end if;
  result := public.mark_installment_paid(schedule_id, 3, null);
  if result->>'applied' <> 'false' or (result->'plan'->>'paid_count')::integer <> 3 then
    raise exception 'Finished plan accepted another payment';
  end if;

  insert into public.installment_plans
    (user_id, name, kind, total_amount, monthly_amount, total_count, paid_count, due_day, currency, next_due_date)
  values (owner_id, 'Leap year', 'loan', 20.00, 10.00, 2, 0, 31, 'SAR', '2024-02-29')
  returning id into finish_id;
  result := public.mark_installment_paid(finish_id, 0, '2024-02-29');
  if result->'plan'->>'next_due_date' <> '2024-03-31' then
    raise exception 'Leap February did not advance to nominal day 31';
  end if;
  begin
    perform public.mark_installment_paid('00000000-0000-4000-a000-000000000099', 0, '2024-02-29');
    raise exception 'Missing plan did not return not-found';
  exception when sqlstate 'P0002' then null;
  end;
  begin
    perform public.mark_installment_paid(finish_id, -1, '2024-02-29');
    -- A stale count is safely reported as unapplied; negative values must not
    -- mutate and are rejected as malformed expected state in the contract.
    if (select paid_count from public.installment_plans where id = finish_id) <> 1 then
      raise exception 'Stale/negative expected count mutated the plan';
    end if;
  exception when sqlstate '22023' then null;
  end;
end;
$$;

select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-a000-000000000032', true);
do $$
begin
  begin
    perform public.mark_installment_paid(pg_catalog.current_setting('phase3.owner_plan_id')::uuid, 3, null);
    raise exception 'Another owner marked the installment paid';
  exception when sqlstate 'P0002' then null;
  end;
end;
$$;

-- Constraint-level validation rejects impossible clamped schedule dates and
-- completed records that remain active or carry a next date.
reset role;
set local role service_role;
do $$
declare
  owner_id constant uuid := '00000000-0000-4000-a000-000000000031';
begin
  begin
    insert into public.installment_plans
      (user_id, name, total_amount, monthly_amount, total_count, due_day, currency, next_due_date)
    values (owner_id, 'Infinite schedule', 10, 10, 1, 31, 'SAR', 'infinity');
    raise exception 'Plan accepted an infinite schedule date';
  exception when check_violation then null;
  end;
  begin
    insert into public.installment_plans
      (user_id, name, total_amount, monthly_amount, total_count, due_day, currency, next_due_date)
    values (owner_id, 'Wrong nominal date', 10, 10, 1, 31, 'SAR', '2026-02-27');
    raise exception 'Plan accepted a date inconsistent with nominal due_day';
  exception when check_violation then null;
  end;
  begin
    insert into public.installment_plans
      (user_id, name, total_amount, monthly_amount, total_count, paid_count, due_day, active, currency)
    values (owner_id, 'Active but complete', 10, 10, 1, 1, 1, true, 'SAR');
    raise exception 'Completed plan remained active';
  exception when check_violation then null;
  end;
  begin
    insert into public.installment_plans
      (user_id, name, total_amount, monthly_amount, total_count, due_day, currency)
    values (owner_id, 'SAR overprecision', 10.001, 10.001, 1, 1, 'SAR');
    raise exception 'Plan accepted nonzero third decimal in SAR';
  exception when check_violation then null;
  end;
end;
$$;

rollback;
