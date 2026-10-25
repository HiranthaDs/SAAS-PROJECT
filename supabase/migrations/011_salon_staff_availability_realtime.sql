-- Salon staff capacity, blocked time, and realtime appointment updates.

alter table public.employees add column if not exists bookable_for_appointments boolean not null default false;
update public.employees employees
set bookable_for_appointments=true
from public.organizations organizations
where employees.org_id=organizations.id
  and organizations.business_type='salon'
  and employees.employment_status='active';

create table if not exists public.salon_unavailability (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  staff_id uuid references public.employees(id) on delete cascade,
  kind text not null default 'time_off' check(kind in ('time_off','salon_closed','blocked')),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  reason text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check(ends_at>starts_at),
  check((kind='salon_closed' and staff_id is null) or kind<>'salon_closed')
);
create index if not exists salon_unavailability_org_time_idx on public.salon_unavailability(org_id,starts_at,ends_at);
create index if not exists salon_unavailability_staff_time_idx on public.salon_unavailability(staff_id,starts_at,ends_at);

alter table public.salon_unavailability enable row level security;
drop policy if exists salon_unavailability_select on public.salon_unavailability;
create policy salon_unavailability_select on public.salon_unavailability for select to authenticated
using(public.is_org_member(org_id));
drop policy if exists salon_unavailability_insert on public.salon_unavailability;
create policy salon_unavailability_insert on public.salon_unavailability for insert to authenticated
with check(public.is_org_member(org_id));
drop policy if exists salon_unavailability_update on public.salon_unavailability;
create policy salon_unavailability_update on public.salon_unavailability for update to authenticated
using(public.is_org_member(org_id)) with check(public.is_org_member(org_id));
drop policy if exists salon_unavailability_delete on public.salon_unavailability;
create policy salon_unavailability_delete on public.salon_unavailability for delete to authenticated
using(public.is_org_member(org_id));
grant select,insert,update,delete on public.salon_unavailability to authenticated;

create or replace function public.configure_business(
  p_org_id uuid,
  p_business_type text,
  p_company_name text,
  p_legal_name text,
  p_phone text,
  p_email text,
  p_address text,
  p_registration_number text,
  p_tax_number text,
  p_branch_count integer,
  p_employee_count integer,
  p_preferences jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_modules jsonb; v_existing_staff integer; v_index integer;
begin
  if not public.can_manage_org(p_org_id) then raise exception 'Only a workspace manager can configure this company'; end if;
  if p_business_type not in ('retail_grocery','pharmacy','salon','automotive','general_erp') then raise exception 'Choose a valid business type'; end if;
  if nullif(trim(p_company_name),'') is null then raise exception 'Company name is required'; end if;
  if coalesce(p_branch_count,0)<1 or coalesce(p_employee_count,0)<1 then raise exception 'Branches and employees must be at least 1'; end if;
  v_modules:=public.modules_for_business_type(p_business_type);
  update public.organizations set name=trim(p_company_name),legal_name=nullif(trim(p_legal_name),''),phone=nullif(trim(p_phone),''),
    email=nullif(trim(p_email),''),address=nullif(trim(p_address),''),registration_number=nullif(trim(p_registration_number),''),
    tax_number=nullif(trim(p_tax_number),''),branch_count=p_branch_count,employee_count=p_employee_count,
    industry=p_business_type,business_type=p_business_type where id=p_org_id;
  update public.organization_settings set currency='LKR',timezone='Asia/Colombo',enabled_modules=v_modules,
    preferences=coalesce(preferences,'{}'::jsonb)||coalesce(p_preferences,'{}'::jsonb)||jsonb_build_object('onboarding_completed',true,'configured_at',now(),'configured_by',auth.uid())
    where org_id=p_org_id;

  if p_business_type='salon' then
    select count(*) into v_existing_staff from public.employees
    where org_id=p_org_id and employment_status='active' and bookable_for_appointments=true;
    if v_existing_staff<p_employee_count then
      for v_index in (v_existing_staff+1)..p_employee_count loop
        insert into public.employees(org_id,name,role_title,department,employment_status,bookable_for_appointments)
        values(p_org_id,'Staff member '||v_index,'Salon specialist','Salon','active',true);
      end loop;
    end if;
  end if;

  insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_org_id,auth.uid(),'business_configured','organization',p_org_id::text,jsonb_build_object('business_type',p_business_type,'modules',v_modules));
  return jsonb_build_object('configured',true,'business_type',p_business_type,'enabled_modules',v_modules);
end $$;

grant execute on function public.configure_business(uuid,text,text,text,text,text,text,text,text,integer,integer,jsonb) to authenticated;

create or replace function public.get_public_salon_booking(p_slug text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_org public.organizations%rowtype; v_settings public.organization_settings%rowtype; v_services jsonb; v_capacity integer;
begin
  select * into v_org from public.organizations where booking_slug=p_slug and business_type='salon';
  if v_org.id is null then raise exception 'This booking link is unavailable'; end if;
  select * into v_settings from public.organization_settings where org_id=v_org.id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'name',name,'category',coalesce(category,'Services'),'description',description,
    'duration_minutes',duration_minutes,'price',price
  ) order by category,name),'[]'::jsonb) into v_services from public.salon_services where org_id=v_org.id and active=true;
  select count(*) into v_capacity from public.employees
  where org_id=v_org.id and employment_status='active' and bookable_for_appointments=true;
  return jsonb_build_object(
    'salon',jsonb_build_object('name',v_org.name,'phone',v_org.phone,'address',v_org.address,'slug',v_org.booking_slug),
    'services',v_services,
    'opening_time',coalesce(v_settings.preferences->>'opening_time','09:00'),
    'closing_time',coalesce(v_settings.preferences->>'closing_time','19:00'),
    'booking_interval',coalesce((v_settings.preferences->>'booking_interval')::integer,30),
    'capacity',greatest(v_capacity,1)
  );
