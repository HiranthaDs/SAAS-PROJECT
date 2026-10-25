-- Let a workspace owner use their own location links while preserving branch assignment checks.
-- Assigned managers and employees may also use the normal workspace login; RLS continues to
-- restrict their data to the location recorded in organization_user_access.

create or replace function public.validate_employee_login_portal(p_slug text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_location public.salon_locations%rowtype;
  v_access public.organization_user_access%rowtype;
  v_org public.organizations%rowtype;
  v_is_owner boolean:=false;
begin
  if auth.uid() is null then raise exception 'Sign in is required';end if;

  select l.* into v_location
  from public.salon_locations l
  join public.organizations o on o.id=l.org_id
  where l.employee_login_slug=p_slug and l.active=true and o.account_status='active';
  if v_location.id is null then raise exception 'This location login link is unavailable';end if;

  select * into v_org from public.organizations where id=v_location.org_id;
  v_is_owner:=v_org.owner_id=auth.uid() and exists(
    select 1 from public.memberships m
    where m.org_id=v_location.org_id and m.user_id=auth.uid()
      and m.status='active' and m.role='owner'
  );

  select * into v_access
  from public.organization_user_access a
  where a.user_id=auth.uid() and a.org_id=v_location.org_id and a.location_id=v_location.id;

  if not v_is_owner and (
    v_access.user_id is null or not exists(
      select 1 from public.memberships m
      where m.org_id=v_location.org_id and m.user_id=auth.uid() and m.status='active'
    )
  ) then
    raise exception 'This account is not assigned to this salon location';
  end if;

  return jsonb_build_object(
    'authorized',true,
    'access_kind',case when v_is_owner then 'workspace_owner' else 'assigned_user' end,
    'org_id',v_location.org_id,
    'location_id',v_location.id,
    'location_name',v_location.name,
    'salon_name',v_org.name,
    'permissions',case when v_is_owner then '{}'::jsonb else coalesce(v_access.permissions,'{}'::jsonb) end
  );
end $$;

grant execute on function public.validate_employee_login_portal(text) to authenticated;
