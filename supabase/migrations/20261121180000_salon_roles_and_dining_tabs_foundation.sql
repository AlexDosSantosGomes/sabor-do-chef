create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

create table if not exists public.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  role text not null check (role in ('DELIVERY','SALON')),
  is_active boolean not null default true,
  created_by uuid references public.admin_profiles(user_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.user_roles enable row level security;
grant select, insert, update, delete on public.user_roles to authenticated;

create table if not exists public.dining_tabs (
  id uuid primary key default gen_random_uuid(),
  table_id uuid not null references public.restaurant_tables(id),
  status text not null default 'OPEN' check (status in ('OPEN','CLOSED')),
  opened_by uuid references auth.users(id),
  closed_by uuid references auth.users(id),
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  closing_note text,
  check ((status = 'OPEN' and closed_at is null) or (status = 'CLOSED' and closed_at is not null))
);
create unique index if not exists dining_tabs_one_open_per_table
on public.dining_tabs(table_id) where status = 'OPEN';
create index if not exists dining_tabs_table_status_idx
on public.dining_tabs(table_id,status,opened_at desc);
alter table public.dining_tabs enable row level security;
grant select, insert, update on public.dining_tabs to authenticated;

create or replace function private.is_active_admin()
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.admin_profiles ap
    where ap.user_id = auth.uid() and ap.is_active = true);
$$;
create or replace function private.has_staff_role(p_role text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.user_roles ur
    where ur.user_id = auth.uid() and ur.role = p_role and ur.is_active = true);
$$;
revoke all on function private.is_active_admin() from public;
revoke all on function private.has_staff_role(text) from public;
grant execute on function private.is_active_admin() to authenticated;
grant execute on function private.has_staff_role(text) to authenticated;

drop policy if exists user_roles_admin_manage on public.user_roles;
create policy user_roles_admin_manage on public.user_roles
for all to authenticated using (private.is_active_admin())
with check (private.is_active_admin());
drop policy if exists user_roles_read_own on public.user_roles;
create policy user_roles_read_own on public.user_roles
for select to authenticated using (user_id = auth.uid());

drop policy if exists dining_tabs_admin_all on public.dining_tabs;
create policy dining_tabs_admin_all on public.dining_tabs
for all to authenticated using (private.is_active_admin())
with check (private.is_active_admin());
drop policy if exists dining_tabs_salon_read on public.dining_tabs;
create policy dining_tabs_salon_read on public.dining_tabs
for select to authenticated using (private.has_staff_role('SALON'));
drop policy if exists dining_tabs_salon_insert on public.dining_tabs;
create policy dining_tabs_salon_insert on public.dining_tabs
for insert to authenticated
with check (private.has_staff_role('SALON') and opened_by = auth.uid());
drop policy if exists dining_tabs_salon_update on public.dining_tabs;
create policy dining_tabs_salon_update on public.dining_tabs
for update to authenticated using (private.has_staff_role('SALON'))
with check (private.has_staff_role('SALON'));

drop policy if exists restaurant_tables_salon_read on public.restaurant_tables;
create policy restaurant_tables_salon_read on public.restaurant_tables
for select to authenticated using (private.has_staff_role('SALON'));
drop policy if exists orders_salon_read on public.orders;
create policy orders_salon_read on public.orders
for select to authenticated using (order_type = 'SALAO' and private.has_staff_role('SALON'));
drop policy if exists order_items_salon_read on public.order_items;
create policy order_items_salon_read on public.order_items
for select to authenticated using (exists (
  select 1 from public.orders o where o.id = order_items.order_id
    and o.order_type = 'SALAO' and private.has_staff_role('SALON')
));
