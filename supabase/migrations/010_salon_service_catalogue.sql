-- Dedicated salon service catalogue with descriptions and module access.

alter table public.salon_services add column if not exists description text;

create or replace function public.modules_for_business_type(target_type text) returns jsonb
language sql immutable as $$
  select case target_type
    when 'retail_grocery' then '["overview","pos","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'pharmacy' then '["overview","pharmacy","pos","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'salon' then '["overview","salon","service_catalog","reminders","pos","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'automotive' then '["overview","automotive","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'general_erp' then '["overview","sales","sales_history","finance","inventory","people","services"]'::jsonb
    else '[]'::jsonb
  end
$$;

update public.organization_settings settings
set enabled_modules=public.modules_for_business_type(organizations.business_type)
from public.organizations organizations
where organizations.id=settings.org_id and organizations.business_type='salon';

create or replace function public.get_public_salon_booking(p_slug text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_org public.organizations%rowtype; v_settings public.organization_settings%rowtype; v_services jsonb;
begin
  select * into v_org from public.organizations where booking_slug=p_slug and business_type='salon';
  if v_org.id is null then raise exception 'This booking link is unavailable'; end if;
  select * into v_settings from public.organization_settings where org_id=v_org.id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'name',name,'category',coalesce(category,'Services'),'description',description,
    'duration_minutes',duration_minutes,'price',price
  ) order by category,name),'[]'::jsonb) into v_services from public.salon_services where org_id=v_org.id and active=true;
  return jsonb_build_object(
    'salon',jsonb_build_object('name',v_org.name,'phone',v_org.phone,'address',v_org.address,'slug',v_org.booking_slug),
    'services',v_services,
    'opening_time',coalesce(v_settings.preferences->>'opening_time','09:00'),
    'closing_time',coalesce(v_settings.preferences->>'closing_time','19:00'),
    'booking_interval',coalesce((v_settings.preferences->>'booking_interval')::integer,30)
  );
end $$;

grant execute on function public.get_public_salon_booking(text) to anon,authenticated;
