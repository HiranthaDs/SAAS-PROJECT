create extension if not exists pgcrypto;

do $$ begin
  create type public.platform_role as enum ('user', 'super_admin');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.membership_role as enum ('owner', 'admin', 'manager', 'member', 'viewer');
exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text,
  avatar_url text,
  platform_role public.platform_role not null default 'user',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  owner_id uuid not null references auth.users(id),
  industry text,
  email text,
  phone text,
  address text,
  logo_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.memberships (
  org_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.membership_role not null default 'member',
  status text not null default 'active' check (status in ('invited','active','suspended')),
  created_at timestamptz not null default now(),
  primary key (org_id, user_id)
);
create index if not exists memberships_user_id_idx on public.memberships(user_id);

create table if not exists public.organization_settings (
  org_id uuid primary key references public.organizations(id) on delete cascade,
  currency text not null default 'USD',
  timezone text not null default 'Asia/Colombo',
  locale text not null default 'en-US',
  fiscal_year_start integer not null default 1 check (fiscal_year_start between 1 and 12),
  enabled_modules jsonb not null default '["crm","sales","finance","inventory","people","projects","marketing","commerce","productivity"]'::jsonb,
  preferences jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.contacts (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  kind text not null default 'customer', name text not null, company text, email text, phone text, address text,
  tags text[] not null default '{}', created_by uuid references auth.users(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists contacts_org_id_idx on public.contacts(org_id);

create table if not exists public.opportunities (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  company text not null, title text not null, stage text not null default 'New' check (stage in ('New','Qualified','Proposal','Won','Lost')),
  value numeric(14,2) not null default 0, probability integer not null default 10 check (probability between 0 and 100),
  owner_id uuid references auth.users(id), expected_close date, notes text, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists opportunities_org_id_idx on public.opportunities(org_id);

create table if not exists public.invoices (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  number text not null, customer text not null, issue_date date not null default current_date, due_date date,
  status text not null default 'Draft' check (status in ('Draft','Pending','Paid','Overdue','Cancelled')),
  currency text not null default 'USD', subtotal numeric(14,2) not null default 0, tax numeric(14,2) not null default 0,
  total numeric(14,2) generated always as (subtotal + tax) stored, notes text, created_by uuid references auth.users(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(org_id, number)
);
create index if not exists invoices_org_id_idx on public.invoices(org_id);

create table if not exists public.invoice_items (
  id uuid primary key default gen_random_uuid(), invoice_id uuid not null references public.invoices(id) on delete cascade,
  description text not null, quantity numeric(12,2) not null default 1, unit_price numeric(14,2) not null default 0,
  line_total numeric(14,2) generated always as (quantity * unit_price) stored
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  sku text not null, name text not null, category text, product_type text not null default 'stockable', price numeric(14,2) not null default 0,
  cost numeric(14,2) not null default 0, stock numeric(14,2) not null default 0, forecast numeric(14,2) not null default 0,
  reorder_level numeric(14,2) not null default 0, active boolean not null default true, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(org_id, sku)
);
create index if not exists products_org_id_idx on public.products(org_id);

create table if not exists public.warehouses (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  name text not null, code text not null, address text, capacity integer, active boolean not null default true, unique(org_id, code)
);
create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  product_id uuid not null references public.products(id), warehouse_id uuid references public.warehouses(id), movement_type text not null check (movement_type in ('receipt','delivery','transfer','adjustment')),
  quantity numeric(14,2) not null, reference text, moved_at timestamptz not null default now(), created_by uuid references auth.users(id)
);
create index if not exists stock_movements_org_id_idx on public.stock_movements(org_id);

create table if not exists public.employees (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid references auth.users(id), name text not null, email text, role_title text, department text, employment_status text not null default 'active',
  start_date date, manager_id uuid references public.employees(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists employees_org_id_idx on public.employees(org_id);

create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  name text not null, client text, status text not null default 'On track', start_date date, due_date date,
  progress integer not null default 0 check (progress between 0 and 100), budget numeric(14,2) not null default 0,
  manager_id uuid references auth.users(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists projects_org_id_idx on public.projects(org_id);

create table if not exists public.project_tasks (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade, title text not null, status text not null default 'todo', priority text not null default 'normal',
  assignee_id uuid references auth.users(id), due_date date, estimated_hours numeric(8,2), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.timesheets (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  project_id uuid references public.projects(id), task_id uuid references public.project_tasks(id), user_id uuid not null references auth.users(id),
  work_date date not null default current_date, hours numeric(6,2) not null check (hours > 0), description text, billable boolean not null default true, created_at timestamptz not null default now()
);

create table if not exists public.tickets (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  number text not null, subject text not null, customer text, priority text not null default 'normal', status text not null default 'open',
  assignee_id uuid references auth.users(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(org_id, number)
);
create table if not exists public.campaigns (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  name text not null, channel text not null, status text not null default 'Draft', audience_size integer not null default 0,
  engagement_rate numeric(6,2) not null default 0, scheduled_at timestamptz, created_by uuid references auth.users(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.website_pages (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  title text not null, slug text not null, page_type text not null default 'page', status text not null default 'draft', content jsonb not null default '{}'::jsonb,
  seo jsonb not null default '{}'::jsonb, published_at timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(org_id, slug)
);
create table if not exists public.knowledge_articles (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  title text not null, content text, visibility text not null default 'workspace', created_by uuid references auth.users(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.approvals (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  request_type text not null, title text not null, amount numeric(14,2), status text not null default 'pending', requester_id uuid not null references auth.users(id),
  approver_id uuid references auth.users(id), decided_at timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.activity_log (
  id bigint generated always as identity primary key, org_id uuid not null references public.organizations(id) on delete cascade,
  actor_id uuid references auth.users(id), action text not null, entity_type text, entity_id text, metadata jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);

create or replace function public.is_platform_admin()
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.profiles where id = (select auth.uid()) and platform_role = 'super_admin');
$$;
create or replace function public.is_org_member(target_org uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_platform_admin() or exists(select 1 from public.memberships where org_id = target_org and user_id = (select auth.uid()) and status = 'active');
$$;
create or replace function public.can_manage_org(target_org uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_platform_admin() or exists(select 1 from public.memberships where org_id = target_org and user_id = (select auth.uid()) and status = 'active' and role in ('owner','admin','manager'));
$$;

create or replace function public.touch_updated_at() returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end $$;
do $$ declare tab text; begin
  foreach tab in array array['profiles','organizations','contacts','opportunities','invoices','products','employees','projects','project_tasks','tickets','campaigns','website_pages','knowledge_articles','approvals'] loop
    execute format('drop trigger if exists touch_updated_at on public.%I', tab);
    execute format('create trigger touch_updated_at before update on public.%I for each row execute function public.touch_updated_at()', tab);
  end loop;
end $$;

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
declare new_org uuid; company text; base_slug text;
begin
  company := coalesce(new.raw_user_meta_data->>'company_name', split_part(new.email, '@', 1) || ' Workspace');
  base_slug := trim(both '-' from regexp_replace(lower(company), '[^a-z0-9]+', '-', 'g'));
  insert into public.profiles(id,email,full_name,platform_role)
  values(new.id,new.email,coalesce(new.raw_user_meta_data->>'full_name',split_part(new.email,'@',1)),case when lower(new.email)='cs.hichweb@gmail.com' then 'super_admin'::public.platform_role else 'user'::public.platform_role end)
  on conflict(id) do update set email=excluded.email;
  insert into public.organizations(name,slug,owner_id,email) values(company,base_slug || '-' || left(replace(new.id::text,'-',''),6),new.id,new.email) returning id into new_org;
  insert into public.memberships(org_id,user_id,role,status) values(new_org,new.id,'owner','active');
  insert into public.organization_settings(org_id) values(new_org);
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

alter table public.profiles enable row level security;
alter table public.organizations enable row level security;
alter table public.memberships enable row level security;
alter table public.organization_settings enable row level security;
do $$ declare tab text; begin
  foreach tab in array array['contacts','opportunities','invoices','products','warehouses','stock_movements','employees','projects','project_tasks','timesheets','tickets','campaigns','website_pages','knowledge_articles','approvals','activity_log'] loop
    execute format('alter table public.%I enable row level security', tab);
  end loop;
end $$;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (id=(select auth.uid()) or public.is_platform_admin() or exists(select 1 from public.memberships mine join public.memberships theirs on mine.org_id=theirs.org_id where mine.user_id=(select auth.uid()) and theirs.user_id=profiles.id));
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated using (id=(select auth.uid()) or public.is_platform_admin()) with check (id=(select auth.uid()) or public.is_platform_admin());

drop policy if exists organizations_select on public.organizations;
create policy organizations_select on public.organizations for select to authenticated using (public.is_org_member(id));
drop policy if exists organizations_insert on public.organizations;
create policy organizations_insert on public.organizations for insert to authenticated with check (owner_id=(select auth.uid()) or public.is_platform_admin());
drop policy if exists organizations_update on public.organizations;
create policy organizations_update on public.organizations for update to authenticated using (public.can_manage_org(id)) with check (public.can_manage_org(id));
drop policy if exists organizations_delete on public.organizations;
create policy organizations_delete on public.organizations for delete to authenticated using (owner_id=(select auth.uid()) or public.is_platform_admin());

drop policy if exists memberships_select on public.memberships;
create policy memberships_select on public.memberships for select to authenticated using (public.is_org_member(org_id));
drop policy if exists memberships_insert on public.memberships;
create policy memberships_insert on public.memberships for insert to authenticated with check (public.can_manage_org(org_id));
drop policy if exists memberships_update on public.memberships;
create policy memberships_update on public.memberships for update to authenticated using (public.can_manage_org(org_id)) with check (public.can_manage_org(org_id));
drop policy if exists memberships_delete on public.memberships;
create policy memberships_delete on public.memberships for delete to authenticated using (public.can_manage_org(org_id));

drop policy if exists organization_settings_select on public.organization_settings;
create policy organization_settings_select on public.organization_settings for select to authenticated using (public.is_org_member(org_id));
drop policy if exists organization_settings_update on public.organization_settings;
create policy organization_settings_update on public.organization_settings for update to authenticated using (public.can_manage_org(org_id)) with check (public.can_manage_org(org_id));

do $$ declare tab text; begin
  foreach tab in array array['contacts','opportunities','invoices','products','warehouses','stock_movements','employees','projects','project_tasks','timesheets','tickets','campaigns','website_pages','knowledge_articles','approvals','activity_log'] loop
    execute format('drop policy if exists %I on public.%I', tab || '_select', tab);
    execute format('create policy %I on public.%I for select to authenticated using (public.is_org_member(org_id))', tab || '_select', tab);
    execute format('drop policy if exists %I on public.%I', tab || '_insert', tab);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.is_org_member(org_id))', tab || '_insert', tab);
    execute format('drop policy if exists %I on public.%I', tab || '_update', tab);
    execute format('create policy %I on public.%I for update to authenticated using (public.is_org_member(org_id)) with check (public.is_org_member(org_id))', tab || '_update', tab);
    execute format('drop policy if exists %I on public.%I', tab || '_delete', tab);
    execute format('create policy %I on public.%I for delete to authenticated using (public.can_manage_org(org_id))', tab || '_delete', tab);
  end loop;
end $$;

alter table public.invoice_items enable row level security;
drop policy if exists invoice_items_select on public.invoice_items;
create policy invoice_items_select on public.invoice_items for select to authenticated using (exists(select 1 from public.invoices i where i.id=invoice_id and public.is_org_member(i.org_id)));
drop policy if exists invoice_items_write on public.invoice_items;
create policy invoice_items_write on public.invoice_items for all to authenticated using (exists(select 1 from public.invoices i where i.id=invoice_id and public.is_org_member(i.org_id))) with check (exists(select 1 from public.invoices i where i.id=invoice_id and public.is_org_member(i.org_id)));

grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function public.is_platform_admin(), public.is_org_member(uuid), public.can_manage_org(uuid) to authenticated;
