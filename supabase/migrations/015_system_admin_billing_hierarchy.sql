-- Three-level administration model:
-- system administrator -> workspace super administrator -> location-bound users.

alter table public.profiles alter column platform_role drop default;
alter table public.profiles alter column platform_role type text using platform_role::text;
alter table public.profiles alter column platform_role set default 'user';
alter table public.profiles drop constraint if exists profiles_platform_role_check;
alter table public.profiles add constraint profiles_platform_role_check
  check(platform_role in ('user','super_admin','system_admin'));

alter table public.organizations
  add column if not exists account_status text not null default 'active' check(account_status in ('active','suspended')),
  add column if not exists billing_status text not null default 'trial' check(billing_status in ('trial','paid','past_due','suspended')),
  add column if not exists access_suspended_at timestamptz,
  add column if not exists access_suspension_reason text,
  add column if not exists access_suspended_by uuid references auth.users(id) on delete set null;

update public.profiles p set platform_role='super_admin'
where p.platform_role='user' and exists(select 1 from public.organizations o where o.owner_id=p.id);
update public.profiles set platform_role='system_admin'
where lower(email)='hiranthadiass4@gmail.com';
update public.profiles p set platform_role='user'
where p.platform_role='super_admin'
  and exists(select 1 from public.organization_user_access access where access.user_id=p.id)
  and not exists(select 1 from public.organizations organization where organization.owner_id=p.id);

create or replace function public.is_system_admin()
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.profiles where id=(select auth.uid()) and platform_role='system_admin');
$$;

-- Legacy helper now means true platform-wide authority only.
create or replace function public.is_platform_admin()
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_system_admin();
$$;

