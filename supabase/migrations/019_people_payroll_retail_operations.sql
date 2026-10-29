-- Complete employee onboarding, selectable manual paysheets, and branch-aware retail receiving.

alter table public.employees add column if not exists employee_code text;
alter table public.employees add column if not exists phone text;
alter table public.employees add column if not exists nic_passport text;
alter table public.employees add column if not exists date_of_birth date;
alter table public.employees add column if not exists address text;
alter table public.employees add column if not exists emergency_contact text;
alter table public.employees add column if not exists emergency_phone text;
alter table public.employees add column if not exists notes text;
create unique index if not exists employees_org_employee_code_key on public.employees(org_id,employee_code) where employee_code is not null;

alter table public.payroll_items add column if not exists manual_additions jsonb not null default '[]'::jsonb;
alter table public.payroll_items add column if not exists manual_deductions jsonb not null default '[]'::jsonb;
alter table public.payroll_items add column if not exists notes text;

alter table public.products add column if not exists brand text;
alter table public.products add column if not exists unit text not null default 'item';
alter table public.products add column if not exists batch_number text;
alter table public.products add column if not exists expiry_date date;

create table if not exists public.inventory_receipts(
 id uuid primary key default gen_random_uuid(),org_id uuid not null references public.organizations(id) on delete cascade,
 location_id uuid not null references public.salon_locations(id) on delete restrict,supplier_id uuid references public.suppliers(id) on delete set null,
 reference text not null,received_at timestamptz not null default now(),subtotal numeric(14,2) not null default 0,notes text,
 created_by uuid references auth.users(id) on delete set null,created_at timestamptz not null default now(),unique(org_id,reference)
);
create table if not exists public.inventory_receipt_items(
 id uuid primary key default gen_random_uuid(),receipt_id uuid not null references public.inventory_receipts(id) on delete cascade,
 product_id uuid not null references public.products(id) on delete restrict,quantity numeric(14,3) not null check(quantity>0),
 unit_cost numeric(14,2) not null check(unit_cost>=0),line_total numeric(14,2) generated always as(quantity*unit_cost) stored
);
create index if not exists inventory_receipts_org_location_idx on public.inventory_receipts(org_id,location_id,received_at desc);
create index if not exists inventory_receipt_items_receipt_idx on public.inventory_receipt_items(receipt_id);

alter table public.inventory_receipts enable row level security;
alter table public.inventory_receipt_items enable row level security;
drop policy if exists inventory_receipts_access on public.inventory_receipts;
create policy inventory_receipts_access on public.inventory_receipts for all to authenticated
using(public.is_org_super_admin(org_id) or public.can_access_salon_location(org_id,location_id))
with check(public.is_org_super_admin(org_id) or public.can_access_salon_location(org_id,location_id));
drop policy if exists inventory_receipt_items_access on public.inventory_receipt_items;
create policy inventory_receipt_items_access on public.inventory_receipt_items for all to authenticated
using(exists(select 1 from public.inventory_receipts r where r.id=receipt_id and (public.is_org_super_admin(r.org_id) or public.can_access_salon_location(r.org_id,r.location_id))))
with check(exists(select 1 from public.inventory_receipts r where r.id=receipt_id and (public.is_org_super_admin(r.org_id) or public.can_access_salon_location(r.org_id,r.location_id))));

