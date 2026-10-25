-- Salon workflow board, granular workspace access, forced temporary-password reset,
-- and an auditable permission boundary for appointment actions.

alter table public.profiles
  add column if not exists must_change_password boolean not null default false;

create table if not exists public.organization_user_access (
  org_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  title text,
  permissions jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (org_id,user_id)
);

create index if not exists organization_user_access_user_idx
  on public.organization_user_access(user_id);

drop trigger if exists touch_updated_at on public.organization_user_access;
create trigger touch_updated_at before update on public.organization_user_access
for each row execute function public.touch_updated_at();

alter table public.organization_user_access enable row level security;
drop policy if exists organization_user_access_select on public.organization_user_access;
create policy organization_user_access_select on public.organization_user_access
for select to authenticated
using (user_id=(select auth.uid()) or public.is_platform_admin());

drop policy if exists organization_user_access_insert on public.organization_user_access;
create policy organization_user_access_insert on public.organization_user_access
for insert to authenticated
with check (public.is_platform_admin());

drop policy if exists organization_user_access_update on public.organization_user_access;
create policy organization_user_access_update on public.organization_user_access
for update to authenticated
using (public.is_platform_admin()) with check (public.is_platform_admin());

drop policy if exists organization_user_access_delete on public.organization_user_access;
create policy organization_user_access_delete on public.organization_user_access
for delete to authenticated
using (public.is_platform_admin());

create or replace function public.has_org_permission(target_org uuid, permission_key text)
returns boolean
language sql stable security definer set search_path=public as $$
  select public.is_platform_admin() or exists(
    select 1
    from public.memberships m
    left join public.organization_user_access a
      on a.org_id=m.org_id and a.user_id=m.user_id
    where m.org_id=target_org
      and m.user_id=(select auth.uid())
      and m.status='active'
      and case
        when a.permissions ? permission_key
          then coalesce((a.permissions->>permission_key)::boolean,false)
        when permission_key like '%_view'
          then true
        else m.role in ('owner','admin','manager')
      end
  );
$$;

alter table public.salon_appointments
  add column if not exists workflow_stage text not null default 'pending'
    check (workflow_stage in ('pending','call','confirmed','complete')),
  add column if not exists responsible_employee_id uuid references public.employees(id) on delete set null,
  add column if not exists responsible_name text;

create index if not exists salon_appointments_workflow_idx
  on public.salon_appointments(org_id,workflow_stage,starts_at);

update public.salon_appointments
set workflow_stage=case
  when status='completed' then 'complete'
  when status in ('confirmed','in_service') then 'confirmed'
  else 'pending'
end
where workflow_stage='pending' and status<>'booked';

create or replace function public.sync_salon_workflow_stage()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.status='completed' then
    new.workflow_stage:='complete';
  elsif new.status in ('confirmed','in_service')
    and (tg_op='INSERT' or old.status is distinct from new.status) then
    new.workflow_stage:='confirmed';
  end if;
  return new;
end $$;

drop trigger if exists sync_salon_workflow_stage on public.salon_appointments;
create trigger sync_salon_workflow_stage
before insert or update of status on public.salon_appointments
for each row execute function public.sync_salon_workflow_stage();

