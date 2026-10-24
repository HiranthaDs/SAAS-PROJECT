alter table public.organizations drop constraint if exists organizations_owner_id_fkey;
alter table public.organizations add constraint organizations_owner_id_fkey foreign key(owner_id) references auth.users(id) on delete cascade;
alter table public.approvals alter column requester_id drop not null;

do $$ declare item record; begin
  for item in select * from (values
    ('contacts','created_by'),('opportunities','owner_id'),('invoices','created_by'),('stock_movements','created_by'),
    ('employees','user_id'),('projects','manager_id'),('project_tasks','assignee_id'),('tickets','assignee_id'),
    ('campaigns','created_by'),('knowledge_articles','created_by'),('approvals','requester_id'),('approvals','approver_id'),('activity_log','actor_id')
  ) as refs(tab,col) loop
    execute format('alter table public.%I drop constraint if exists %I',item.tab,item.tab||'_'||item.col||'_fkey');
    execute format('alter table public.%I add constraint %I foreign key(%I) references auth.users(id) on delete set null',item.tab,item.tab||'_'||item.col||'_fkey',item.col);
  end loop;
end $$;
alter table public.timesheets drop constraint if exists timesheets_user_id_fkey;
alter table public.timesheets add constraint timesheets_user_id_fkey foreign key(user_id) references auth.users(id) on delete cascade;