create or replace function public.configure_onboarding_employees(p_org_id uuid,p_employees jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_item jsonb;v_employee uuid;v_location uuid;v_code text;v_count integer:=0;
begin
 if not public.is_org_super_admin(p_org_id) then raise exception 'Only the workspace super administrator can configure employees';end if;
 if jsonb_typeof(p_employees)<>'array' or jsonb_array_length(p_employees)=0 then raise exception 'Add at least one employee';end if;
 for v_item in select value from jsonb_array_elements(p_employees) loop
  if nullif(trim(v_item->>'name'),'') is null or nullif(trim(v_item->>'role'),'') is null then raise exception 'Every employee needs a name and role';end if;
  v_code:=upper(coalesce(nullif(trim(v_item->>'employee_code'),''),'EMP-'||lpad((v_count+1)::text,4,'0')));
  v_location:=nullif(v_item->>'location_id','')::uuid;
  if v_location is not null and not exists(select 1 from public.salon_locations where id=v_location and org_id=p_org_id and active=true) then raise exception 'Employee branch does not belong to this workspace';end if;
  select id into v_employee from public.employees where org_id=p_org_id and employee_code=v_code limit 1;
  if v_employee is null then select id into v_employee from public.employees where org_id=p_org_id and employee_code is null and name like 'Staff member %' and role_title='Salon specialist' and department='Salon' and bookable_for_appointments=true order by created_at limit 1;end if;
  if v_employee is null then
   insert into public.employees(org_id,location_id,employee_code,name,email,phone,nic_passport,role_title,department,start_date,employment_status,bookable_for_appointments,address,emergency_contact,emergency_phone,notes)
   values(p_org_id,v_location,v_code,trim(v_item->>'name'),nullif(trim(v_item->>'email'),''),nullif(trim(v_item->>'phone'),''),nullif(trim(v_item->>'nic_passport'),''),trim(v_item->>'role'),coalesce(nullif(trim(v_item->>'department'),''),'Operations'),coalesce(nullif(v_item->>'start_date','')::date,current_date),'active',coalesce((v_item->>'bookable')::boolean,false),nullif(trim(v_item->>'address'),''),nullif(trim(v_item->>'emergency_contact'),''),nullif(trim(v_item->>'emergency_phone'),''),nullif(trim(v_item->>'notes'),'')) returning id into v_employee;
  else
   update public.employees set location_id=v_location,employee_code=v_code,name=trim(v_item->>'name'),email=nullif(trim(v_item->>'email'),''),phone=nullif(trim(v_item->>'phone'),''),nic_passport=nullif(trim(v_item->>'nic_passport'),''),role_title=trim(v_item->>'role'),department=coalesce(nullif(trim(v_item->>'department'),''),'Operations'),start_date=coalesce(nullif(v_item->>'start_date','')::date,start_date,current_date),employment_status='active',bookable_for_appointments=coalesce((v_item->>'bookable')::boolean,false),address=nullif(trim(v_item->>'address'),''),emergency_contact=nullif(trim(v_item->>'emergency_contact'),''),emergency_phone=nullif(trim(v_item->>'emergency_phone'),''),notes=nullif(trim(v_item->>'notes'),''),updated_at=now() where id=v_employee;
  end if;
  insert into public.employee_compensation(org_id,employee_id,pay_type,base_salary,hourly_rate,standard_hours,fixed_allowances,fixed_deductions,payment_method,effective_from)
  values(p_org_id,v_employee,coalesce(nullif(v_item->>'pay_type',''),'monthly'),greatest(coalesce((v_item->>'base_salary')::numeric,0),0),greatest(coalesce((v_item->>'hourly_rate')::numeric,0),0),greatest(coalesce((v_item->>'standard_hours')::numeric,0),0),greatest(coalesce((v_item->>'allowances')::numeric,0),0),greatest(coalesce((v_item->>'deductions')::numeric,0),0),coalesce(nullif(v_item->>'payment_method',''),'bank'),coalesce(nullif(v_item->>'start_date','')::date,current_date))
  on conflict(employee_id) do update set pay_type=excluded.pay_type,base_salary=excluded.base_salary,hourly_rate=excluded.hourly_rate,standard_hours=excluded.standard_hours,fixed_allowances=excluded.fixed_allowances,fixed_deductions=excluded.fixed_deductions,payment_method=excluded.payment_method,effective_from=excluded.effective_from,updated_at=now();
  v_count:=v_count+1;
 end loop;
 update public.organizations set employee_count=(select count(*) from public.employees where org_id=p_org_id and employment_status='active') where id=p_org_id;
 return jsonb_build_object('saved',v_count);
end $$;

create or replace function public.save_employee_paysheet(p_org_id uuid,p_period_month date,p_employee_id uuid,p_additions jsonb default '[]'::jsonb,p_deductions jsonb default '[]'::jsonb,p_notes text default null) returns uuid
language plpgsql security definer set search_path=public as $$
declare v_run uuid;v_comp public.employee_compensation%rowtype;v_base numeric;v_added numeric:=0;v_reduced numeric:=0;v_gross numeric;v_epf numeric;v_net numeric;v_line jsonb;
begin
 if not public.can_manage_org(p_org_id) then raise exception 'Only workspace managers can create paysheets';end if;
 if not exists(select 1 from public.employees where id=p_employee_id and org_id=p_org_id and employment_status='active') then raise exception 'Select an active employee';end if;
 select * into v_comp from public.employee_compensation where org_id=p_org_id and employee_id=p_employee_id;
 if v_comp.id is null then raise exception 'Add compensation details for this employee first';end if;
 if jsonb_typeof(coalesce(p_additions,'[]'))<>'array' or jsonb_typeof(coalesce(p_deductions,'[]'))<>'array' then raise exception 'Paysheet adjustments must be lists';end if;
 for v_line in select value from jsonb_array_elements(coalesce(p_additions,'[]')) loop if coalesce((v_line->>'amount')::numeric,0)<0 then raise exception 'Addition values cannot be negative';end if;v_added:=v_added+coalesce((v_line->>'amount')::numeric,0);end loop;
 for v_line in select value from jsonb_array_elements(coalesce(p_deductions,'[]')) loop if coalesce((v_line->>'amount')::numeric,0)<0 then raise exception 'Deduction values cannot be negative';end if;v_reduced:=v_reduced+coalesce((v_line->>'amount')::numeric,0);end loop;
 insert into public.payroll_runs(org_id,period_month,status,created_by) values(p_org_id,date_trunc('month',p_period_month)::date,'draft',auth.uid())
 on conflict(org_id,period_month) do update set status=payroll_runs.status returning id into v_run;
 if exists(select 1 from public.payroll_runs where id=v_run and status<>'draft') then raise exception 'Only a draft payroll can be edited';end if;
 v_base:=case when v_comp.pay_type='hourly' then round(v_comp.hourly_rate*v_comp.standard_hours,2) else v_comp.base_salary end;
 v_gross:=v_base+v_comp.fixed_allowances+v_added;v_epf:=round(v_base*v_comp.epf_employee_rate/100,2);v_net:=v_gross-v_epf-v_comp.fixed_deductions-v_reduced;
 if v_net<0 then raise exception 'Deductions cannot exceed the employee gross pay';end if;
 insert into public.payroll_items(payroll_run_id,employee_id,base_pay,allowances,gross_pay,epf_employee,other_deductions,net_pay,epf_employer,etf_employer,manual_additions,manual_deductions,notes)
 values(v_run,p_employee_id,v_base,v_comp.fixed_allowances+v_added,v_gross,v_epf,v_comp.fixed_deductions+v_reduced,v_net,round(v_base*v_comp.epf_employer_rate/100,2),round(v_base*v_comp.etf_rate/100,2),coalesce(p_additions,'[]'),coalesce(p_deductions,'[]'),nullif(trim(p_notes),''))
 on conflict(payroll_run_id,employee_id) do update set base_pay=excluded.base_pay,allowances=excluded.allowances,gross_pay=excluded.gross_pay,epf_employee=excluded.epf_employee,other_deductions=excluded.other_deductions,net_pay=excluded.net_pay,epf_employer=excluded.epf_employer,etf_employer=excluded.etf_employer,manual_additions=excluded.manual_additions,manual_deductions=excluded.manual_deductions,notes=excluded.notes;
 update public.payroll_runs set gross_pay=coalesce((select sum(gross_pay) from public.payroll_items where payroll_run_id=v_run),0),employee_deductions=coalesce((select sum(epf_employee+other_deductions) from public.payroll_items where payroll_run_id=v_run),0),employer_contributions=coalesce((select sum(epf_employer+etf_employer) from public.payroll_items where payroll_run_id=v_run),0),net_pay=coalesce((select sum(net_pay) from public.payroll_items where payroll_run_id=v_run),0) where id=v_run;
 return v_run;
end $$;

create or replace function public.receive_inventory_stock(p_org_id uuid,p_location_id uuid,p_supplier_id uuid,p_reference text,p_items jsonb,p_notes text default null) returns uuid
language plpgsql security definer set search_path=public as $$
declare v_receipt uuid;v_item jsonb;v_product public.products%rowtype;v_qty numeric;v_cost numeric;v_total numeric:=0;v_entry uuid;v_inventory uuid;v_payable uuid;
begin
 if not (public.is_org_super_admin(p_org_id) or public.can_access_salon_location(p_org_id,p_location_id)) then raise exception 'You cannot receive stock for this branch';end if;
 if not exists(select 1 from public.salon_locations where id=p_location_id and org_id=p_org_id and active=true) then raise exception 'Choose an active branch';end if;
 if p_supplier_id is not null and not exists(select 1 from public.suppliers where id=p_supplier_id and org_id=p_org_id and location_id=p_location_id and active=true) then raise exception 'Supplier does not belong to this branch';end if;
 if nullif(trim(p_reference),'') is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Reference and at least one item are required';end if;
 insert into public.inventory_receipts(org_id,location_id,supplier_id,reference,notes,created_by) values(p_org_id,p_location_id,p_supplier_id,upper(trim(p_reference)),nullif(trim(p_notes),''),auth.uid()) returning id into v_receipt;
 for v_item in select value from jsonb_array_elements(p_items) loop
  v_qty:=coalesce((v_item->>'quantity')::numeric,0);v_cost:=coalesce((v_item->>'unit_cost')::numeric,-1);
  if v_qty<=0 or v_cost<0 then raise exception 'Quantity and unit cost are invalid';end if;
  select * into v_product from public.products where id=(v_item->>'product_id')::uuid and org_id=p_org_id and active=true for update;
  if v_product.id is null or (v_product.location_id is not null and v_product.location_id<>p_location_id) then raise exception 'Product does not belong to this branch';end if;
  insert into public.inventory_receipt_items(receipt_id,product_id,quantity,unit_cost) values(v_receipt,v_product.id,v_qty,v_cost);
  update public.products set location_id=coalesce(location_id,p_location_id),supplier_id=coalesce(p_supplier_id,supplier_id),stock=stock+v_qty,forecast=forecast+v_qty,cost=v_cost,updated_at=now() where id=v_product.id;
  insert into public.stock_movements(org_id,location_id,product_id,movement_type,quantity,reference,created_by) values(p_org_id,p_location_id,v_product.id,'receipt',v_qty,upper(trim(p_reference)),auth.uid());
  v_total:=v_total+v_qty*v_cost;
 end loop;
 update public.inventory_receipts set subtotal=round(v_total,2) where id=v_receipt;
 perform public.ensure_default_accounts(p_org_id);
 insert into public.accounts(org_id,code,name,account_type) values(p_org_id,'1200','Inventory','asset_current'),(p_org_id,'2100','Accounts Payable','liability_current') on conflict(org_id,code) do nothing;
 select id into v_inventory from public.accounts where org_id=p_org_id and code='1200';select id into v_payable from public.accounts where org_id=p_org_id and code='2100';
 insert into public.journal_entries(org_id,reference,entry_date,description,status,source_type,source_id,created_by,posted_at) values(p_org_id,upper(trim(p_reference)),current_date,'Branch inventory receipt','posted','inventory_receipt',v_receipt,auth.uid(),now()) returning id into v_entry;
 insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values(v_entry,v_inventory,'Inventory received',round(v_total,2),0),(v_entry,v_payable,'Supplier payable',0,round(v_total,2));
 return v_receipt;
end $$;

grant select,insert,update,delete on public.inventory_receipts,public.inventory_receipt_items to authenticated;
grant execute on function public.configure_onboarding_employees(uuid,jsonb),public.save_employee_paysheet(uuid,date,uuid,jsonb,jsonb,text),public.receive_inventory_stock(uuid,uuid,uuid,text,jsonb,text) to authenticated;

-- Retail & Grocery uses the same hardened location foundation as salon and automotive.
create or replace function public.ensure_salon_primary_location() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.business_type in ('salon','automotive','retail_grocery') and not exists(select 1 from public.salon_locations where org_id=new.id) then
  insert into public.salon_locations(org_id,name,code,address,phone,employee_login_slug,is_primary,created_by)
  values(new.id,new.name||' Main','MAIN',new.address,new.phone,trim(both '-' from regexp_replace(lower(new.slug||'-main'),'[^a-z0-9]+','-','g'))||'-'||lower(substr(replace(gen_random_uuid()::text,'-',''),1,8)),true,new.owner_id);
 end if;return new;
end $$;

create or replace function public.create_salon_location(p_org_id uuid,p_name text,p_code text default null,p_city text default null,p_address text default null,p_phone text default null,p_is_primary boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_location public.salon_locations%rowtype;v_primary boolean;
begin
 if not public.is_org_super_admin(p_org_id) then raise exception 'Only this workspace super administrator can create locations';end if;
 if nullif(trim(p_name),'') is null then raise exception 'Location name is required';end if;
 if not exists(select 1 from public.organizations where id=p_org_id and business_type in ('salon','automotive','retail_grocery') and account_status='active') then raise exception 'Active branch-enabled workspace not found';end if;
 v_primary:=p_is_primary or not exists(select 1 from public.salon_locations where org_id=p_org_id);if v_primary then update public.salon_locations set is_primary=false where org_id=p_org_id;end if;
 insert into public.salon_locations(org_id,name,code,city,address,phone,employee_login_slug,is_primary,created_by)
 values(p_org_id,trim(p_name),nullif(upper(trim(p_code)),''),nullif(trim(p_city),''),nullif(trim(p_address),''),nullif(trim(p_phone),''),'',v_primary,auth.uid()) returning * into v_location;
 insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata) values(p_org_id,auth.uid(),'location.created','business_location',v_location.id::text,jsonb_build_object('name',v_location.name,'city',v_location.city));return to_jsonb(v_location);
end $$;
grant execute on function public.create_salon_location(uuid,text,text,text,text,text,boolean) to authenticated;
