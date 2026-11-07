-- Rollback-only Phase 2 regression for 003_apple_pay_capture.sql.
-- Run as a Supabase database administrator after 001/002/003 are applied,
-- with psql -v ON_ERROR_STOP=1 against a disposable database.
-- UNEXECUTED locally: psql and a disposable Supabase database are unavailable.
begin;

create temporary table phase2_test_state (
  user_id uuid primary key,
  old_token text not null,
  new_token text
);
grant select, insert, update on phase2_test_state to authenticated, service_role;

do $$
declare
  owner_id constant uuid := '00000000-0000-4000-a000-000000000021';
  other_id constant uuid := '00000000-0000-4000-a000-000000000022';
  missing_profile_id constant uuid := '00000000-0000-4000-a000-000000000023';
begin
  if exists (
    select 1 from auth.users
    where id in (owner_id, other_id, missing_profile_id)
  ) then
    raise exception 'Phase 2 regression fixture UUID already exists';
  end if;

  insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at)
  values
    (owner_id, 'authenticated', 'authenticated', 'phase2-owner@example.invalid', '', pg_catalog.now()),
    (other_id, 'authenticated', 'authenticated', 'phase2-other@example.invalid', '', pg_catalog.now()),
    (missing_profile_id, 'authenticated', 'authenticated', 'phase2-missing@example.invalid', '', pg_catalog.now());

  insert into phase2_test_state (user_id, old_token)
  select id, ingest_token from public.profiles
  where id in (owner_id, other_id);

  if (select count(*) from phase2_test_state) <> 2 then
    raise exception 'Profile trigger did not create both test profiles';
  end if;
  if exists (
    select 1 from public.profiles as profile
    where profile.id in (owner_id, other_id)
      and profile.ingest_token_hash is distinct from pg_catalog.encode(
        extensions.digest(pg_catalog.convert_to(profile.ingest_token, 'UTF8'), 'sha256'),
        'hex'
      )
  ) then
    raise exception 'Generated token digest does not match the exact UTF8 token';
  end if;
end;
$$;

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-a000-000000000021', true);

do $$
declare
  rotated text;
begin
  rotated := public.rotate_ingest_token();
  if rotated !~ '^[0-9a-f]{48}$' then
    raise exception 'Rotation did not return a fresh 48-character lowercase hex token';
  end if;
  if rotated = (select old_token from phase2_test_state where user_id = auth.uid()) then
    raise exception 'Rotation returned the previous token';
  end if;
  update phase2_test_state set new_token = rotated where user_id = auth.uid();

  begin
    update public.profiles set ingest_token = repeat('0', 48) where id = auth.uid();
    raise exception 'Authenticated client unexpectedly wrote ingest_token';
  exception when insufficient_privilege then null;
  end;

  begin
    -- DEFAULT is syntactically valid for a generated column, so this exercises
    -- the column ACL instead of failing earlier in generated-column rewriting.
    update public.profiles set ingest_token_hash = default where id = auth.uid();
    raise exception 'Authenticated client unexpectedly wrote ingest_token_hash';
  exception when insufficient_privilege then null;
  end;
end;
$$;

select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-a000-000000000022', true);
do $$
declare
  rotated text;
begin
  rotated := public.rotate_ingest_token();
  update phase2_test_state set new_token = rotated where user_id = auth.uid();
end;
$$;

select pg_catalog.set_config('request.jwt.claim.sub', '', true);
do $$
begin
  begin
    perform public.rotate_ingest_token();
    raise exception 'Rotation succeeded without an authenticated identity';
  exception when sqlstate '28000' then null;
  end;
end;
$$;

set local role anon;
do $$
begin
  begin
    perform public.rotate_ingest_token();
    raise exception 'Anonymous role unexpectedly executed token rotation';
  exception when insufficient_privilege then null;
  end;
end;
$$;

set local role service_role;
do $$
declare
  owner_id constant uuid := '00000000-0000-4000-a000-000000000021';
  other_id constant uuid := '00000000-0000-4000-a000-000000000022';
  token text;
  old_token text;
  token_hash text;
  stale_hash text;
  event_time constant timestamptz := '2026-01-02 03:04:05+00';
  result jsonb;
  first_id uuid;
  manual_id uuid;
