-- First-login company configuration, richer customers, and unified sales access.

alter table public.organizations add column if not exists legal_name text;
alter table public.organizations add column if not exists registration_number text;
alter table public.organizations add column if not exists tax_number text;
alter table public.organizations add column if not exists country text default 'Sri Lanka';
alter table public.organizations add column if not exists branch_count integer not null default 1 check(branch_count>0);
alter table public.organizations add column if not exists employee_count integer not null default 1 check(employee_count>0);

alter table public.retail_customers add column if not exists customer_code text;
alter table public.retail_customers add column if not exists nic_passport text;
alter table public.retail_customers add column if not exists gender text;
alter table public.retail_customers add column if not exists preferred_language text default 'English';
alter table public.retail_customers add column if not exists address text;
alter table public.retail_customers add column if not exists city text;
alter table public.retail_customers add column if not exists postal_code text;
alter table public.retail_customers add column if not exists marketing_consent boolean not null default false;
alter table public.retail_customers add column if not exists tags text[] not null default '{}';
create unique index if not exists retail_customers_org_code_unique on public.retail_customers(org_id,customer_code) where customer_code is not null;

update public.organization_settings set preferences=jsonb_set(preferences,'{onboarding_completed}','false'::jsonb,true)
where not (preferences ? 'onboarding_completed');

create or replace function public.modules_for_business_type(target_type text) returns jsonb
language sql immutable as $$
  select case target_type
    when 'retail_grocery' then '["overview","pos","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'pharmacy' then '["overview","pharmacy","pos","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'salon' then '["overview","salon","pos","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'automotive' then '["overview","automotive","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'general_erp' then '["overview","sales","sales_history","finance","inventory","people","services"]'::jsonb
    else '[]'::jsonb
  end
$$;

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
declare new_org uuid; company text; base_slug text;
begin
  company := coalesce(nullif(new.raw_user_meta_data->>'company_name',''), split_part(new.email, '@', 1) || ' Workspace');
  base_slug := trim(both '-' from regexp_replace(lower(company), '[^a-z0-9]+', '-', 'g'));
  insert into public.profiles(id,email,full_name,platform_role)
  values(new.id,new.email,coalesce(new.raw_user_meta_data->>'full_name',split_part(new.email,'@',1)),case when lower(new.email)='cs.hichweb@gmail.com' then 'super_admin'::public.platform_role else 'user'::public.platform_role end)
  on conflict(id) do update set email=excluded.email;
  insert into public.organizations(name,slug,owner_id,email,industry,business_type)
  values(company,base_slug || '-' || left(replace(new.id::text,'-',''),6),new.id,new.email,'unconfigured','unconfigured') returning id into new_org;
  insert into public.memberships(org_id,user_id,role,status) values(new_org,new.id,'owner','active');
  insert into public.organization_settings(org_id,currency,enabled_modules,preferences)
  values(new_org,'LKR','[]'::jsonb,jsonb_build_object('onboarding_completed',false,'setup_step',1));
  return new;
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
declare v_modules jsonb;
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
  insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_org_id,auth.uid(),'business_configured','organization',p_org_id::text,jsonb_build_object('business_type',p_business_type,'modules',v_modules));
  return jsonb_build_object('configured',true,'business_type',p_business_type,'enabled_modules',v_modules);
end $$;

grant execute on function public.configure_business(uuid,text,text,text,text,text,text,text,text,integer,integer,jsonb) to authenticated;