create or replace function public.is_org_super_admin(target_org uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_system_admin() or exists(
    select 1 from public.organizations o
    join public.profiles p on p.id=o.owner_id
    join public.memberships m on m.org_id=o.id and m.user_id=o.owner_id
    where o.id=target_org and o.owner_id=(select auth.uid()) and o.account_status='active'
      and p.platform_role='super_admin' and m.status='active' and m.role='owner'
  );
$$;

create or replace function public.is_org_member(target_org uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_system_admin() or exists(
    select 1 from public.memberships m join public.organizations o on o.id=m.org_id
    where m.org_id=target_org and m.user_id=(select auth.uid()) and m.status='active' and o.account_status='active'
  );
$$;

create or replace function public.can_manage_org(target_org uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_system_admin() or exists(
    select 1 from public.memberships m join public.organizations o on o.id=m.org_id
    where m.org_id=target_org and m.user_id=(select auth.uid()) and m.status='active'
      and m.role in ('owner','admin') and o.account_status='active'
  );
$$;

create or replace function public.has_org_permission(target_org uuid,permission_key text)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_system_admin() or exists(
    select 1 from public.memberships m
    join public.organizations o on o.id=m.org_id and o.account_status='active'
    left join public.organization_user_access a on a.org_id=m.org_id and a.user_id=m.user_id
    where m.org_id=target_org and m.user_id=(select auth.uid()) and m.status='active'
      and case
        when a.permissions ? permission_key then coalesce((a.permissions->>permission_key)::boolean,false)
        when permission_key like '%_view' then true
        else m.role in ('owner','admin','manager')
      end
  );
$$;

create or replace function public.can_access_salon_location(target_org uuid,target_location uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_system_admin()
  or exists(
    select 1 from public.organizations o
    where o.id=target_org and o.owner_id=(select auth.uid()) and o.account_status='active'
  )
  or exists(
    select 1 from public.memberships m
    join public.organizations o on o.id=m.org_id and o.account_status='active'
    join public.organization_user_access a on a.org_id=m.org_id and a.user_id=m.user_id
    where m.org_id=target_org and m.user_id=(select auth.uid()) and m.status='active' and a.location_id=target_location
  );
$$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path=public as $$
declare new_org uuid;company text;base_slug text;assigned_role text;is_system boolean;
begin
  company:=coalesce(new.raw_user_meta_data->>'company_name',split_part(new.email,'@',1)||' Workspace');
  base_slug:=trim(both '-' from regexp_replace(lower(company),'[^a-z0-9]+','-','g'));
  is_system:=lower(new.email)='hiranthadiass4@gmail.com';
  assigned_role:=case
    when is_system then 'system_admin'
    when coalesce(new.raw_user_meta_data->>'provisioning_kind','workspace_owner')='employee' then 'user'
    else 'super_admin'
  end;
  insert into public.profiles(id,email,full_name,platform_role)
  values(new.id,new.email,coalesce(new.raw_user_meta_data->>'full_name',split_part(new.email,'@',1)),assigned_role)
  on conflict(id) do update set email=excluded.email,full_name=excluded.full_name;
  insert into public.organizations(name,slug,owner_id,email,industry,business_type)
  values(company,base_slug||'-'||left(replace(new.id::text,'-',''),6),new.id,new.email,
    case when is_system then 'general_erp' else 'unconfigured' end,
    case when is_system then 'general_erp' else 'unconfigured' end) returning id into new_org;
  insert into public.memberships(org_id,user_id,role,status) values(new_org,new.id,'owner','active');
  insert into public.organization_settings(org_id,currency,enabled_modules,preferences)
  values(new_org,'LKR',case when is_system then '["overview"]'::jsonb else '[]'::jsonb end,
    jsonb_build_object('onboarding_completed',is_system,'setup_step',case when is_system then 4 else 1 end));
  return new;
end $$;

update public.organizations o set industry='general_erp',business_type='general_erp'
where o.owner_id in(select id from public.profiles where platform_role='system_admin')
  and o.business_type='unconfigured';
update public.organization_settings s set
  enabled_modules=case when jsonb_array_length(s.enabled_modules)=0 then '["overview"]'::jsonb else s.enabled_modules end,
  preferences=coalesce(s.preferences,'{}'::jsonb)||jsonb_build_object('onboarding_completed',true,'setup_step',4)
where s.org_id in(
  select o.id from public.organizations o join public.profiles p on p.id=o.owner_id where p.platform_role='system_admin'
);

-- A user may update only their first-login flag. Role changes remain server-side.
revoke update on table public.profiles from authenticated;
grant update(must_change_password) on table public.profiles to authenticated;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using(
  id=(select auth.uid()) or public.is_system_admin() or exists(
    select 1 from public.memberships target_membership
    where target_membership.user_id=profiles.id and public.is_org_member(target_membership.org_id)
  )
);

drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
using(id=(select auth.uid()) or public.is_system_admin())
with check(id=(select auth.uid()) or public.is_system_admin());

drop policy if exists organizations_insert on public.organizations;
create policy organizations_insert on public.organizations for insert to authenticated
with check(public.is_system_admin());
drop policy if exists organizations_delete on public.organizations;
create policy organizations_delete on public.organizations for delete to authenticated
using(public.is_system_admin() or public.is_org_super_admin(id));

drop policy if exists activity_log_select on public.activity_log;
create policy activity_log_select on public.activity_log for select to authenticated
using(actor_id=(select auth.uid()) or public.is_system_admin() or public.is_org_super_admin(org_id));

drop policy if exists organization_user_access_select on public.organization_user_access;
create policy organization_user_access_select on public.organization_user_access for select to authenticated
using(user_id=(select auth.uid()) or public.is_org_super_admin(org_id));
drop policy if exists organization_user_access_insert on public.organization_user_access;
create policy organization_user_access_insert on public.organization_user_access for insert to authenticated
with check(public.is_org_super_admin(org_id));
drop policy if exists organization_user_access_update on public.organization_user_access;
create policy organization_user_access_update on public.organization_user_access for update to authenticated
using(public.is_org_super_admin(org_id)) with check(public.is_org_super_admin(org_id));
drop policy if exists organization_user_access_delete on public.organization_user_access;
create policy organization_user_access_delete on public.organization_user_access for delete to authenticated
using(public.is_org_super_admin(org_id));

drop policy if exists salon_locations_select on public.salon_locations;
create policy salon_locations_select on public.salon_locations for select to authenticated
using(public.is_system_admin() or public.is_org_super_admin(org_id) or public.can_access_salon_location(org_id,id));
drop policy if exists salon_locations_insert on public.salon_locations;
create policy salon_locations_insert on public.salon_locations for insert to authenticated
with check(public.is_org_super_admin(org_id));
drop policy if exists salon_locations_update on public.salon_locations;
create policy salon_locations_update on public.salon_locations for update to authenticated
using(public.is_org_super_admin(org_id)) with check(public.is_org_super_admin(org_id));
drop policy if exists salon_locations_delete on public.salon_locations;
create policy salon_locations_delete on public.salon_locations for delete to authenticated
using(public.is_org_super_admin(org_id));

-- Salon sales inherit the cashier's permanent branch assignment. Workspace
-- super administrators keep the all-branches view; branch users see their own.
alter table public.pos_orders add column if not exists location_id uuid references public.salon_locations(id) on delete restrict;
create index if not exists pos_orders_location_created_idx on public.pos_orders(org_id,location_id,created_at desc);
update public.pos_orders orders set location_id=coalesce(
  (select access.location_id from public.organization_user_access access
    where access.org_id=orders.org_id and access.user_id=orders.cashier_id and access.location_id is not null limit 1),
  (select location.id from public.salon_locations location
    where location.org_id=orders.org_id order by location.is_primary desc,location.created_at limit 1)
)
where orders.location_id is null and exists(select 1 from public.salon_locations location where location.org_id=orders.org_id);

create or replace function public.assign_pos_order_location()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_business_type text;v_assigned_location uuid;
begin
  select business_type into v_business_type from public.organizations where id=new.org_id;
  if v_business_type<>'salon' then return new;end if;
  if auth.role()='service_role' then
    if new.location_id is null then new.location_id:=(select id from public.salon_locations where org_id=new.org_id and active=true order by is_primary desc,created_at limit 1);end if;
    return new;
  end if;
  if not public.is_org_member(new.org_id) or not public.has_org_permission(new.org_id,'sales_view') then
    raise exception 'You do not have permission to create sales for this salon';
  end if;
  select location_id into v_assigned_location from public.organization_user_access
  where org_id=new.org_id and user_id=coalesce(new.cashier_id,auth.uid()) and location_id is not null limit 1;
  if new.location_id is null then
    new.location_id:=coalesce(v_assigned_location,(select id from public.salon_locations where org_id=new.org_id and active=true order by is_primary desc,created_at limit 1));
  end if;
  if new.location_id is null or not public.can_access_salon_location(new.org_id,new.location_id) then
    raise exception 'This sale is not assigned to an accessible salon location';
  end if;
  return new;
end $$;

drop trigger if exists assign_pos_order_location on public.pos_orders;
create trigger assign_pos_order_location before insert or update of org_id,location_id,cashier_id on public.pos_orders
for each row execute function public.assign_pos_order_location();

drop policy if exists pos_orders_select on public.pos_orders;
create policy pos_orders_select on public.pos_orders for select to authenticated using(
  public.is_org_super_admin(org_id)
  or (location_id is not null and public.can_access_salon_location(org_id,location_id))
  or (location_id is null and public.is_org_member(org_id))
);
drop policy if exists pos_orders_insert on public.pos_orders;
create policy pos_orders_insert on public.pos_orders for insert to authenticated with check(
  public.is_org_super_admin(org_id)
  or (location_id is not null and public.can_access_salon_location(org_id,location_id) and public.has_org_permission(org_id,'sales_view'))
  or (location_id is null and public.is_org_member(org_id))
);
drop policy if exists pos_orders_update on public.pos_orders;
create policy pos_orders_update on public.pos_orders for update to authenticated
using(public.is_org_super_admin(org_id) or (location_id is not null and public.can_access_salon_location(org_id,location_id) and public.has_org_permission(org_id,'sales_view')))
with check(public.is_org_super_admin(org_id) or (location_id is not null and public.can_access_salon_location(org_id,location_id) and public.has_org_permission(org_id,'sales_view')));
drop policy if exists pos_orders_delete on public.pos_orders;
create policy pos_orders_delete on public.pos_orders for delete to authenticated using(public.is_org_super_admin(org_id));

drop policy if exists pos_order_items_access on public.pos_order_items;
create policy pos_order_items_access on public.pos_order_items for select to authenticated using(exists(
  select 1 from public.pos_orders orders where orders.id=pos_order_id and (
    public.is_org_super_admin(orders.org_id)
    or (orders.location_id is not null and public.can_access_salon_location(orders.org_id,orders.location_id))
    or (orders.location_id is null and public.is_org_member(orders.org_id))
  )
));

create or replace function public.create_salon_location(
  p_org_id uuid,p_name text,p_code text default null,p_city text default null,
  p_address text default null,p_phone text default null,p_is_primary boolean default false
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_location public.salon_locations%rowtype;v_primary boolean;
begin
  if not public.is_org_super_admin(p_org_id) then raise exception 'Only this workspace super administrator can create locations';end if;
  if nullif(trim(p_name),'') is null then raise exception 'Location name is required';end if;
  if not exists(select 1 from public.organizations where id=p_org_id and business_type='salon' and account_status='active') then raise exception 'Active salon workspace not found';end if;
  v_primary:=p_is_primary or not exists(select 1 from public.salon_locations where org_id=p_org_id);
  if v_primary then update public.salon_locations set is_primary=false where org_id=p_org_id;end if;
  insert into public.salon_locations(org_id,name,code,city,address,phone,employee_login_slug,is_primary,created_by)
  values(p_org_id,trim(p_name),nullif(upper(trim(p_code)),''),nullif(trim(p_city),''),nullif(trim(p_address),''),nullif(trim(p_phone),''),'',v_primary,auth.uid()) returning * into v_location;
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
  select * into v_location from public.salon_locations where id=p_location_id for update;
  if v_location.id is null then raise exception 'Location not found';end if;
  if not public.is_org_super_admin(v_location.org_id) then raise exception 'Only this workspace super administrator can update locations';end if;
  if nullif(trim(p_name),'') is null then raise exception 'Location name is required';end if;
  if not p_active and v_location.is_primary then raise exception 'Choose another primary location before deactivating this one';end if;
  if v_location.is_primary and not p_is_primary then raise exception 'Choose another location as primary before removing this primary location';end if;
  if p_is_primary then update public.salon_locations set is_primary=false where org_id=v_location.org_id and id<>v_location.id;end if;
  update public.salon_locations set name=trim(p_name),code=nullif(upper(trim(p_code)),''),city=nullif(trim(p_city),''),address=nullif(trim(p_address),''),phone=nullif(trim(p_phone),''),active=p_active,is_primary=p_is_primary
  where id=v_location.id returning * into v_location;
  insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_location.org_id,auth.uid(),'salon.location.updated','salon_location',v_location.id::text,jsonb_build_object('name',v_location.name,'active',v_location.active));
  return to_jsonb(v_location);
end $$;

create or replace function public.validate_employee_login_portal(p_slug text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_location public.salon_locations%rowtype;v_access public.organization_user_access%rowtype;v_org public.organizations%rowtype;
begin
  if exists(select 1 from public.profiles where id=auth.uid() and platform_role in ('super_admin','system_admin')) then
    raise exception 'Administrators must use the main login page';
  end if;
  select l.* into v_location from public.salon_locations l join public.organizations o on o.id=l.org_id
  where l.employee_login_slug=p_slug and l.active=true and o.account_status='active';
  if v_location.id is null then raise exception 'This employee login link is unavailable';end if;
  select * into v_access from public.organization_user_access a where a.user_id=auth.uid() and a.org_id=v_location.org_id and a.location_id=v_location.id;
  if v_access.user_id is null or not exists(select 1 from public.memberships m where m.org_id=v_location.org_id and m.user_id=auth.uid() and m.status='active') then
    raise exception 'This account is not assigned to this salon location';
  end if;
  select * into v_org from public.organizations where id=v_location.org_id;
  return jsonb_build_object('authorized',true,'org_id',v_location.org_id,'location_id',v_location.id,'location_name',v_location.name,'salon_name',v_org.name,'permissions',v_access.permissions);
end $$;

create or replace function public.get_employee_login_portal(p_slug text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_location public.salon_locations%rowtype;v_org public.organizations%rowtype;
begin
  select l.* into v_location from public.salon_locations l join public.organizations o on o.id=l.org_id
  where l.employee_login_slug=p_slug and l.active=true and o.account_status='active';
  if v_location.id is null then raise exception 'This employee login link is unavailable';end if;
  select * into v_org from public.organizations where id=v_location.org_id;
  return jsonb_build_object('portal_slug',v_location.employee_login_slug,'location_id',v_location.id,'location_name',v_location.name,
    'city',v_location.city,'address',v_location.address,'phone',coalesce(v_location.phone,v_org.phone),'salon_name',v_org.name);
end $$;

create or replace function public.get_public_salon_booking(p_slug text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_org public.organizations%rowtype;v_settings public.organization_settings%rowtype;v_services jsonb;v_locations jsonb;v_capacity integer;
begin
  select * into v_org from public.organizations where booking_slug=p_slug and business_type='salon' and account_status='active';
  if v_org.id is null then raise exception 'This booking link is unavailable';end if;
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

create or replace function public.get_public_salon_availability(
  p_slug text,p_service_id uuid,p_from_date date,p_to_date date,p_location_id uuid default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_org public.organizations%rowtype;v_location public.salon_locations%rowtype;v_settings public.organization_settings%rowtype;
  v_service public.salon_services%rowtype;v_opening time;v_closing time;v_interval integer;v_timezone text;v_capacity integer;
  v_day date;v_minute integer;v_start timestamptz;v_end timestamptz;v_remaining integer;v_slots jsonb;v_days jsonb:='[]'::jsonb;
begin
  select * into v_org from public.organizations where booking_slug=p_slug and business_type='salon' and account_status='active';
  if v_org.id is null then raise exception 'This booking link is unavailable';end if;
  select * into v_location from public.salon_locations where id=p_location_id and org_id=v_org.id and active=true;
  if v_location.id is null then select * into v_location from public.salon_locations where org_id=v_org.id and active=true order by is_primary desc,created_at limit 1;end if;
  if v_location.id is null then raise exception 'No salon location is available';end if;
  select * into v_service from public.salon_services where id=p_service_id and org_id=v_org.id and active=true;
  if v_service.id is null then raise exception 'Service is unavailable';end if;
  if p_from_date<current_date or p_to_date<p_from_date or p_to_date>p_from_date+30 or p_to_date>current_date+180 then raise exception 'Choose an availability range within the next 180 days';end if;
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
      else v_remaining:=1;end if;
      v_slots:=v_slots||jsonb_build_array(jsonb_build_object('time',to_char(v_start at time zone v_timezone,'HH24:MI'),'starts_at',v_start,'available',v_remaining>0,'remaining',v_remaining,'capacity',v_capacity));
      v_minute:=v_minute+v_interval;
    end loop;
    v_days:=v_days||jsonb_build_array(jsonb_build_object('date',to_char(v_day,'YYYY-MM-DD'),'available',exists(select 1 from jsonb_array_elements(v_slots) slot(value) where (value->>'available')::boolean),'slots',v_slots));
  end loop;
  return jsonb_build_object('service_id',v_service.id,'service_name',v_service.name,'location_id',v_location.id,'location_name',v_location.name,'duration_minutes',v_service.duration_minutes,'capacity',v_capacity,'days',v_days);
end $$;

create or replace function public.book_public_salon_appointment(
  p_slug text,p_service_id uuid,p_customer_name text,p_customer_phone text,p_customer_email text,
  p_starts_at timestamptz,p_notes text default null,p_location_id uuid default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_org public.organizations%rowtype;v_location public.salon_locations%rowtype;v_settings public.organization_settings%rowtype;v_service public.salon_services%rowtype;
  v_customer public.retail_customers%rowtype;v_staff public.employees%rowtype;v_phone text;v_ends_at timestamptz;v_appointment uuid;
  v_opening time;v_closing time;v_local_start timestamp;v_local_end timestamp;v_capacity integer;
begin
  select * into v_org from public.organizations where booking_slug=p_slug and business_type='salon' and account_status='active';if v_org.id is null then raise exception 'This booking link is unavailable';end if;
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

create or replace function public.get_my_workspace_gate()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_membership public.memberships%rowtype;v_org public.organizations%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in is required';end if;
  select membership.* into v_membership
  from public.memberships membership
  left join public.organization_user_access access
    on access.org_id=membership.org_id and access.user_id=membership.user_id
  where membership.user_id=auth.uid()
  order by case when access.user_id is not null then 0 when membership.role='owner' then 1 else 2 end,membership.created_at
  limit 1;
  if v_membership.org_id is null then raise exception 'No workspace is assigned to this account';end if;
  select * into v_org from public.organizations where id=v_membership.org_id;
  return jsonb_build_object('org_id',v_org.id,'org_name',v_org.name,'account_status',v_org.account_status,'billing_status',v_org.billing_status,
    'suspension_reason',v_org.access_suspension_reason,'membership_status',v_membership.status,'role',v_membership.role);
end $$;

create or replace function public.get_system_admin_console()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_rows jsonb;
begin
  if not public.is_system_admin() then raise exception 'System administrator access required';end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',o.id,'name',o.name,'email',o.email,'phone',o.phone,'business_type',o.business_type,
    'account_status',o.account_status,'billing_status',o.billing_status,'created_at',o.created_at,
    'suspended_at',o.access_suspended_at,'suspension_reason',o.access_suspension_reason,
    'owner_id',o.owner_id,'owner_name',p.full_name,'owner_email',p.email,
    'user_count',(select count(*) from public.memberships m where m.org_id=o.id),
    'location_count',(select count(*) from public.salon_locations l where l.org_id=o.id),
    'is_system_workspace',p.platform_role='system_admin'
  ) order by o.created_at desc),'[]'::jsonb) into v_rows
  from public.organizations o left join public.profiles p on p.id=o.owner_id;
  return jsonb_build_object('organizations',v_rows,'generated_at',now());
end $$;

create or replace function public.set_organization_access_state(
  p_org_id uuid,p_account_status text,p_billing_status text,p_reason text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org public.organizations%rowtype;
begin
  if not public.is_system_admin() then raise exception 'System administrator access required';end if;
  if p_account_status not in ('active','suspended') then raise exception 'Invalid account status';end if;
  if p_billing_status not in ('trial','paid','past_due','suspended') then raise exception 'Invalid billing status';end if;
  select * into v_org from public.organizations where id=p_org_id for update;
  if v_org.id is null then raise exception 'Workspace not found';end if;
  if v_org.owner_id=auth.uid() and p_account_status='suspended' then raise exception 'The system administrator workspace cannot be suspended';end if;
  update public.organizations set account_status=p_account_status,billing_status=p_billing_status,
    access_suspended_at=case when p_account_status='suspended' then now() else null end,
    access_suspension_reason=case when p_account_status='suspended' then nullif(trim(p_reason),'') else null end,
    access_suspended_by=case when p_account_status='suspended' then auth.uid() else null end
  where id=p_org_id returning * into v_org;
  insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_org_id,auth.uid(),case when p_account_status='suspended' then 'system.workspace_suspended' else 'system.workspace_activated' end,
    'organization',p_org_id::text,jsonb_build_object('billing_status',p_billing_status,'reason',p_reason));
  return jsonb_build_object('id',v_org.id,'account_status',v_org.account_status,'billing_status',v_org.billing_status);
end $$;

grant execute on function public.is_system_admin() to authenticated;
grant execute on function public.is_org_super_admin(uuid) to authenticated;
grant execute on function public.get_my_workspace_gate() to authenticated;
grant execute on function public.get_system_admin_console() to authenticated;
grant execute on function public.set_organization_access_state(uuid,text,text,text) to authenticated;
