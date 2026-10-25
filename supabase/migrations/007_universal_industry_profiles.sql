-- Industry-aware onboarding and focused operating modules.

alter table public.organizations add column if not exists business_type text;
update public.organizations set business_type=coalesce(nullif(industry,''),'general_erp') where business_type is null;
update public.organizations set business_type='retail_grocery',industry='retail_grocery'
where exists(select 1 from public.products p where p.org_id=organizations.id and p.sku like 'GR-%');

create or replace function public.modules_for_business_type(target_type text) returns jsonb
language sql immutable as $$
  select case target_type
    when 'retail_grocery' then '["overview","pos","customers","inventory","finance","people"]'::jsonb
    when 'pharmacy' then '["overview","pharmacy","pos","customers","inventory","finance","people"]'::jsonb
    when 'salon' then '["overview","salon","pos","customers","inventory","finance","people"]'::jsonb
    when 'automotive' then '["overview","automotive","customers","inventory","finance","people"]'::jsonb
    else '["overview","sales","finance","inventory","people","services"]'::jsonb
  end
$$;

update public.organization_settings s set enabled_modules=public.modules_for_business_type(o.business_type)
from public.organizations o where o.id=s.org_id;

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
declare new_org uuid; company text; base_slug text; selected_type text;
begin
  company := coalesce(new.raw_user_meta_data->>'company_name', split_part(new.email, '@', 1) || ' Workspace');
  selected_type := coalesce(nullif(new.raw_user_meta_data->>'business_type',''),'general_erp');
  if selected_type not in ('retail_grocery','pharmacy','salon','automotive','general_erp') then selected_type := 'general_erp'; end if;
  base_slug := trim(both '-' from regexp_replace(lower(company), '[^a-z0-9]+', '-', 'g'));
  insert into public.profiles(id,email,full_name,platform_role)
  values(new.id,new.email,coalesce(new.raw_user_meta_data->>'full_name',split_part(new.email,'@',1)),case when lower(new.email)='cs.hichweb@gmail.com' then 'super_admin'::public.platform_role else 'user'::public.platform_role end)
  on conflict(id) do update set email=excluded.email;
  insert into public.organizations(name,slug,owner_id,email,industry,business_type)
  values(company,base_slug || '-' || left(replace(new.id::text,'-',''),6),new.id,new.email,selected_type,selected_type) returning id into new_org;
  insert into public.memberships(org_id,user_id,role,status) values(new_org,new.id,'owner','active');
  insert into public.organization_settings(org_id,currency,enabled_modules)
  values(new_org,'LKR',public.modules_for_business_type(selected_type));
  return new;
end $$;