create table if not exists public.purchase_orders (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  number text not null, vendor text not null, order_date date not null default current_date, expected_date date, status text not null default 'draft',
  currency text not null default 'USD', total numeric(14,2) not null default 0, buyer_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(org_id,number)
);
create table if not exists public.bills_of_materials (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade, name text not null, version integer not null default 1,
  components jsonb not null default '[]'::jsonb, operations jsonb not null default '[]'::jsonb, active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.manufacturing_orders (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  number text not null, product_id uuid references public.products(id), bom_id uuid references public.bills_of_materials(id), quantity numeric(14,2) not null,
  status text not null default 'planned', work_center text, scheduled_start timestamptz, scheduled_end timestamptz, progress integer not null default 0,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(org_id,number)
);
create table if not exists public.quality_checks (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  manufacturing_order_id uuid references public.manufacturing_orders(id) on delete cascade, title text not null, check_type text not null default 'visual',
  result text not null default 'pending', notes text, checked_by uuid references auth.users(id) on delete set null, checked_at timestamptz, created_at timestamptz not null default now()
);
create table if not exists public.maintenance_requests (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  equipment text not null, title text not null, maintenance_type text not null default 'corrective', priority text not null default 'normal',
  status text not null default 'new', scheduled_date date, assigned_to uuid references auth.users(id) on delete set null, notes text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  employee_id uuid references public.employees(id) on delete set null, title text not null, category text, amount numeric(14,2) not null,
  currency text not null default 'USD', expense_date date not null default current_date, status text not null default 'draft', receipt_url text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.leave_requests (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade, leave_type text not null, starts_on date not null, ends_on date not null,
  status text not null default 'pending', reason text, approver_id uuid references auth.users(id) on delete set null, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.candidates (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  job_title text not null, name text not null, email text, phone text, stage text not null default 'applied', source text, resume_url text,
  rating integer check(rating between 1 and 5), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.subscriptions (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  customer text not null, plan_name text not null, amount numeric(14,2) not null, currency text not null default 'USD', interval text not null default 'month',
  status text not null default 'active', starts_on date not null default current_date, renews_on date, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.rental_orders (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  customer text not null, product_id uuid references public.products(id), starts_at timestamptz not null, ends_at timestamptz not null,
  amount numeric(14,2) not null default 0, status text not null default 'reserved', created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.pos_orders (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  session_ref text, receipt_number text not null, customer text, items jsonb not null default '[]'::jsonb, total numeric(14,2) not null,
  payment_method text, status text not null default 'paid', cashier_id uuid references auth.users(id) on delete set null, created_at timestamptz not null default now(), unique(org_id,receipt_number)
);
create table if not exists public.field_service_orders (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  number text not null, customer text not null, address text, title text not null, technician_id uuid references auth.users(id) on delete set null,
  scheduled_at timestamptz, status text not null default 'planned', materials jsonb not null default '[]'::jsonb, notes text, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(org_id,number)
);
create table if not exists public.appointments (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  title text not null, attendee_name text, attendee_email text, host_id uuid references auth.users(id) on delete set null,
  starts_at timestamptz not null, ends_at timestamptz not null, status text not null default 'booked', location text, created_at timestamptz not null default now()
);
create table if not exists public.events (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  name text not null, starts_at timestamptz not null, ends_at timestamptz, venue text, capacity integer, registrations integer not null default 0,
  ticket_price numeric(14,2) not null default 0, status text not null default 'draft', created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.surveys (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  title text not null, questions jsonb not null default '[]'::jsonb, status text not null default 'draft', response_count integer not null default 0,
  created_by uuid references auth.users(id) on delete set null, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.documents (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  name text not null, folder text, mime_type text, storage_path text, size_bytes bigint, owner_id uuid references auth.users(id) on delete set null,
  tags text[] not null default '{}', created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.signature_requests (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  document_id uuid references public.documents(id) on delete cascade, title text not null, signers jsonb not null default '[]'::jsonb,
  status text not null default 'draft', expires_at timestamptz, created_by uuid references auth.users(id) on delete set null, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.fleet_vehicles (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  license_plate text not null, make text, model text, driver_employee_id uuid references public.employees(id) on delete set null, odometer numeric(14,2) not null default 0,
  status text not null default 'active', next_service_date date, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(org_id,license_plate)
);
create table if not exists public.custom_fields (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  entity_type text not null, name text not null, label text not null, field_type text not null, options jsonb not null default '[]'::jsonb,
  required boolean not null default false, created_at timestamptz not null default now(), unique(org_id,entity_type,name)
);
create table if not exists public.automation_rules (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  name text not null, trigger_type text not null, entity_type text not null, conditions jsonb not null default '{}'::jsonb, actions jsonb not null default '[]'::jsonb,
  active boolean not null default true, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

do $$ declare tab text; begin
  foreach tab in array array['purchase_orders','bills_of_materials','manufacturing_orders','quality_checks','maintenance_requests','expenses','leave_requests','candidates','subscriptions','rental_orders','pos_orders','field_service_orders','appointments','events','surveys','documents','signature_requests','fleet_vehicles','custom_fields','automation_rules'] loop
    execute format('create index if not exists %I on public.%I(org_id)',tab||'_org_id_idx',tab);
    execute format('alter table public.%I enable row level security',tab);
    execute format('drop policy if exists %I on public.%I',tab||'_select',tab);
    execute format('create policy %I on public.%I for select to authenticated using (public.is_org_member(org_id))',tab||'_select',tab);
    execute format('drop policy if exists %I on public.%I',tab||'_insert',tab);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.is_org_member(org_id))',tab||'_insert',tab);
    execute format('drop policy if exists %I on public.%I',tab||'_update',tab);
    execute format('create policy %I on public.%I for update to authenticated using (public.is_org_member(org_id)) with check (public.is_org_member(org_id))',tab||'_update',tab);
    execute format('drop policy if exists %I on public.%I',tab||'_delete',tab);
    execute format('create policy %I on public.%I for delete to authenticated using (public.can_manage_org(org_id))',tab||'_delete',tab);
  end loop;
end $$;
do $$ declare tab text; begin
  foreach tab in array array['purchase_orders','bills_of_materials','manufacturing_orders','maintenance_requests','expenses','leave_requests','candidates','subscriptions','rental_orders','field_service_orders','events','surveys','documents','signature_requests','fleet_vehicles','automation_rules'] loop
    execute format('drop trigger if exists touch_updated_at on public.%I',tab);
    execute format('create trigger touch_updated_at before update on public.%I for each row execute function public.touch_updated_at()',tab);
  end loop;
end $$;
grant select,insert,update,delete on all tables in schema public to authenticated;
grant usage,select on all sequences in schema public to authenticated;
