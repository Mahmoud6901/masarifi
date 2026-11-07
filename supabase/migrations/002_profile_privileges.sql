-- Upgrade an installation that already ran the original 001_init.sql.
-- Fresh installations also run this safely after the hardened 001 migration.

create extension if not exists pgcrypto with schema extensions;

alter table public.profiles
  alter column ingest_token set default pg_catalog.encode(extensions.gen_random_bytes(24), 'hex');

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.profiles'::pg_catalog.regclass
      and conname = 'profiles_currency_check'
  ) then
    alter table public.profiles
      add constraint profiles_currency_check check (currency ~ '^[A-Z]{3}$');
  end if;

  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.profiles'::pg_catalog.regclass
      and conname = 'profiles_monthly_income_check'
  ) then
    alter table public.profiles
      add constraint profiles_monthly_income_check check (monthly_income >= 0);
  end if;
end $$;

drop policy if exists "own profile" on public.profiles;
drop policy if exists "update own profile preferences" on public.profiles;
create policy "own profile" on public.profiles
  for select to authenticated using (auth.uid() = id);
create policy "update own profile preferences" on public.profiles
  for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

drop policy if exists "own expenses" on public.expenses;
create policy "own expenses" on public.expenses
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "own installments" on public.installment_plans;
create policy "own installments" on public.installment_plans
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

alter table public.profiles enable row level security;
alter table public.expenses enable row level security;
alter table public.installment_plans enable row level security;

revoke all privileges on table public.profiles, public.expenses, public.installment_plans
  from public, anon, authenticated;
revoke all privileges (id, currency, monthly_income, ingest_token, created_at)
  on table public.profiles from public, anon, authenticated;
grant select on table public.profiles to authenticated;
grant update (currency, monthly_income) on public.profiles to authenticated;
grant select, insert, update, delete on table public.expenses, public.installment_plans
  to authenticated;
grant all privileges on table public.profiles, public.expenses, public.installment_plans
  to service_role;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end $$;
revoke all on function public.handle_new_user() from public, anon, authenticated;
