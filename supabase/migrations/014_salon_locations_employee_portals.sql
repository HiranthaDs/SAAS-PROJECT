-- Permanent location-specific employee portals and branch-aware salon operations.

create table if not exists public.salon_locations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  code text,
  city text,
  address text,
  phone text,
  employee_login_slug text not null unique,
  active boolean not null default true,
  is_primary boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(org_id,name)
);

create unique index if not exists salon_locations_one_primary_idx
  on public.salon_locations(org_id) where is_primary;
create index if not exists salon_locations_org_idx on public.salon_locations(org_id,active,name);

create or replace function public.prepare_salon_location()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_org_slug text; v_base text;
begin
  if tg_op='UPDATE' and old.employee_login_slug is distinct from new.employee_login_slug then
    raise exception 'The permanent employee login link cannot be changed';
  end if;
  if tg_op='INSERT' and nullif(trim(new.employee_login_slug),'') is null then
    select slug into v_org_slug from public.organizations where id=new.org_id;
    v_base:=trim(both '-' from regexp_replace(lower(coalesce(v_org_slug,'salon')||'-'||new.name),'[^a-z0-9]+','-','g'));
    new.employee_login_slug:=v_base||'-'||lower(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  end if;
  new.updated_at:=now();
  return new;
end $$;

drop trigger if exists prepare_salon_location on public.salon_locations;
create trigger prepare_salon_location before insert or update on public.salon_locations
for each row execute function public.prepare_salon_location();

alter table public.employees add column if not exists location_id uuid references public.salon_locations(id) on delete set null;
alter table public.salon_appointments add column if not exists location_id uuid references public.salon_locations(id) on delete restrict;
alter table public.salon_unavailability add column if not exists location_id uuid references public.salon_locations(id) on delete cascade;
alter table public.organization_user_access add column if not exists location_id uuid references public.salon_locations(id) on delete set null;

create index if not exists employees_location_idx on public.employees(org_id,location_id,employment_status);
create index if not exists salon_appointments_location_time_idx on public.salon_appointments(org_id,location_id,starts_at);
create index if not exists salon_unavailability_location_time_idx on public.salon_unavailability(org_id,location_id,starts_at,ends_at);
create index if not exists organization_user_access_location_idx on public.organization_user_access(org_id,location_id);

insert into public.salon_locations(org_id,name,code,city,address,phone,employee_login_slug,is_primary,created_by)
select o.id,o.name||' Main','MAIN',null,o.address,o.phone,
  trim(both '-' from regexp_replace(lower(o.slug||'-main'),'[^a-z0-9]+','-','g'))||'-'||lower(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
  true,o.owner_id
from public.organizations o
where o.business_type='salon'
  and not exists(select 1 from public.salon_locations l where l.org_id=o.id);

update public.employees e set location_id=(select l.id from public.salon_locations l where l.org_id=e.org_id order by l.is_primary desc,l.created_at limit 1)
where e.location_id is null and exists(select 1 from public.salon_locations l where l.org_id=e.org_id);

update public.salon_appointments a set location_id=coalesce(
  (select e.location_id from public.employees e where e.id=a.staff_id),
  (select l.id from public.salon_locations l where l.org_id=a.org_id order by l.is_primary desc,l.created_at limit 1)
)
where a.location_id is null;

update public.salon_unavailability u set location_id=coalesce(
  (select e.location_id from public.employees e where e.id=u.staff_id),
  (select l.id from public.salon_locations l where l.org_id=u.org_id order by l.is_primary desc,l.created_at limit 1)
)
where u.location_id is null;

update public.organization_user_access a set location_id=(
  select e.location_id from public.employees e where e.org_id=a.org_id and e.user_id=a.user_id limit 1
)
where a.location_id is null
  and not exists(select 1 from public.profiles p where p.id=a.user_id and p.platform_role='super_admin');

create or replace function public.assign_primary_salon_location()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.location_id is null then
    if tg_table_name='employees' then
      select id into new.location_id from public.salon_locations where org_id=new.org_id and active=true order by is_primary desc,created_at limit 1;
    elsif tg_table_name='salon_appointments' then
      if new.staff_id is not null then select location_id into new.location_id from public.employees where id=new.staff_id; end if;
      if new.location_id is null then select id into new.location_id from public.salon_locations where org_id=new.org_id and active=true order by is_primary desc,created_at limit 1; end if;
    elsif tg_table_name='salon_unavailability' then
      if new.staff_id is not null then select location_id into new.location_id from public.employees where id=new.staff_id; end if;
      if new.location_id is null then select id into new.location_id from public.salon_locations where org_id=new.org_id and active=true order by is_primary desc,created_at limit 1; end if;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists assign_primary_salon_location on public.employees;
create trigger assign_primary_salon_location before insert on public.employees for each row execute function public.assign_primary_salon_location();
drop trigger if exists assign_primary_salon_location on public.salon_appointments;
create trigger assign_primary_salon_location before insert on public.salon_appointments for each row execute function public.assign_primary_salon_location();
drop trigger if exists assign_primary_salon_location on public.salon_unavailability;
create trigger assign_primary_salon_location before insert on public.salon_unavailability for each row execute function public.assign_primary_salon_location();

create or replace function public.ensure_salon_primary_location()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.business_type='salon' and not exists(select 1 from public.salon_locations where org_id=new.id) then
    insert into public.salon_locations(org_id,name,code,address,phone,employee_login_slug,is_primary,created_by)
    values(new.id,new.name||' Main','MAIN',new.address,new.phone,
      trim(both '-' from regexp_replace(lower(new.slug||'-main'),'[^a-z0-9]+','-','g'))||'-'||lower(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
      true,new.owner_id);
  end if;
  return new;
end $$;

drop trigger if exists ensure_salon_primary_location on public.organizations;
create trigger ensure_salon_primary_location after insert or update of business_type on public.organizations
for each row execute function public.ensure_salon_primary_location();

create or replace function public.can_access_salon_location(target_org uuid,target_location uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_platform_admin()
  or exists(select 1 from public.organizations o where o.id=target_org and o.owner_id=(select auth.uid()))
  or exists(
    select 1 from public.memberships m
    join public.organization_user_access a on a.org_id=m.org_id and a.user_id=m.user_id
    where m.org_id=target_org and m.user_id=(select auth.uid()) and m.status='active'
      and a.location_id=target_location
  );
$$;

alter table public.salon_locations enable row level security;
drop policy if exists salon_locations_select on public.salon_locations;
create policy salon_locations_select on public.salon_locations for select to authenticated
using (public.is_platform_admin() or exists(select 1 from public.organizations o where o.id=salon_locations.org_id and o.owner_id=(select auth.uid())) or exists(
  select 1 from public.organization_user_access a
  where a.org_id=salon_locations.org_id and a.user_id=(select auth.uid()) and a.location_id=salon_locations.id
));
drop policy if exists salon_locations_insert on public.salon_locations;
create policy salon_locations_insert on public.salon_locations for insert to authenticated with check(public.is_platform_admin());
drop policy if exists salon_locations_update on public.salon_locations;
create policy salon_locations_update on public.salon_locations for update to authenticated using(public.is_platform_admin()) with check(public.is_platform_admin());
drop policy if exists salon_locations_delete on public.salon_locations;
create policy salon_locations_delete on public.salon_locations for delete to authenticated using(public.is_platform_admin());

drop policy if exists employees_select on public.employees;
create policy employees_select on public.employees for select to authenticated
using (
  public.is_platform_admin()
  or (location_id is not null and public.can_access_salon_location(org_id,location_id))
  or (location_id is null and public.is_org_member(org_id))
);

drop policy if exists salon_appointments_select on public.salon_appointments;
create policy salon_appointments_select on public.salon_appointments for select to authenticated
using (public.can_access_salon_location(org_id,location_id));
drop policy if exists salon_appointments_insert on public.salon_appointments;
create policy salon_appointments_insert on public.salon_appointments for insert to authenticated
with check(public.has_org_permission(org_id,'salon_create') and public.can_access_salon_location(org_id,location_id));
drop policy if exists salon_appointments_update on public.salon_appointments;
create policy salon_appointments_update on public.salon_appointments for update to authenticated
using(public.has_org_permission(org_id,'salon_manage') and public.can_access_salon_location(org_id,location_id))
with check(public.has_org_permission(org_id,'salon_manage') and public.can_access_salon_location(org_id,location_id));
drop policy if exists salon_appointments_delete on public.salon_appointments;
create policy salon_appointments_delete on public.salon_appointments for delete to authenticated
using(public.has_org_permission(org_id,'salon_manage') and public.can_access_salon_location(org_id,location_id));

drop policy if exists salon_unavailability_select on public.salon_unavailability;
create policy salon_unavailability_select on public.salon_unavailability for select to authenticated
using(public.can_access_salon_location(org_id,location_id));
drop policy if exists salon_unavailability_insert on public.salon_unavailability;
create policy salon_unavailability_insert on public.salon_unavailability for insert to authenticated
with check(public.has_org_permission(org_id,'salon_manage') and public.can_access_salon_location(org_id,location_id));
drop policy if exists salon_unavailability_update on public.salon_unavailability;
create policy salon_unavailability_update on public.salon_unavailability for update to authenticated
using(public.has_org_permission(org_id,'salon_manage') and public.can_access_salon_location(org_id,location_id))
with check(public.has_org_permission(org_id,'salon_manage') and public.can_access_salon_location(org_id,location_id));
drop policy if exists salon_unavailability_delete on public.salon_unavailability;
create policy salon_unavailability_delete on public.salon_unavailability for delete to authenticated
using(public.has_org_permission(org_id,'salon_manage') and public.can_access_salon_location(org_id,location_id));

create or replace function public.create_salon_location(
  p_org_id uuid,p_name text,p_code text default null,p_city text default null,
  p_address text default null,p_phone text default null,p_is_primary boolean default false
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_location public.salon_locations%rowtype; v_primary boolean;
begin
  if not public.is_platform_admin() then raise exception 'Only a super administrator can create locations'; end if;
  if nullif(trim(p_name),'') is null then raise exception 'Location name is required'; end if;
  if not exists(select 1 from public.organizations where id=p_org_id and business_type='salon') then raise exception 'Salon workspace not found'; end if;
  v_primary:=p_is_primary or not exists(select 1 from public.salon_locations where org_id=p_org_id);
  if v_primary then update public.salon_locations set is_primary=false where org_id=p_org_id; end if;
  insert into public.salon_locations(org_id,name,code,city,address,phone,employee_login_slug,is_primary,created_by)
  values(p_org_id,trim(p_name),nullif(upper(trim(p_code)),''),nullif(trim(p_city),''),nullif(trim(p_address),''),nullif(trim(p_phone),''),'',v_primary,auth.uid())
  returning * into v_location;
  insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_org_id,auth.uid(),'salon.location.created','salon_location',v_location.id::text,jsonb_build_object('name',v_location.name,'city',v_location.city));
  return to_jsonb(v_location);
end $$;

create or replace function public.update_salon_location(
  p_location_id uuid,p_name text,p_code text default null,p_city text default null,
  p_address text default null,p_phone text default null,p_active boolean default true,p_is_primary boolean default false
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_location public.salon_locations%rowtype;
begin
  if not public.is_platform_admin() then raise exception 'Only a super administrator can update locations'; end if;
  select * into v_location from public.salon_locations where id=p_location_id for update;
  if v_location.id is null then raise exception 'Location not found'; end if;
  if nullif(trim(p_name),'') is null then raise exception 'Location name is required'; end if;
  if not p_active and v_location.is_primary then raise exception 'Choose another primary location before deactivating this one'; end if;
  if v_location.is_primary and not p_is_primary then raise exception 'Choose another location as primary before removing this primary location'; end if;
  if p_is_primary then update public.salon_locations set is_primary=false where org_id=v_location.org_id and id<>v_location.id; end if;
  update public.salon_locations set name=trim(p_name),code=nullif(upper(trim(p_code)),''),city=nullif(trim(p_city),''),
    address=nullif(trim(p_address),''),phone=nullif(trim(p_phone),''),active=p_active,is_primary=p_is_primary
  where id=v_location.id returning * into v_location;
  insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_location.org_id,auth.uid(),'salon.location.updated','salon_location',v_location.id::text,jsonb_build_object('name',v_location.name,'active',v_location.active));
  return to_jsonb(v_location);
end $$;

create or replace function public.get_employee_login_portal(p_slug text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_location public.salon_locations%rowtype; v_org public.organizations%rowtype;
begin
  select * into v_location from public.salon_locations where employee_login_slug=p_slug and active=true;
  if v_location.id is null then raise exception 'This employee login link is unavailable'; end if;
  select * into v_org from public.organizations where id=v_location.org_id;
  return jsonb_build_object('portal_slug',v_location.employee_login_slug,'location_id',v_location.id,'location_name',v_location.name,
    'city',v_location.city,'address',v_location.address,'phone',coalesce(v_location.phone,v_org.phone),'salon_name',v_org.name);
end $$;

create or replace function public.validate_employee_login_portal(p_slug text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_location public.salon_locations%rowtype; v_access public.organization_user_access%rowtype; v_org public.organizations%rowtype;
begin
  if public.is_platform_admin() then raise exception 'Super administrators must use the main login page'; end if;
  select * into v_location from public.salon_locations where employee_login_slug=p_slug and active=true;
  if v_location.id is null then raise exception 'This employee login link is unavailable'; end if;
  select * into v_access from public.organization_user_access a
  where a.user_id=auth.uid() and a.org_id=v_location.org_id and a.location_id=v_location.id;
  if v_access.user_id is null or not exists(select 1 from public.memberships m where m.org_id=v_location.org_id and m.user_id=auth.uid() and m.status='active') then
    raise exception 'This account is not assigned to this salon location';
  end if;
  select * into v_org from public.organizations where id=v_location.org_id;
  return jsonb_build_object('authorized',true,'org_id',v_location.org_id,'location_id',v_location.id,
    'location_name',v_location.name,'salon_name',v_org.name,'permissions',v_access.permissions);
end $$;

create or replace function public.get_public_salon_booking(p_slug text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_org public.organizations%rowtype; v_settings public.organization_settings%rowtype; v_services jsonb; v_locations jsonb; v_capacity integer;
begin
  select * into v_org from public.organizations where booking_slug=p_slug and business_type='salon';
  if v_org.id is null then raise exception 'This booking link is unavailable'; end if;
  select * into v_settings from public.organization_settings where org_id=v_org.id;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'category',coalesce(category,'Services'),'description',description,
    'duration_minutes',duration_minutes,'price',price) order by category,name),'[]'::jsonb)
  into v_services from public.salon_services where org_id=v_org.id and active=true;
  select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'name',l.name,'city',l.city,'address',l.address,'phone',coalesce(l.phone,v_org.phone),
    'is_primary',l.is_primary,'capacity',(select count(*) from public.employees e where e.location_id=l.id and e.employment_status='active' and e.bookable_for_appointments=true))
    order by l.is_primary desc,l.name),'[]'::jsonb)
  into v_locations from public.salon_locations l where l.org_id=v_org.id and l.active=true;
  select count(*) into v_capacity from public.employees where org_id=v_org.id and employment_status='active' and bookable_for_appointments=true;
  return jsonb_build_object('salon',jsonb_build_object('name',v_org.name,'phone',v_org.phone,'address',v_org.address,'slug',v_org.booking_slug),
    'services',v_services,'locations',v_locations,'opening_time',coalesce(v_settings.preferences->>'opening_time','09:00'),
    'closing_time',coalesce(v_settings.preferences->>'closing_time','19:00'),'booking_interval',coalesce((v_settings.preferences->>'booking_interval')::integer,30),
    'capacity',greatest(v_capacity,1));
end $$;

drop function if exists public.get_public_salon_availability(text,uuid,date,date);
create or replace function public.get_public_salon_availability(
  p_slug text,p_service_id uuid,p_from_date date,p_to_date date,p_location_id uuid default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_org public.organizations%rowtype; v_location public.salon_locations%rowtype; v_settings public.organization_settings%rowtype;
  v_service public.salon_services%rowtype; v_opening time; v_closing time; v_interval integer; v_timezone text; v_capacity integer;
  v_day date; v_minute integer; v_start timestamptz; v_end timestamptz; v_remaining integer; v_slots jsonb; v_days jsonb:='[]'::jsonb;
begin
  select * into v_org from public.organizations where booking_slug=p_slug and business_type='salon';
  if v_org.id is null then raise exception 'This booking link is unavailable'; end if;
  select * into v_location from public.salon_locations where id=p_location_id and org_id=v_org.id and active=true;
  if v_location.id is null then select * into v_location from public.salon_locations where org_id=v_org.id and active=true order by is_primary desc,created_at limit 1; end if;
  if v_location.id is null then raise exception 'No salon location is available'; end if;
  select * into v_service from public.salon_services where id=p_service_id and org_id=v_org.id and active=true;
  if v_service.id is null then raise exception 'Service is unavailable'; end if;
  if p_from_date<current_date or p_to_date<p_from_date or p_to_date>p_from_date+30 or p_to_date>current_date+180 then raise exception 'Choose an availability range within the next 180 days'; end if;
  select * into v_settings from public.organization_settings where org_id=v_org.id;
  v_opening:=coalesce(v_settings.preferences->>'opening_time','09:00')::time;v_closing:=coalesce(v_settings.preferences->>'closing_time','19:00')::time;
  v_interval:=greatest(15,coalesce((v_settings.preferences->>'booking_interval')::integer,30));v_timezone:=coalesce(v_settings.timezone,'Asia/Colombo');
  select count(*) into v_capacity from public.employees where location_id=v_location.id and employment_status='active' and bookable_for_appointments=true;
  v_capacity:=greatest(v_capacity,1);
  for v_day in select generate_series(p_from_date,p_to_date,interval '1 day')::date loop
    v_slots:='[]'::jsonb;v_minute:=0;
    while v_opening+make_interval(mins=>v_minute)<v_closing loop
      v_start:=((v_day+v_opening+make_interval(mins=>v_minute)) at time zone v_timezone);v_end:=v_start+make_interval(mins=>v_service.duration_minutes);
      if (v_end at time zone v_timezone)::date<>v_day or (v_end at time zone v_timezone)::time>v_closing or v_start<=now()+interval '30 minutes' then v_remaining:=0;
      elsif exists(select 1 from public.salon_unavailability u where u.location_id=v_location.id and u.staff_id is null and tstzrange(u.starts_at,u.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')) then v_remaining:=0;
      elsif exists(select 1 from public.employees e where e.location_id=v_location.id and e.employment_status='active' and e.bookable_for_appointments=true) then
        select count(*) into v_remaining from public.employees e where e.location_id=v_location.id and e.employment_status='active' and e.bookable_for_appointments=true
          and not exists(select 1 from public.salon_appointments a where a.location_id=v_location.id and a.staff_id=e.id and a.status not in ('cancelled','no_show') and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)'))
          and not exists(select 1 from public.salon_unavailability u where u.location_id=v_location.id and u.staff_id=e.id and tstzrange(u.starts_at,u.ends_at,'[)')&&tstzrange(v_start,v_end,'[)'));
      elsif exists(select 1 from public.salon_appointments a where a.location_id=v_location.id and a.staff_id is null and a.status not in ('cancelled','no_show') and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')) then v_remaining:=0;
      else v_remaining:=1; end if;
      v_slots:=v_slots||jsonb_build_array(jsonb_build_object('time',to_char(v_start at time zone v_timezone,'HH24:MI'),'starts_at',v_start,'available',v_remaining>0,'remaining',v_remaining,'capacity',v_capacity));
      v_minute:=v_minute+v_interval;
    end loop;
    v_days:=v_days||jsonb_build_array(jsonb_build_object('date',to_char(v_day,'YYYY-MM-DD'),'available',exists(select 1 from jsonb_array_elements(v_slots) slot(value) where (value->>'available')::boolean),'slots',v_slots));
  end loop;
  return jsonb_build_object('service_id',v_service.id,'service_name',v_service.name,'location_id',v_location.id,'location_name',v_location.name,'duration_minutes',v_service.duration_minutes,'capacity',v_capacity,'days',v_days);
end $$;

drop function if exists public.book_public_salon_appointment(text,uuid,text,text,text,timestamptz,text);
create or replace function public.book_public_salon_appointment(
  p_slug text,p_service_id uuid,p_customer_name text,p_customer_phone text,p_customer_email text,
  p_starts_at timestamptz,p_notes text default null,p_location_id uuid default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_org public.organizations%rowtype;v_location public.salon_locations%rowtype;v_settings public.organization_settings%rowtype;v_service public.salon_services%rowtype;
  v_customer public.retail_customers%rowtype;v_staff public.employees%rowtype;v_phone text;v_ends_at timestamptz;v_appointment uuid;
  v_opening time;v_closing time;v_local_start timestamp;v_local_end timestamp;v_capacity integer;
begin
  select * into v_org from public.organizations where booking_slug=p_slug and business_type='salon';if v_org.id is null then raise exception 'This booking link is unavailable';end if;
  select * into v_location from public.salon_locations where id=p_location_id and org_id=v_org.id and active=true;
  if v_location.id is null then select * into v_location from public.salon_locations where org_id=v_org.id and active=true order by is_primary desc,created_at limit 1;end if;
  if v_location.id is null then raise exception 'No salon location is available';end if;
  if nullif(trim(p_customer_name),'') is null then raise exception 'Customer name is required';end if;
  v_phone:=public.normalize_phone(p_customer_phone);if length(regexp_replace(v_phone,'\D','','g'))<9 then raise exception 'Enter a valid phone number';end if;
  if p_starts_at<=now()+interval '30 minutes' or p_starts_at>now()+interval '180 days' then raise exception 'Choose an available future time';end if;
  select * into v_service from public.salon_services where id=p_service_id and org_id=v_org.id and active=true;if v_service.id is null then raise exception 'Service is unavailable';end if;
  v_ends_at:=p_starts_at+make_interval(mins=>v_service.duration_minutes);select * into v_settings from public.organization_settings where org_id=v_org.id;
  v_opening:=coalesce(v_settings.preferences->>'opening_time','09:00')::time;v_closing:=coalesce(v_settings.preferences->>'closing_time','19:00')::time;
  v_local_start:=p_starts_at at time zone coalesce(v_settings.timezone,'Asia/Colombo');v_local_end:=v_ends_at at time zone coalesce(v_settings.timezone,'Asia/Colombo');
  if v_local_start::date<>v_local_end::date or v_local_start::time<v_opening or v_local_end::time>v_closing then raise exception 'This service must fit within salon opening hours';end if;
  if exists(select 1 from public.salon_unavailability u where u.location_id=v_location.id and u.staff_id is null and tstzrange(u.starts_at,u.ends_at,'[)')&&tstzrange(p_starts_at,v_ends_at,'[)')) then raise exception 'This location is unavailable at that time';end if;
  select count(*) into v_capacity from public.employees where location_id=v_location.id and employment_status='active' and bookable_for_appointments=true;
  select * into v_staff from public.employees e where e.location_id=v_location.id and e.employment_status='active' and e.bookable_for_appointments=true
    and not exists(select 1 from public.salon_appointments a where a.location_id=v_location.id and a.staff_id=e.id and a.status not in ('cancelled','no_show') and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(p_starts_at,v_ends_at,'[)'))
    and not exists(select 1 from public.salon_unavailability u where u.location_id=v_location.id and u.staff_id=e.id and tstzrange(u.starts_at,u.ends_at,'[)')&&tstzrange(p_starts_at,v_ends_at,'[)'))
    order by e.name limit 1 for update of e skip locked;
  if v_capacity>0 and v_staff.id is null then raise exception 'That time is fully booked at this location';end if;
  if v_staff.id is null and exists(select 1 from public.salon_appointments a where a.location_id=v_location.id and a.staff_id is null and a.status not in ('cancelled','no_show') and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(p_starts_at,v_ends_at,'[)')) then raise exception 'That time is already booked';end if;
  insert into public.retail_customers(org_id,customer_code,name,phone,phone_normalized,email,preferred_language,tags,marketing_consent)
  values(v_org.id,'CUS-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),trim(p_customer_name),trim(p_customer_phone),v_phone,nullif(trim(p_customer_email),''),'English',array['salon-booking'],false)
  on conflict(org_id,phone_normalized) do update set name=excluded.name,email=coalesce(excluded.email,retail_customers.email),updated_at=now() returning * into v_customer;
  insert into public.salon_appointments(org_id,location_id,customer_id,customer_name,customer_phone,customer_email,service_id,service_name,staff_id,staff_name,starts_at,ends_at,price,status,notes,source,reminder_status)
  values(v_org.id,v_location.id,v_customer.id,v_customer.name,v_customer.phone,v_customer.email,v_service.id,v_service.name,v_staff.id,v_staff.name,p_starts_at,v_ends_at,v_service.price,'booked',nullif(trim(p_notes),''),'public_booking','pending') returning id into v_appointment;
  return jsonb_build_object('appointment_id',v_appointment,'salon',v_org.name,'salon_phone',coalesce(v_location.phone,v_org.phone),'salon_address',coalesce(v_location.address,v_org.address),
    'location',v_location.name,'location_id',v_location.id,'service',v_service.name,'price',v_service.price,'starts_at',p_starts_at,'ends_at',v_ends_at,'staff',v_staff.name,'status','booked');
end $$;

create or replace function public.move_salon_appointment_kanban(p_appointment_id uuid,p_stage text,p_responsible_employee_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_appointment public.salon_appointments%rowtype;v_responsible public.employees%rowtype;v_status text;
begin
  if p_stage not in ('pending','call','confirmed','complete') then raise exception 'Invalid workflow stage';end if;
  select * into v_appointment from public.salon_appointments where id=p_appointment_id for update;
  if v_appointment.id is null or not public.can_access_salon_location(v_appointment.org_id,v_appointment.location_id) then raise exception 'Appointment not found or access denied';end if;
  if p_stage is distinct from v_appointment.workflow_stage then
    if p_stage='confirmed' and not public.has_org_permission(v_appointment.org_id,'salon_approve') then raise exception 'You do not have permission to confirm appointments';
    elsif p_stage<>'confirmed' and not public.has_org_permission(v_appointment.org_id,'salon_move') then raise exception 'You do not have permission to move appointments';end if;
  end if;
  if p_responsible_employee_id is distinct from v_appointment.responsible_employee_id and not public.has_org_permission(v_appointment.org_id,'salon_allocate') then raise exception 'You do not have permission to allocate a responsible person';end if;
  if p_responsible_employee_id is not null then
    select * into v_responsible from public.employees where id=p_responsible_employee_id and location_id=v_appointment.location_id and employment_status='active';
    if v_responsible.id is null then raise exception 'Responsible person must belong to this location';end if;
  end if;
  v_status:=case p_stage when 'confirmed' then 'confirmed' when 'complete' then 'completed' else 'booked' end;
  update public.salon_appointments set workflow_stage=p_stage,status=v_status,responsible_employee_id=v_responsible.id,responsible_name=v_responsible.name where id=v_appointment.id;
  insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_appointment.org_id,auth.uid(),'salon.appointment.workflow_changed','salon_appointment',v_appointment.id::text,
    jsonb_build_object('location_id',v_appointment.location_id,'customer',v_appointment.customer_name,'service',v_appointment.service_name,'from_stage',v_appointment.workflow_stage,'to_stage',p_stage,'responsible_person',v_responsible.name));
  return jsonb_build_object('id',v_appointment.id,'workflow_stage',p_stage,'status',v_status,'responsible_employee_id',v_responsible.id,'responsible_name',v_responsible.name);
end $$;

grant select,insert,update,delete on public.salon_locations to authenticated;
grant execute on function public.can_access_salon_location(uuid,uuid) to authenticated;
grant execute on function public.create_salon_location(uuid,text,text,text,text,text,boolean) to authenticated;
grant execute on function public.update_salon_location(uuid,text,text,text,text,text,boolean,boolean) to authenticated;
grant execute on function public.get_employee_login_portal(text) to anon,authenticated;
grant execute on function public.validate_employee_login_portal(text) to authenticated;
grant execute on function public.get_public_salon_availability(text,uuid,date,date,uuid) to anon,authenticated;
grant execute on function public.book_public_salon_appointment(text,uuid,text,text,text,timestamptz,text,uuid) to anon,authenticated;