create table if not exists public.pharmacy_prescriptions (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  number text not null, patient_name text not null, patient_phone text, prescriber text not null,
  items jsonb not null default '[]'::jsonb, notes text,
  status text not null default 'pending' check(status in ('pending','verified','dispensed','cancelled')),
  verified_by uuid references auth.users(id) on delete set null, dispensed_by uuid references auth.users(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(org_id,number)
);
create table if not exists public.pharmacy_batches (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade, batch_number text not null,
  expiry_date date not null, quantity numeric(14,3) not null default 0 check(quantity>=0),
  purchase_price numeric(14,2) not null default 0, controlled boolean not null default false,
  supplier text, created_at timestamptz not null default now(), unique(org_id,product_id,batch_number)
);

create table if not exists public.salon_services (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  name text not null, category text, duration_minutes integer not null default 60 check(duration_minutes>0),
  price numeric(14,2) not null default 0, commission_rate numeric(6,3) not null default 0,
  active boolean not null default true, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(org_id,name)
);
create table if not exists public.salon_appointments (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid references public.retail_customers(id) on delete set null, customer_name text not null, customer_phone text,
  service_id uuid references public.salon_services(id) on delete set null, service_name text not null,
  staff_id uuid references public.employees(id) on delete set null, staff_name text,
  starts_at timestamptz not null, ends_at timestamptz not null, price numeric(14,2) not null default 0,
  status text not null default 'booked' check(status in ('booked','confirmed','in_service','completed','no_show','cancelled')),
  notes text, created_by uuid references auth.users(id) on delete set null, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.vehicles (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid references public.retail_customers(id) on delete set null, registration_number text not null,
  make text, model text, manufacture_year integer, vin text, current_mileage numeric(14,2) not null default 0,
  notes text, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(org_id,registration_number)
);
create table if not exists public.workshop_job_cards (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  number text not null, vehicle_id uuid not null references public.vehicles(id) on delete restrict,
  customer_name text not null, customer_phone text, complaint text not null,
  inspection jsonb not null default '{}'::jsonb, labor_items jsonb not null default '[]'::jsonb, parts_items jsonb not null default '[]'::jsonb,
  estimate_amount numeric(14,2) not null default 0, actual_amount numeric(14,2) not null default 0,
  odometer_in numeric(14,2) not null default 0, promised_at timestamptz,
  technician_id uuid references public.employees(id) on delete set null,
  status text not null default 'check_in' check(status in ('check_in','inspection','approval','in_progress','quality_check','ready','delivered','cancelled')),
  created_by uuid references auth.users(id) on delete set null, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(org_id,number)
);

do $$ declare tab text; begin
  foreach tab in array array['pharmacy_prescriptions','pharmacy_batches','salon_services','salon_appointments','vehicles','workshop_job_cards'] loop
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
  foreach tab in array array['pharmacy_prescriptions','salon_services','salon_appointments','vehicles','workshop_job_cards'] loop
    execute format('drop trigger if exists touch_updated_at on public.%I',tab);
    execute format('create trigger touch_updated_at before update on public.%I for each row execute function public.touch_updated_at()',tab);
  end loop;
end $$;

create or replace function public.advance_prescription(p_prescription_id uuid) returns text
language plpgsql security definer set search_path=public as $$
declare v_rx public.pharmacy_prescriptions%rowtype; v_item jsonb; v_product public.products%rowtype; v_qty numeric;
begin
  select * into v_rx from public.pharmacy_prescriptions where id=p_prescription_id for update;
  if v_rx.id is null or not public.is_org_member(v_rx.org_id) then raise exception 'Prescription not found or access denied'; end if;
  if v_rx.status='pending' then
    update public.pharmacy_prescriptions set status='verified',verified_by=auth.uid() where id=v_rx.id; return 'verified';
  elsif v_rx.status='verified' then
    for v_item in select value from jsonb_array_elements(v_rx.items) loop
      v_qty:=coalesce((v_item->>'quantity')::numeric,0);
      select * into v_product from public.products where id=(v_item->>'product_id')::uuid and org_id=v_rx.org_id for update;
      if v_product.id is null then raise exception 'Medicine not found'; end if;
      if v_product.stock<v_qty then raise exception 'Insufficient stock for %',v_product.name; end if;
      update public.products set stock=stock-v_qty,forecast=forecast-v_qty where id=v_product.id;
      insert into public.stock_movements(org_id,product_id,movement_type,quantity,reference,created_by)
      values(v_rx.org_id,v_product.id,'delivery',-v_qty,v_rx.number,auth.uid());
    end loop;
    update public.pharmacy_prescriptions set status='dispensed',dispensed_by=auth.uid() where id=v_rx.id; return 'dispensed';
  end if;
  raise exception 'Prescription cannot advance from %',v_rx.status;
end $$;

create or replace function public.advance_job_card(p_job_id uuid) returns text
language plpgsql security definer set search_path=public as $$
declare v_job public.workshop_job_cards%rowtype; v_next text;
begin
  select * into v_job from public.workshop_job_cards where id=p_job_id for update;
  if v_job.id is null or not public.is_org_member(v_job.org_id) then raise exception 'Job card not found or access denied'; end if;
  v_next:=case v_job.status when 'check_in' then 'inspection' when 'inspection' then 'approval' when 'approval' then 'in_progress'
    when 'in_progress' then 'quality_check' when 'quality_check' then 'ready' when 'ready' then 'delivered' else null end;
  if v_next is null then raise exception 'Job card cannot advance from %',v_job.status; end if;
  update public.workshop_job_cards set status=v_next where id=v_job.id; return v_next;
end $$;

grant select,insert,update,delete on public.pharmacy_prescriptions,public.pharmacy_batches,public.salon_services,public.salon_appointments,public.vehicles,public.workshop_job_cards to authenticated;
grant execute on function public.modules_for_business_type(text),public.advance_prescription(uuid),public.advance_job_card(uuid) to authenticated;