begin
  begin
    perform public.rotate_ingest_token();
    raise exception 'service_role unexpectedly executed token rotation';
  exception when insufficient_privilege then null;
  end;

  select new_token, phase2_test_state.old_token
  into token, old_token
  from phase2_test_state where user_id = owner_id;
  token_hash := pg_catalog.encode(extensions.digest(pg_catalog.convert_to(token, 'UTF8'), 'sha256'), 'hex');
  stale_hash := pg_catalog.encode(extensions.digest(pg_catalog.convert_to(old_token, 'UTF8'), 'sha256'), 'hex');

  -- The old token is revoked by rotation; the returned token remains usable.
  begin
    perform public.record_apple_pay(owner_id, stale_hash, 12.34, 'Rotated Token', event_time, 'other');
    raise exception 'Old token remained valid after rotation';
  exception when sqlstate '28000' then null;
  end;
  result := public.record_apple_pay(owner_id, token_hash, 12.34, 'Rotated Token', event_time, 'other');
  if result->>'ok' <> 'true' or result->>'duplicate' <> 'false' then
    raise exception 'New token did not create its first expense';
  end if;

  -- PostgreSQL escape strings do not recognize \v as a vertical tab; a trim
  -- list must use chr(11), otherwise merchant names beginning with v are lost.
  result := public.record_apple_pay(owner_id, token_hash, 10.00, 'vox', event_time, 'entertainment');
  if result->>'duplicate' <> 'false' then
    raise exception 'A valid merchant starting with v was rejected';
  end if;
  begin
    perform public.record_apple_pay(owner_id, token_hash, 1.00, chr(11) || 'Cafe', event_time, 'food');
    raise exception 'A merchant with a leading vertical tab was accepted';
  exception when sqlstate '22023' then null;
  end;

  -- Opposite arrival order and inclusive lower boundary.
  result := public.record_apple_pay(owner_id, token_hash, 20.00, 'Lower Boundary', event_time, 'food');
  first_id := (result->>'id')::uuid;
  result := public.record_apple_pay(owner_id, token_hash, 20.00, 'Lower Boundary', event_time - interval '120 seconds', 'food');
  if result->>'duplicate' <> 'true' or (result->>'id')::uuid <> first_id then
    raise exception 'Lower 120-second boundary or reversed arrival was not deduplicated';
  end if;

  -- Inclusive upper boundary.
  result := public.record_apple_pay(owner_id, token_hash, 21.00, 'Upper Boundary', event_time, 'food');
  first_id := (result->>'id')::uuid;
  result := public.record_apple_pay(owner_id, token_hash, 21.00, 'Upper Boundary', event_time + interval '120 seconds', 'food');
  if result->>'duplicate' <> 'true' or (result->>'id')::uuid <> first_id then
    raise exception 'Upper 120-second boundary was not deduplicated';
  end if;

  -- A payment outside the window is independent.
  result := public.record_apple_pay(owner_id, token_hash, 22.00, 'Outside Window', event_time, 'food');
  result := public.record_apple_pay(owner_id, token_hash, 22.00, 'Outside Window', event_time + interval '121 seconds', 'food');
  if result->>'duplicate' <> 'false' then
    raise exception 'Payment outside the 120-second window was suppressed';
  end if;

  -- Identical other-user payments remain separate.
  result := public.record_apple_pay(owner_id, token_hash, 23.00, 'Cross User', event_time, 'food');
  select new_token into token from phase2_test_state where user_id = other_id;
  token_hash := pg_catalog.encode(extensions.digest(pg_catalog.convert_to(token, 'UTF8'), 'sha256'), 'hex');
  result := public.record_apple_pay(other_id, token_hash, 23.00, 'Cross User', event_time, 'food');
  if result->>'duplicate' <> 'false' then
    raise exception 'Another user’s payment was treated as a duplicate';
  end if;

  -- Manual expenses never participate in Apple Pay de-duplication.
  select new_token into token from phase2_test_state where user_id = owner_id;
  token_hash := pg_catalog.encode(extensions.digest(pg_catalog.convert_to(token, 'UTF8'), 'sha256'), 'hex');
  insert into public.expenses (user_id, amount, currency, merchant, category, source, spent_at)
  values (owner_id, 24.00, 'SAR', 'Manual Isolated', 'food', 'manual', event_time)
  returning id into manual_id;
  result := public.record_apple_pay(owner_id, token_hash, 24.00, 'Manual Isolated', event_time, 'food');
  if result->>'duplicate' <> 'false' or (result->>'id')::uuid = manual_id then
    raise exception 'Manual expense incorrectly suppressed Apple Pay insert';
  end if;

  -- Invalid payloads must fail explicitly rather than round or write.
  begin
    perform public.record_apple_pay(owner_id, token_hash, 1.001, 'Bad Amount', event_time, 'other');
    raise exception 'Amount with more than two decimals was accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.record_apple_pay(owner_id, token_hash, 'NaN'::numeric, 'Bad Amount', event_time, 'other');
    raise exception 'NaN amount was accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.record_apple_pay(owner_id, token_hash, 1.00, 'Bad Category', event_time, 'invalid');
    raise exception 'Unknown category was accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.record_apple_pay(owner_id, token_hash, 1.00, ' Bad Merchant', event_time, 'other');
    raise exception 'Untrimmed merchant was accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.record_apple_pay(owner_id, token_hash, 1.00, 'Bad Time', 'infinity'::timestamptz, 'other');
    raise exception 'Infinite event time was accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.record_apple_pay(owner_id, repeat('a', 64), 1.00, 'Bad Digest', event_time, 'other');
    raise exception 'Mismatched token digest was accepted';
  exception when sqlstate '28000' then null;
  end;
