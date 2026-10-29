-- Ten configurable industry profiles with isolated module records and workflows.

create or replace function public.modules_for_business_type(target_type text) returns jsonb
language sql immutable set search_path=public as $$
  select case target_type
    when 'retail_grocery' then '["overview","pos","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'pharmacy' then '["overview","pharmacy","pos","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'salon' then '["overview","salon","service_catalog","reminders","pos","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'automotive' then '["overview","automotive","pos","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'general_erp' then '["overview","sales","sales_history","finance","inventory","people","services"]'::jsonb
    when 'clothing_fashion' then '["overview","industry_ops","pos","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'restaurant' then '["overview","industry_ops","pos","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'hotel' then '["overview","industry_ops","pos","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'construction' then '["overview","industry_ops","sales","sales_history","customers","inventory","finance","people","services"]'::jsonb
    when 'real_estate' then '["overview","industry_ops","sales","sales_history","customers","finance","people"]'::jsonb
    when 'education' then '["overview","industry_ops","sales_history","customers","finance","people","services"]'::jsonb
    when 'healthcare_clinic' then '["overview","industry_ops","pos","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'logistics' then '["overview","industry_ops","sales","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'manufacturing_business' then '["overview","industry_ops","sales","inventory","manufacturing","sales_history","finance","people"]'::jsonb
    when 'agriculture' then '["overview","industry_ops","sales_history","customers","inventory","finance","people"]'::jsonb
    else '[]'::jsonb
  end
$$;

create or replace function public.industry_module_key(target_type text) returns text
language sql immutable set search_path=public as $$
  select case target_type
    when 'clothing_fashion' then 'fashion_operations'
    when 'restaurant' then 'restaurant_operations'
    when 'hotel' then 'hotel_operations'
    when 'construction' then 'construction_operations'
    when 'real_estate' then 'real_estate_operations'
    when 'education' then 'education_operations'
    when 'healthcare_clinic' then 'clinic_operations'
    when 'logistics' then 'logistics_operations'
    when 'manufacturing_business' then 'manufacturing_operations'
    when 'agriculture' then 'agriculture_operations'
    else null
  end
$$;

create or replace function public.business_type_uses_locations(target_type text) returns boolean
language sql immutable set search_path=public as $$
  select target_type in (
    'retail_grocery','salon','automotive','clothing_fashion','restaurant','hotel','construction','real_estate',
    'education','healthcare_clinic','logistics','manufacturing_business','agriculture'
  )
$$;

create or replace function public.ensure_salon_primary_location() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if public.business_type_uses_locations(new.business_type) and not exists(select 1 from public.salon_locations where org_id=new.id) then
    insert into public.salon_locations(org_id,name,code,address,phone,employee_login_slug,is_primary,created_by)
    values(new.id,new.name||' Main','MAIN',new.address,new.phone,
      trim(both '-' from regexp_replace(lower(new.slug||'-main'),'[^a-z0-9]+','-','g'))||'-'||lower(substr(replace(gen_random_uuid()::text,'-',''),1,8)),true,new.owner_id);
  end if;
  return new;
end $$;

create or replace function public.create_salon_location(
  p_org_id uuid,p_name text,p_code text default null,p_city text default null,
  p_address text default null,p_phone text default null,p_is_primary boolean default false
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_location public.salon_locations%rowtype;v_primary boolean;
begin
  if not public.is_org_super_admin(p_org_id) then raise exception 'Only this workspace super administrator can create locations';end if;
  if nullif(trim(p_name),'') is null then raise exception 'Location name is required';end if;
  if not exists(select 1 from public.organizations where id=p_org_id and public.business_type_uses_locations(business_type) and account_status='active') then
    raise exception 'Active location-enabled workspace not found';
  end if;
  v_primary:=p_is_primary or not exists(select 1 from public.salon_locations where org_id=p_org_id);
  if v_primary then update public.salon_locations set is_primary=false where org_id=p_org_id;end if;
  insert into public.salon_locations(org_id,name,code,city,address,phone,employee_login_slug,is_primary,created_by)
  values(p_org_id,trim(p_name),nullif(upper(trim(p_code)),''),nullif(trim(p_city),''),nullif(trim(p_address),''),nullif(trim(p_phone),''),'',v_primary,auth.uid()) returning * into v_location;
  insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_org_id,auth.uid(),'location.created','business_location',v_location.id::text,jsonb_build_object('name',v_location.name,'city',v_location.city));
  return to_jsonb(v_location);
end $$;

create or replace function public.enforce_industry_module_isolation() returns trigger
language plpgsql set search_path=public as $$
declare v_business_type text; v_expected_key text;
begin
  if new.module_key not in (
    'fashion_operations','restaurant_operations','hotel_operations','construction_operations','real_estate_operations',
    'education_operations','clinic_operations','logistics_operations','manufacturing_operations','agriculture_operations'
  ) then
    return new;
  end if;
  select business_type into v_business_type from public.organizations where id=new.org_id;
  v_expected_key:=public.industry_module_key(v_business_type);
  if v_expected_key is distinct from new.module_key then
    raise exception 'Industry module % is not enabled for business type %',new.module_key,coalesce(v_business_type,'unknown');
  end if;
  return new;
end $$;

drop trigger if exists enforce_industry_module_isolation on public.module_records;
create trigger enforce_industry_module_isolation
before insert or update of org_id,module_key on public.module_records
for each row execute function public.enforce_industry_module_isolation();

create or replace function public.advance_industry_record(p_record_id uuid) returns text
language plpgsql security definer set search_path=public as $$
declare
  v_record public.module_records%rowtype;
  v_business_type text;
  v_expected_key text;
  v_stages text[];
  v_position integer;
  v_next text;
begin
  select * into v_record from public.module_records where id=p_record_id for update;
  if v_record.id is null or not public.is_org_member(v_record.org_id) then
    raise exception 'Industry record not found or access denied';
  end if;
  select business_type into v_business_type from public.organizations where id=v_record.org_id;
  v_expected_key:=public.industry_module_key(v_business_type);
  if v_expected_key is null or v_record.module_key<>v_expected_key then
    raise exception 'This record does not belong to the active industry module';
  end if;
  v_stages:=case v_business_type
    when 'clothing_fashion' then array['design','sampling','production','quality_control','ready']
    when 'restaurant' then array['received','preparing','ready','served','closed']
    when 'hotel' then array['reserved','checked_in','housekeeping','room_ready','checked_out']
    when 'construction' then array['planning','approved','in_progress','inspection','completed']
    when 'real_estate' then array['new_lead','viewing','negotiation','contracted','closed']
    when 'education' then array['enrolled','scheduled','in_progress','assessed','completed']
    when 'healthcare_clinic' then array['registered','triage','consultation','treatment','completed']
    when 'logistics' then array['booked','dispatched','in_transit','delivered','closed']
    when 'manufacturing_business' then array['planned','materials_ready','in_production','quality_check','completed']
    when 'agriculture' then array['planned','planted','growing','harvest_ready','completed']
    else null
  end;
  v_position:=array_position(v_stages,v_record.status);
  if v_position is null then raise exception 'Invalid workflow status %',v_record.status; end if;
  if v_position>=array_length(v_stages,1) then raise exception 'Record is already complete'; end if;
  v_next:=v_stages[v_position+1];
  update public.module_records set status=v_next where id=v_record.id;
  insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_record.org_id,auth.uid(),'industry.record.advanced',v_record.record_type,v_record.id::text,
    jsonb_build_object('business_type',v_business_type,'module_key',v_record.module_key,'from_status',v_record.status,'to_status',v_next));
  return v_next;
end $$;

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
  if p_business_type not in (
    'retail_grocery','pharmacy','salon','automotive','general_erp','clothing_fashion','restaurant','hotel',
    'construction','real_estate','education','healthcare_clinic','logistics','manufacturing_business','agriculture'
  ) then raise exception 'Choose a valid business type'; end if;
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
  return jsonb_build_object('configured',true,'business_type',p_business_type,'enabled_modules',v_modules,'industry_module_key',public.industry_module_key(p_business_type));
end $$;

update public.organization_settings settings
set enabled_modules=public.modules_for_business_type(organizations.business_type)
from public.organizations organizations
where organizations.id=settings.org_id
  and organizations.business_type in ('clothing_fashion','restaurant','hotel','construction','real_estate','education','healthcare_clinic','logistics','manufacturing_business','agriculture');

grant execute on function public.modules_for_business_type(text),public.industry_module_key(text),public.business_type_uses_locations(text),public.advance_industry_record(uuid) to authenticated;
grant execute on function public.create_salon_location(uuid,text,text,text,text,text,boolean) to authenticated;
grant execute on function public.configure_business(uuid,text,text,text,text,text,text,text,text,integer,integer,jsonb) to authenticated;

