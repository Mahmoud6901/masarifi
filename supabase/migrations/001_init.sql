-- Masarifi schema. Run in Supabase SQL editor or via `supabase db push`.

-- Supabase keeps optional extensions in `extensions`; qualify pgcrypto below
-- so the profile default does not depend on a migration's search_path.
create extension if not exists pgcrypto with schema extensions;

create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  currency text not null default 'SAR' check (currency ~ '^[A-Z]{3}$'),
  monthly_income numeric(12,2) not null default 0 check (monthly_income >= 0),
  ingest_token text not null unique default pg_catalog.encode(extensions.gen_random_bytes(24), 'hex'),
  created_at timestamptz not null default pg_catalog.now()
);

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  amount numeric(12,2) not null check (amount >= 0),
  currency text not null default 'SAR',
  merchant text not null,
  category text not null default 'other',
  note text,
  source text not null default 'manual' check (source in ('apple_pay', 'manual')),
  spent_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index expenses_user_spent on public.expenses (user_id, spent_at desc);

create table public.installment_plans (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  name text not null,
  provider text not null default '',
  kind text not null default 'other' check (kind in ('loan', 'bnpl', 'card', 'other')),
  total_amount numeric(12,2) not null check (total_amount >= 0),
  monthly_amount numeric(12,2) not null check (monthly_amount >= 0),
  total_count int not null check (total_count > 0),
  paid_count int not null default 0 check (paid_count >= 0),
  due_day int not null check (due_day between 1 and 28),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check (paid_count <= total_count)
);

alter table public.profiles enable row level security;
alter table public.expenses enable row level security;
alter table public.installment_plans enable row level security;

create policy "own profile" on public.profiles
  for select to authenticated using (auth.uid() = id);
create policy "update own profile preferences" on public.profiles
  for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);
create policy "own expenses" on public.expenses
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own installments" on public.installment_plans
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Create a profile automatically for each new user.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Client privileges are explicit; RLS supplies the per-user row boundary.
revoke all privileges on table public.profiles, public.expenses, public.installment_plans
  from public, anon, authenticated;
revoke all privileges (id, currency, monthly_income, ingest_token, created_at)
  on table public.profiles from public, anon, authenticated;
grant select on table public.profiles to authenticated;
grant update (currency, monthly_income) on public.profiles to authenticated;
grant select, insert, update, delete on table public.expenses, public.installment_plans
  to authenticated;

-- Service-role functions (including ingest and agent) retain table access.
grant all privileges on table public.profiles, public.expenses, public.installment_plans
  to service_role;

-- The profile is trigger-created; clients cannot call its trigger function or
-- insert/delete profiles to replace the server-generated ingest token.
revoke all on function public.handle_new_user() from public, anon, authenticated;