end;
$$;

-- Authenticated and anonymous callers cannot execute the service-only recorder.
set local role authenticated;
do $$
begin
  begin
    perform public.record_apple_pay(
      '00000000-0000-4000-a000-000000000021', repeat('a', 64), 1.00,
      'Unauthorized', '2026-01-02 03:04:05+00', 'other'
    );
    raise exception 'Authenticated role unexpectedly executed the recorder';
  exception when insufficient_privilege then null;
  end;
end;
$$;

set local role anon;
do $$
begin
  begin
    perform public.record_apple_pay(
      '00000000-0000-4000-a000-000000000021', repeat('a', 64), 1.00,
      'Unauthorized', '2026-01-02 03:04:05+00', 'other'
    );
    raise exception 'Anonymous role unexpectedly executed the recorder';
  exception when insufficient_privilege then null;
  end;
end;
$$;

reset role;

-- Force an insertion error after validation and duplicate lookup. The RPC must
-- propagate it and leave no expense behind.
create function pg_temp.reject_apple_pay_insert() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.source = 'apple_pay' and new.merchant = 'Injected Failure' then
    raise exception 'Injected insert failure';
  end if;
  return new;
end;
$$;
create trigger phase2_test_reject_insert
before insert on public.expenses
for each row execute function pg_temp.reject_apple_pay_insert();

set local role service_role;
do $$
declare
  owner_id constant uuid := '00000000-0000-4000-a000-000000000021';
  token text;
  token_hash text;
begin
  select new_token into token from phase2_test_state where user_id = owner_id;
  token_hash := pg_catalog.encode(extensions.digest(pg_catalog.convert_to(token, 'UTF8'), 'sha256'), 'hex');
  begin
    perform public.record_apple_pay(
      owner_id, token_hash, 25.00, 'Injected Failure',
      '2026-01-02 03:04:05+00', 'other'
    );
    raise exception 'Recorder reported success despite an insert failure';
  exception when raise_exception then
    if sqlerrm = 'Recorder reported success despite an insert failure' then raise; end if;
  end;
  if exists (
    select 1 from public.expenses
    where user_id = owner_id and source = 'apple_pay' and merchant = 'Injected Failure'
  ) then
    raise exception 'Failed recorder left a partial expense';
  end if;
end;
$$;

reset role;

-- An authenticated identity with no profile must fail without creating one.
delete from public.profiles where id = '00000000-0000-4000-a000-000000000023';
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-a000-000000000023', true);
do $$
begin
  begin
    perform public.rotate_ingest_token();
    raise exception 'Rotation unexpectedly created a missing profile';
  exception when sqlstate '28000' then null;
  end;
end;
$$;
reset role;

do $$
begin
  if exists (
    select 1 from public.profiles where id = '00000000-0000-4000-a000-000000000023'
  ) then
    raise exception 'Rotation created a profile that was missing';
  end if;
end;
$$;

rollback;
