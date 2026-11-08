-- Rollback-only regression for 005_cards_refunds_sms.sql. Run as a database
-- administrator after 001-005 inside a transaction that is rolled back.
-- Fixture users are synthetic; no real data is read or kept.
do $$
declare
  owner_id constant uuid := '00000000-0000-4000-a000-000000000051';
  hash text;
  r jsonb;
  first_id uuid;
  t0 constant timestamptz := '2026-11-08T09:00:00Z';
  n int;
  card_count int;
begin
  insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at)
  values (owner_id, 'authenticated', 'authenticated', 'cards-owner@example.invalid', '', pg_catalog.now());
  select ingest_token_hash into hash from public.profiles where id = owner_id;

  -- 1. Wallet tap creates a Wallet-named card and an apple_pay expense.
  r := public.capture_payment(owner_id, hash, 'purchase', 'apple_pay', 25.50, null, 'Starbucks Olaya', t0, 'food', 'Bank A mada Classic', null, null);
  first_id := (r->>'id')::uuid;
  if (r->>'duplicate')::boolean then raise exception '1: first tap reported duplicate'; end if;
  if (select count(*) from public.cards where user_id = owner_id and wallet_name = 'Bank A mada Classic' and last4 is null) <> 1 then
    raise exception '1: wallet card not created';
  end if;

  -- 2. The SMS for the same payment 3 minutes later merges into one expense
  --    and one card holding both the Wallet name and the digits.
  r := public.capture_payment(owner_id, hash, 'purchase', 'sms', 25.50, 'SAR', 'Starbucks Ol', t0 + interval '3 minutes', 'food', null, 'Bank A', '1226');
  if not coalesce((r->>'merged')::boolean, false) or (r->>'id')::uuid <> first_id then raise exception '2: SMS did not merge: %', r; end if;
  if (select count(*) from public.expenses where user_id = owner_id) <> 1 then raise exception '2: duplicate expense stored'; end if;
  select count(*) into card_count from public.cards where user_id = owner_id;
  if card_count <> 1 then raise exception '2: cards not merged (% cards)', card_count; end if;
  if not exists (select 1 from public.cards where user_id = owner_id and wallet_name = 'Bank A mada Classic' and last4 = '1226' and bank = 'Bank A') then
    raise exception '2: merged card lost wallet name, digits or bank';
  end if;
  if not exists (select 1 from public.expenses where id = first_id and matched and merchant = 'Starbucks Olaya'
                 and card_id = (select id from public.cards where user_id = owner_id)) then
    raise exception '2: expense not matched, merchant not kept, or card not linked';
  end if;

  -- 3. A retry of the same SMS is a plain duplicate, not a new expense.
  r := public.capture_payment(owner_id, hash, 'purchase', 'sms', 25.50, 'SAR', 'Starbucks Ol', t0 + interval '3 minutes', 'food', null, 'Bank A', '1226');
  if not (r->>'duplicate')::boolean then raise exception '3: retry not deduplicated'; end if;

  -- 4. Two real 15 SAR payments 5 minutes apart, each reported twice, stay two.
  perform public.capture_payment(owner_id, hash, 'purchase', 'apple_pay', 15, null, 'Kudu', t0 + interval '1 hour', 'food', 'Bank A mada Classic', null, null);
  perform public.capture_payment(owner_id, hash, 'purchase', 'apple_pay', 15, null, 'Kudu', t0 + interval '1 hour 5 minutes', 'food', 'Bank A mada Classic', null, null);
  perform public.capture_payment(owner_id, hash, 'purchase', 'sms', 15, 'SAR', 'KUDU', t0 + interval '1 hour 1 minute', 'food', null, 'Bank A', '1226');
  perform public.capture_payment(owner_id, hash, 'purchase', 'sms', 15, 'SAR', 'KUDU', t0 + interval '1 hour 6 minutes', 'food', null, 'Bank A', '1226');
  select count(*) into n from public.expenses where user_id = owner_id and amount = 15;
  if n <> 2 or exists (select 1 from public.expenses where user_id = owner_id and amount = 15 and not matched) then
    raise exception '4: expected 2 matched 15 SAR expenses, got %', n;
  end if;

  -- 5. An SMS from a different bank's card with the same amount nearby is
  --    not merged into the Bank A Wallet payment.
  perform public.capture_payment(owner_id, hash, 'purchase', 'apple_pay', 40, null, 'Jarir', t0 + interval '2 hours', 'shopping', 'Bank A mada Classic', null, null);
  r := public.capture_payment(owner_id, hash, 'purchase', 'sms', 40, 'SAR', 'Noon', t0 + interval '2 hours 2 minutes', 'shopping', null, 'Bank B', '9999');
  if coalesce((r->>'merged')::boolean, false) then raise exception '5: different card merged: %', r; end if;

  -- 6. Partial refund applies to the purchase; a resent refund applies once.
  r := public.capture_payment(owner_id, hash, 'refund', 'sms', 10, 'SAR', 'Starbucks', t0 + interval '1 day', null, null, 'Bank A', '1226');
  if not (r->>'matched')::boolean or (r->>'expense_id')::uuid <> first_id then raise exception '6: refund not matched: %', r; end if;
  r := public.capture_payment(owner_id, hash, 'refund', 'sms', 10, 'SAR', 'Starbucks', t0 + interval '1 day', null, null, 'Bank A', '1226');
  if not (r->>'duplicate')::boolean then raise exception '6: resent refund applied twice'; end if;
  if (select refunded_amount from public.expenses where id = first_id) <> 10 then raise exception '6: wrong refunded amount'; end if;

  -- 7. A refund larger than any remaining balance is kept but changes nothing.
  r := public.capture_payment(owner_id, hash, 'refund', 'sms', 500, 'SAR', 'Unknown', t0 + interval '2 days', null, null, null, null);
  if (r->>'matched')::boolean then raise exception '7: unmatched refund was applied'; end if;
  if (select sum(refunded_amount) from public.expenses where user_id = owner_id) <> 10 then raise exception '7: unmatched refund changed spending'; end if;

  -- 8. A wrong token is refused.
  begin
    perform public.capture_payment(owner_id, pg_catalog.repeat('0', 64), 'purchase', 'sms', 1, 'SAR', 'X', t0, 'other', null, null, null);
    raise exception '8: wrong token accepted';
  exception when sqlstate '28000' then null;
  end;

  -- 9. A refund cannot exceed the purchase (constraint).
  begin
    update public.expenses set refunded_amount = amount + 1 where id = first_id;
    raise exception '9: over-refund accepted';
  exception when check_violation then null;
  end;
end;
$$;

-- 10. Clients cannot call capture_payment or create cards.
set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub', '00000000-0000-4000-a000-000000000051', true);
do $$
begin
  begin
    perform public.capture_payment('00000000-0000-4000-a000-000000000051', pg_catalog.repeat('0', 64), 'purchase', 'sms', 1, 'SAR', 'X', pg_catalog.now(), 'other', null, null, null);
    raise exception '10: authenticated executed capture_payment';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.cards (user_id, last4) values ('00000000-0000-4000-a000-000000000051', '1111');
    raise exception '10: authenticated inserted a card';
  exception when insufficient_privilege then null;
  end;
  if (select count(*) from public.cards) <> 2 then raise exception '10: owner cannot read own cards'; end if;
  update public.cards set nickname = 'Daily card' where last4 = '1226';
  if not found then raise exception '10: owner cannot rename card'; end if;
end;
$$;
reset role;
select 'ALL 005 CHECKS PASSED' as result;