create or replace function public.move_salon_appointment_kanban(
  p_appointment_id uuid,
  p_stage text,
  p_responsible_employee_id uuid default null
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_appointment public.salon_appointments%rowtype;
  v_responsible public.employees%rowtype;
  v_status text;
begin
  if p_stage not in ('pending','call','confirmed','complete') then
    raise exception 'Invalid workflow stage';
  end if;

  select * into v_appointment from public.salon_appointments
  where id=p_appointment_id for update;
  if v_appointment.id is null or not public.is_org_member(v_appointment.org_id) then
    raise exception 'Appointment not found or access denied';
  end if;

  if p_stage is distinct from v_appointment.workflow_stage then
    if p_stage='confirmed' then
      if not public.has_org_permission(v_appointment.org_id,'salon_approve') then
        raise exception 'You do not have permission to confirm appointments';
      end if;
    elsif not public.has_org_permission(v_appointment.org_id,'salon_move') then
      raise exception 'You do not have permission to move appointments';
    end if;
  end if;

  if p_responsible_employee_id is distinct from v_appointment.responsible_employee_id
    and not public.has_org_permission(v_appointment.org_id,'salon_allocate') then
    raise exception 'You do not have permission to allocate a responsible person';
  end if;

  if p_responsible_employee_id is not null then
    select * into v_responsible from public.employees
    where id=p_responsible_employee_id and org_id=v_appointment.org_id
      and employment_status='active';
    if v_responsible.id is null then raise exception 'Responsible person is unavailable'; end if;
  end if;

  v_status:=case p_stage
    when 'confirmed' then 'confirmed'
    when 'complete' then 'completed'
    else 'booked'
  end;

  update public.salon_appointments set
    workflow_stage=p_stage,
    status=v_status,
    responsible_employee_id=v_responsible.id,
    responsible_name=v_responsible.name
  where id=v_appointment.id;

  insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_appointment.org_id,auth.uid(),'salon.appointment.workflow_changed','salon_appointment',v_appointment.id::text,
    jsonb_build_object(
      'customer',v_appointment.customer_name,
      'service',v_appointment.service_name,
      'from_stage',v_appointment.workflow_stage,
      'to_stage',p_stage,
      'responsible_person',v_responsible.name
    ));

  return jsonb_build_object(
    'id',v_appointment.id,
    'workflow_stage',p_stage,
    'status',v_status,
    'responsible_employee_id',v_responsible.id,
    'responsible_name',v_responsible.name
  );
end $$;

-- Appointment writes are enforced in the database. Public bookings continue to
-- use their dedicated SECURITY DEFINER function.
drop policy if exists salon_appointments_insert on public.salon_appointments;
create policy salon_appointments_insert on public.salon_appointments
for insert to authenticated
with check (public.has_org_permission(org_id,'salon_create'));

drop policy if exists salon_appointments_update on public.salon_appointments;
create policy salon_appointments_update on public.salon_appointments
for update to authenticated
using (public.has_org_permission(org_id,'salon_manage'))
with check (public.has_org_permission(org_id,'salon_manage'));

drop policy if exists salon_appointments_delete on public.salon_appointments;
create policy salon_appointments_delete on public.salon_appointments
for delete to authenticated
using (public.has_org_permission(org_id,'salon_manage'));

-- Audit logs are private: a user can see their own entries, while platform
-- super administrators can inspect the complete history.
drop policy if exists activity_log_select on public.activity_log;
create policy activity_log_select on public.activity_log
for select to authenticated
using (actor_id=(select auth.uid()) or public.is_platform_admin());

drop policy if exists activity_log_insert on public.activity_log;
create policy activity_log_insert on public.activity_log
for insert to authenticated
with check (actor_id=(select auth.uid()) and public.is_org_member(org_id));

drop policy if exists activity_log_update on public.activity_log;
drop policy if exists activity_log_delete on public.activity_log;

-- Managed users may read the salon catalogue, availability and team directory,
-- but only operational managers can change those configuration records.
drop policy if exists salon_services_insert on public.salon_services;
create policy salon_services_insert on public.salon_services for insert to authenticated
with check (public.has_org_permission(org_id,'salon_manage'));
drop policy if exists salon_services_update on public.salon_services;
create policy salon_services_update on public.salon_services for update to authenticated
using (public.has_org_permission(org_id,'salon_manage')) with check (public.has_org_permission(org_id,'salon_manage'));
drop policy if exists salon_services_delete on public.salon_services;
create policy salon_services_delete on public.salon_services for delete to authenticated
using (public.has_org_permission(org_id,'salon_manage'));

drop policy if exists salon_unavailability_insert on public.salon_unavailability;
create policy salon_unavailability_insert on public.salon_unavailability for insert to authenticated
with check (public.has_org_permission(org_id,'salon_manage'));
drop policy if exists salon_unavailability_update on public.salon_unavailability;
create policy salon_unavailability_update on public.salon_unavailability for update to authenticated
using (public.has_org_permission(org_id,'salon_manage')) with check (public.has_org_permission(org_id,'salon_manage'));
drop policy if exists salon_unavailability_delete on public.salon_unavailability;
create policy salon_unavailability_delete on public.salon_unavailability for delete to authenticated
using (public.has_org_permission(org_id,'salon_manage'));

grant select,insert,update,delete on public.organization_user_access to authenticated;
grant execute on function public.has_org_permission(uuid,text) to authenticated;
grant execute on function public.move_salon_appointment_kanban(uuid,text,uuid) to authenticated;