end $$;

create or replace function public.book_public_salon_appointment(
  p_slug text,p_service_id uuid,p_customer_name text,p_customer_phone text,p_customer_email text,
  p_starts_at timestamptz,p_notes text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_org public.organizations%rowtype;
  v_settings public.organization_settings%rowtype;
  v_service public.salon_services%rowtype;
  v_customer public.retail_customers%rowtype;
  v_staff public.employees%rowtype;
  v_phone text;
  v_ends_at timestamptz;
  v_appointment uuid;
  v_opening time;
  v_closing time;
  v_local_start timestamp;
  v_local_end timestamp;
  v_capacity integer;
begin
  select * into v_org from public.organizations where booking_slug=p_slug and business_type='salon';
  if v_org.id is null then raise exception 'This booking link is unavailable'; end if;
  if nullif(trim(p_customer_name),'') is null then raise exception 'Customer name is required'; end if;
  v_phone:=public.normalize_phone(p_customer_phone);
  if length(regexp_replace(v_phone,'\D','','g'))<9 then raise exception 'Enter a valid phone number'; end if;
  if p_starts_at<=now()+interval '30 minutes' or p_starts_at>now()+interval '180 days' then raise exception 'Choose an available future time'; end if;
  select * into v_service from public.salon_services where id=p_service_id and org_id=v_org.id and active=true;
  if v_service.id is null then raise exception 'Service is unavailable'; end if;
  v_ends_at:=p_starts_at+make_interval(mins=>v_service.duration_minutes);
  select * into v_settings from public.organization_settings where org_id=v_org.id;
  v_opening:=coalesce(v_settings.preferences->>'opening_time','09:00')::time;
  v_closing:=coalesce(v_settings.preferences->>'closing_time','19:00')::time;
  v_local_start:=p_starts_at at time zone coalesce(v_settings.timezone,'Asia/Colombo');
  v_local_end:=v_ends_at at time zone coalesce(v_settings.timezone,'Asia/Colombo');
  if v_local_start::date<>v_local_end::date or v_local_start::time<v_opening or v_local_end::time>v_closing then
    raise exception 'This service must fit within salon opening hours';
  end if;
  if exists(select 1 from public.salon_unavailability u where u.org_id=v_org.id and u.staff_id is null
    and tstzrange(u.starts_at,u.ends_at,'[)')&&tstzrange(p_starts_at,v_ends_at,'[)')) then
    raise exception 'The salon is unavailable at that time. Please choose another time';
  end if;

  select count(*) into v_capacity from public.employees where org_id=v_org.id
    and employment_status='active' and bookable_for_appointments=true;
  select * into v_staff from public.employees e where e.org_id=v_org.id
    and e.employment_status='active' and e.bookable_for_appointments=true
    and not exists(select 1 from public.salon_appointments a where a.org_id=v_org.id and a.staff_id=e.id
      and a.status not in ('cancelled','no_show') and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(p_starts_at,v_ends_at,'[)'))
    and not exists(select 1 from public.salon_unavailability u where u.org_id=v_org.id and u.staff_id=e.id
      and tstzrange(u.starts_at,u.ends_at,'[)')&&tstzrange(p_starts_at,v_ends_at,'[)'))
    order by e.name limit 1 for update of e skip locked;
  if v_capacity>0 and v_staff.id is null then
    raise exception 'That time is fully booked. Please choose another time';
  end if;
  if v_staff.id is null and exists(select 1 from public.salon_appointments a where a.org_id=v_org.id and a.staff_id is null
    and a.status not in ('cancelled','no_show') and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(p_starts_at,v_ends_at,'[)')) then
    raise exception 'That time is already booked. Please choose another time';
  end if;

  insert into public.retail_customers(org_id,customer_code,name,phone,phone_normalized,email,preferred_language,tags,marketing_consent)
  values(v_org.id,'CUS-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),trim(p_customer_name),trim(p_customer_phone),v_phone,
    nullif(trim(p_customer_email),''),'English',array['salon-booking'],false)
  on conflict(org_id,phone_normalized) do update set name=excluded.name,email=coalesce(excluded.email,retail_customers.email),updated_at=now()
  returning * into v_customer;

  insert into public.salon_appointments(org_id,customer_id,customer_name,customer_phone,customer_email,service_id,service_name,
    staff_id,staff_name,starts_at,ends_at,price,status,notes,source,reminder_status)
  values(v_org.id,v_customer.id,v_customer.name,v_customer.phone,v_customer.email,v_service.id,v_service.name,v_staff.id,v_staff.name,
    p_starts_at,v_ends_at,v_service.price,'booked',nullif(trim(p_notes),''),'public_booking','pending') returning id into v_appointment;
  return jsonb_build_object('appointment_id',v_appointment,'salon',v_org.name,'salon_phone',v_org.phone,'salon_address',v_org.address,
    'service',v_service.name,'price',v_service.price,'starts_at',p_starts_at,'ends_at',v_ends_at,'staff',v_staff.name,'status','booked');
end $$;

grant execute on function public.get_public_salon_booking(text) to anon,authenticated;
grant execute on function public.book_public_salon_appointment(text,uuid,text,text,text,timestamptz,text) to anon,authenticated;

do $$
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='salon_appointments') then
      execute 'alter publication supabase_realtime add table public.salon_appointments';
    end if;
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='salon_unavailability') then
      execute 'alter publication supabase_realtime add table public.salon_unavailability';
    end if;
  end if;
end $$;
