-- Branch-aware automotive operations, parts, suppliers, vehicle history and POS services.

insert into public.salon_locations(org_id,name,code,address,phone,employee_login_slug,is_primary,created_by)
select o.id,o.name||' Main','MAIN',o.address,o.phone,
  trim(both '-' from regexp_replace(lower(o.slug||'-main'),'[^a-z0-9]+','-','g'))||'-'||lower(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
  true,o.owner_id
from public.organizations o
where o.business_type='automotive' and not exists(select 1 from public.salon_locations l where l.org_id=o.id);

alter table public.products add column if not exists location_id uuid references public.salon_locations(id) on delete restrict;
alter table public.products add column if not exists supplier_id uuid;
alter table public.stock_movements add column if not exists location_id uuid references public.salon_locations(id) on delete restrict;
alter table public.vehicles add column if not exists location_id uuid references public.salon_locations(id) on delete restrict;
alter table public.vehicles add column if not exists color text;
alter table public.vehicles add column if not exists fuel_type text;
alter table public.vehicles add column if not exists transmission text;
alter table public.vehicles add column if not exists engine_number text;
alter table public.vehicles add column if not exists last_service_at timestamptz;
alter table public.vehicles add column if not exists next_service_date date;
alter table public.vehicles add column if not exists next_service_mileage numeric(14,2);
alter table public.vehicles add column if not exists reminder_sent_at timestamptz;
alter table public.workshop_job_cards add column if not exists location_id uuid references public.salon_locations(id) on delete restrict;
alter table public.workshop_job_cards add column if not exists customer_id uuid references public.retail_customers(id) on delete set null;
alter table public.workshop_job_cards add column if not exists diagnosis text;
alter table public.workshop_job_cards add column if not exists next_service_date date;
alter table public.workshop_job_cards add column if not exists next_service_mileage numeric(14,2);
alter table public.workshop_job_cards add column if not exists completed_at timestamptz;

create table if not exists public.suppliers(
 id uuid primary key default gen_random_uuid(),org_id uuid not null references public.organizations(id) on delete cascade,
 location_id uuid not null references public.salon_locations(id) on delete restrict,name text not null,contact_person text,phone text,email text,address text,
 categories text[] not null default '{}',active boolean not null default true,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 unique(org_id,location_id,name)
);
alter table public.products drop constraint if exists products_supplier_id_fkey;
alter table public.products add constraint products_supplier_id_fkey foreign key(supplier_id) references public.suppliers(id) on delete set null;

create table if not exists public.automotive_services(
 id uuid primary key default gen_random_uuid(),org_id uuid not null references public.organizations(id) on delete cascade,
 location_id uuid references public.salon_locations(id) on delete cascade,code text not null,name text not null,category text,description text,
 duration_minutes integer not null default 60 check(duration_minutes>0),price numeric(14,2) not null default 0,
 next_service_months integer not null default 0,next_service_km numeric(14,2) not null default 0,active boolean not null default true,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(org_id,code)
);
alter table public.workshop_job_cards add column if not exists automotive_service_id uuid references public.automotive_services(id) on delete set null;
alter table public.pos_order_items add column if not exists automotive_service_id uuid references public.automotive_services(id) on delete set null;
alter table public.pos_orders add column if not exists job_card_id uuid references public.workshop_job_cards(id) on delete set null;

alter table public.products drop constraint if exists products_org_id_sku_key;
drop index if exists public.products_org_barcode_unique;
create unique index if not exists products_org_sku_no_location_unique on public.products(org_id,sku) where location_id is null;
create unique index if not exists products_org_location_sku_unique on public.products(org_id,location_id,sku) where location_id is not null;
create unique index if not exists products_org_barcode_no_location_unique on public.products(org_id,barcode) where location_id is null and barcode is not null;
create unique index if not exists products_org_location_barcode_unique on public.products(org_id,location_id,barcode) where location_id is not null and barcode is not null;

create index if not exists products_location_idx on public.products(org_id,location_id);
create index if not exists stock_movements_location_idx on public.stock_movements(org_id,location_id,moved_at desc);
create index if not exists vehicles_location_idx on public.vehicles(org_id,location_id);
create index if not exists workshop_jobs_location_idx on public.workshop_job_cards(org_id,location_id,created_at desc);
create index if not exists suppliers_location_idx on public.suppliers(org_id,location_id);
create index if not exists automotive_services_location_idx on public.automotive_services(org_id,location_id);

update public.products p set location_id=(select l.id from public.salon_locations l where l.org_id=p.org_id order by l.is_primary desc,l.created_at limit 1)
where p.location_id is null and exists(select 1 from public.organizations o where o.id=p.org_id and o.business_type='automotive');
update public.vehicles v set location_id=(select l.id from public.salon_locations l where l.org_id=v.org_id order by l.is_primary desc,l.created_at limit 1) where v.location_id is null;
update public.workshop_job_cards j set location_id=coalesce((select v.location_id from public.vehicles v where v.id=j.vehicle_id),(select l.id from public.salon_locations l where l.org_id=j.org_id order by l.is_primary desc,l.created_at limit 1)) where j.location_id is null;
update public.workshop_job_cards j set customer_id=(select v.customer_id from public.vehicles v where v.id=j.vehicle_id) where j.customer_id is null;

alter table public.suppliers enable row level security;
alter table public.automotive_services enable row level security;
do $$ declare tab text;begin
 foreach tab in array array['suppliers','automotive_services'] loop
  execute format('drop policy if exists %I on public.%I',tab||'_select',tab);
  execute format('create policy %I on public.%I for select to authenticated using (public.is_org_super_admin(org_id) or (location_id is null and public.is_org_member(org_id)) or public.can_access_salon_location(org_id,location_id))',tab||'_select',tab);
  execute format('drop policy if exists %I on public.%I',tab||'_insert',tab);
  execute format('create policy %I on public.%I for insert to authenticated with check (public.is_org_super_admin(org_id) or (location_id is not null and public.can_access_salon_location(org_id,location_id)))',tab||'_insert',tab);
  execute format('drop policy if exists %I on public.%I',tab||'_update',tab);
  execute format('create policy %I on public.%I for update to authenticated using (public.is_org_super_admin(org_id) or (location_id is not null and public.can_access_salon_location(org_id,location_id))) with check (public.is_org_super_admin(org_id) or (location_id is null and public.is_org_member(org_id)) or public.can_access_salon_location(org_id,location_id))',tab||'_update',tab);
  execute format('drop policy if exists %I on public.%I',tab||'_delete',tab);
  execute format('create policy %I on public.%I for delete to authenticated using (public.is_org_super_admin(org_id))',tab||'_delete',tab);
 end loop;
end $$;

drop policy if exists stock_movements_select on public.stock_movements;
create policy stock_movements_select on public.stock_movements for select to authenticated using(
 public.is_org_super_admin(org_id) or (location_id is not null and public.can_access_salon_location(org_id,location_id)) or (location_id is null and public.is_org_member(org_id))
);
drop policy if exists stock_movements_insert on public.stock_movements;
create policy stock_movements_insert on public.stock_movements for insert to authenticated with check(
 public.is_org_super_admin(org_id) or (location_id is not null and public.can_access_salon_location(org_id,location_id)) or (location_id is null and public.is_org_member(org_id))
);
drop policy if exists stock_movements_update on public.stock_movements;
create policy stock_movements_update on public.stock_movements for update to authenticated using(
 public.is_org_super_admin(org_id) or (location_id is not null and public.can_access_salon_location(org_id,location_id)) or (location_id is null and public.is_org_member(org_id))
) with check(
 public.is_org_super_admin(org_id) or (location_id is not null and public.can_access_salon_location(org_id,location_id)) or (location_id is null and public.is_org_member(org_id))
);

-- Products and workshop records are branch scoped. Customer and loyalty tables stay org scoped.
do $$ declare tab text;begin
 foreach tab in array array['products','vehicles','workshop_job_cards'] loop
  execute format('drop policy if exists %I on public.%I',tab||'_select',tab);
  execute format('create policy %I on public.%I for select to authenticated using (public.is_org_super_admin(org_id) or (location_id is not null and public.can_access_salon_location(org_id,location_id)) or (location_id is null and public.is_org_member(org_id)))',tab||'_select',tab);
  execute format('drop policy if exists %I on public.%I',tab||'_insert',tab);
  execute format('create policy %I on public.%I for insert to authenticated with check (public.is_org_super_admin(org_id) or (location_id is not null and public.can_access_salon_location(org_id,location_id)) or (location_id is null and public.is_org_member(org_id)))',tab||'_insert',tab);
  execute format('drop policy if exists %I on public.%I',tab||'_update',tab);
  execute format('create policy %I on public.%I for update to authenticated using (public.is_org_super_admin(org_id) or (location_id is not null and public.can_access_salon_location(org_id,location_id)) or (location_id is null and public.is_org_member(org_id))) with check (public.is_org_super_admin(org_id) or (location_id is not null and public.can_access_salon_location(org_id,location_id)) or (location_id is null and public.is_org_member(org_id)))',tab||'_update',tab);
 end loop;
end $$;

create or replace function public.ensure_salon_primary_location() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.business_type in ('salon','automotive') and not exists(select 1 from public.salon_locations where org_id=new.id) then
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
 if not exists(select 1 from public.organizations where id=p_org_id and business_type in ('salon','automotive') and account_status='active') then raise exception 'Active branch-enabled workspace not found';end if;
 v_primary:=p_is_primary or not exists(select 1 from public.salon_locations where org_id=p_org_id);if v_primary then update public.salon_locations set is_primary=false where org_id=p_org_id;end if;
 insert into public.salon_locations(org_id,name,code,city,address,phone,employee_login_slug,is_primary,created_by)
 values(p_org_id,trim(p_name),nullif(upper(trim(p_code)),''),nullif(trim(p_city),''),nullif(trim(p_address),''),nullif(trim(p_phone),''),'',v_primary,auth.uid()) returning * into v_location;
 insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata) values(p_org_id,auth.uid(),'location.created','business_location',v_location.id::text,jsonb_build_object('name',v_location.name,'city',v_location.city));return to_jsonb(v_location);
end $$;

grant select,insert,update,delete on public.suppliers,public.automotive_services to authenticated;
grant execute on function public.create_salon_location(uuid,text,text,text,text,text,boolean) to authenticated;

drop function if exists public.checkout_pos(uuid,jsonb,uuid,text,numeric,numeric,boolean);
create or replace function public.checkout_pos(
 p_org_id uuid,p_items jsonb,p_customer_id uuid default null,p_payment_method text default 'cash',p_amount_tendered numeric default 0,
 p_loyalty_redeemed numeric default 0,p_store_change_as_loyalty boolean default false,p_location_id uuid default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_item jsonb;v_product public.products%rowtype;v_salon public.salon_services%rowtype;v_auto public.automotive_services%rowtype;v_customer public.retail_customers%rowtype;
 v_order uuid;v_receipt text;v_qty numeric(12,3);v_subtotal numeric(14,2):=0;v_cost numeric(14,2):=0;v_due numeric(14,2);v_change numeric(14,2):=0;v_credit numeric(14,2):=0;v_reward numeric(14,2):=0;v_balance numeric(14,2):=0;v_snapshot jsonb:='[]';v_appointment uuid;v_job uuid;v_location uuid;v_entry uuid;v_cash uuid;v_revenue uuid;v_inventory uuid;v_cogs uuid;v_loyalty_liability uuid;v_loyalty_expense uuid;
begin
 if not public.is_org_member(p_org_id) then raise exception 'Access denied';end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one item or service';end if;
 v_location:=coalesce(p_location_id,(select location_id from public.organization_user_access where org_id=p_org_id and user_id=auth.uid()),(select id from public.salon_locations where org_id=p_org_id and active=true order by is_primary desc,created_at limit 1));
 if v_location is not null and not public.can_access_salon_location(p_org_id,v_location) then raise exception 'This branch is not accessible to your account';end if;
 if p_payment_method not in ('cash','card','mobile') then raise exception 'Unsupported payment method';end if;
 if p_customer_id is not null then select * into v_customer from public.retail_customers where id=p_customer_id and org_id=p_org_id for update;if v_customer.id is null then raise exception 'Customer not found';end if;if p_loyalty_redeemed>v_customer.loyalty_balance then raise exception 'Not enough loyalty points';end if;
 elsif p_loyalty_redeemed>0 or p_store_change_as_loyalty then raise exception 'Select a customer to use loyalty';end if;
 for v_item in select value from jsonb_array_elements(p_items) loop
  v_qty:=coalesce((v_item->>'quantity')::numeric,0);if v_qty<=0 then raise exception 'Quantity must be greater than zero';end if;
  if nullif(v_item->>'automotive_service_id','') is not null then
   select * into v_auto from public.automotive_services where id=(v_item->>'automotive_service_id')::uuid and org_id=p_org_id and active=true and (location_id is null or location_id=v_location);
   if v_auto.id is null then raise exception 'Automotive service is not available at this branch';end if;
   if nullif(v_item->>'job_card_id','') is not null then v_job:=(v_item->>'job_card_id')::uuid;if not exists(select 1 from public.workshop_job_cards where id=v_job and org_id=p_org_id and location_id=v_location) then raise exception 'Job card does not match this branch';end if;end if;
   v_subtotal:=v_subtotal+round(v_qty*v_auto.price,2);v_snapshot:=v_snapshot||jsonb_build_array(jsonb_build_object('item_type','automotive_service','automotive_service_id',v_auto.id,'job_card_id',v_job,'sku',v_auto.code,'name',v_auto.name,'quantity',v_qty,'unit_price',v_auto.price,'unit_cost',0,'line_total',round(v_qty*v_auto.price,2)));
  elsif nullif(v_item->>'service_id','') is not null then
   select * into v_salon from public.salon_services where id=(v_item->>'service_id')::uuid and org_id=p_org_id and active=true;if v_salon.id is null then raise exception 'Salon service not found';end if;
   if nullif(v_item->>'appointment_id','') is not null then v_appointment:=(v_item->>'appointment_id')::uuid;if not exists(select 1 from public.salon_appointments where id=v_appointment and org_id=p_org_id and service_id=v_salon.id) then raise exception 'Appointment does not match this service';end if;end if;
   v_subtotal:=v_subtotal+round(v_qty*v_salon.price,2);v_snapshot:=v_snapshot||jsonb_build_array(jsonb_build_object('item_type','service','service_id',v_salon.id,'appointment_id',v_appointment,'sku','SRV-'||upper(left(replace(v_salon.id::text,'-',''),6)),'name',v_salon.name,'quantity',v_qty,'unit_price',v_salon.price,'unit_cost',0,'line_total',round(v_qty*v_salon.price,2)));
  else
   select * into v_product from public.products where id=(v_item->>'product_id')::uuid and org_id=p_org_id and active=true and (location_id is null or location_id=v_location) for update;
   if v_product.id is null then raise exception 'Product is not available at this branch';end if;if v_product.stock<v_qty then raise exception 'Only % units of % are available',v_product.stock,v_product.name;end if;
   v_subtotal:=v_subtotal+round(v_qty*v_product.price,2);v_cost:=v_cost+round(v_qty*v_product.cost,2);v_snapshot:=v_snapshot||jsonb_build_array(jsonb_build_object('item_type','product','product_id',v_product.id,'sku',v_product.sku,'name',v_product.name,'quantity',v_qty,'unit_price',v_product.price,'unit_cost',v_product.cost,'line_total',round(v_qty*v_product.price,2)));
  end if;
 end loop;
 if p_loyalty_redeemed<0 or p_loyalty_redeemed>v_subtotal then raise exception 'Invalid loyalty redemption';end if;v_due:=round(v_subtotal-p_loyalty_redeemed,2);
 if p_payment_method='cash' then if p_amount_tendered<v_due then raise exception 'Cash received is less than the amount due';end if;v_change:=round(p_amount_tendered-v_due,2);else p_amount_tendered:=v_due;end if;
 if p_store_change_as_loyalty then v_credit:=v_change;v_change:=0;end if;if p_customer_id is not null then v_reward:=floor(v_due/100);end if;
 v_receipt:='POS-'||to_char(clock_timestamp(),'YYMMDD-HH24MISS')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,4));
 insert into public.pos_orders(org_id,location_id,session_ref,receipt_number,customer,customer_id,items,total,payment_method,status,cashier_id,subtotal,discount,loyalty_redeemed,loyalty_earned,cash_received,change_due,change_to_loyalty,appointment_id,job_card_id)
 values(p_org_id,v_location,to_char(current_date,'YYYYMMDD'),v_receipt,v_customer.name,p_customer_id,v_snapshot,v_due,p_payment_method,'paid',auth.uid(),v_subtotal,p_loyalty_redeemed,p_loyalty_redeemed,v_reward,p_amount_tendered,v_change,v_credit,v_appointment,v_job) returning id into v_order;
 for v_item in select value from jsonb_array_elements(v_snapshot) loop
  insert into public.pos_order_items(pos_order_id,product_id,service_id,automotive_service_id,item_type,sku,item_name,quantity,unit_cost,unit_price)
  values(v_order,nullif(v_item->>'product_id','')::uuid,nullif(v_item->>'service_id','')::uuid,nullif(v_item->>'automotive_service_id','')::uuid,v_item->>'item_type',v_item->>'sku',v_item->>'name',(v_item->>'quantity')::numeric,(v_item->>'unit_cost')::numeric,(v_item->>'unit_price')::numeric);
  if v_item->>'item_type'='product' then update public.products set stock=stock-(v_item->>'quantity')::numeric,forecast=forecast-(v_item->>'quantity')::numeric where id=(v_item->>'product_id')::uuid;insert into public.stock_movements(org_id,location_id,product_id,movement_type,quantity,reference,created_by) values(p_org_id,v_location,(v_item->>'product_id')::uuid,'delivery',-(v_item->>'quantity')::numeric,v_receipt,auth.uid());end if;
 end loop;
 if v_appointment is not null then update public.salon_appointments set status='completed',pos_order_id=v_order where id=v_appointment;end if;
 if v_job is not null then update public.workshop_job_cards set actual_amount=v_subtotal,status='delivered',completed_at=now() where id=v_job;update public.vehicles v set current_mileage=greatest(v.current_mileage,j.odometer_in),last_service_at=now(),next_service_date=coalesce(j.next_service_date,v.next_service_date),next_service_mileage=coalesce(j.next_service_mileage,v.next_service_mileage) from public.workshop_job_cards j where j.id=v_job and v.id=j.vehicle_id;end if;
 if p_customer_id is not null then v_balance:=round(v_customer.loyalty_balance-p_loyalty_redeemed+v_reward+v_credit,2);update public.retail_customers set loyalty_balance=v_balance,total_spent=total_spent+v_subtotal,visits=visits+1,last_purchase_at=now() where id=p_customer_id;
  if p_loyalty_redeemed>0 then insert into public.loyalty_transactions(org_id,customer_id,pos_order_id,transaction_type,points,balance_after,description,created_by) values(p_org_id,p_customer_id,v_order,'redemption',-p_loyalty_redeemed,v_customer.loyalty_balance-p_loyalty_redeemed,'Redeemed on '||v_receipt,auth.uid());end if;
  if v_reward>0 then insert into public.loyalty_transactions(org_id,customer_id,pos_order_id,transaction_type,points,balance_after,description,created_by) values(p_org_id,p_customer_id,v_order,'purchase_reward',v_reward,v_customer.loyalty_balance-p_loyalty_redeemed+v_reward,'Rs. 1 earned per Rs. 100 spent',auth.uid());end if;
  if v_credit>0 then insert into public.loyalty_transactions(org_id,customer_id,pos_order_id,transaction_type,points,balance_after,description,created_by) values(p_org_id,p_customer_id,v_order,'change_credit',v_credit,v_balance,'Cash change stored as loyalty credit',auth.uid());end if;
 end if;
 perform public.ensure_default_accounts(p_org_id);
 insert into public.accounts(org_id,code,name,account_type) values(p_org_id,'1020','POS Cash & Card','asset_cash'),(p_org_id,'1200','Inventory','asset_current'),(p_org_id,'2150','Loyalty Credit Liability','liability_current'),(p_org_id,'5000','Cost of Goods Sold','expense'),(p_org_id,'6100','Loyalty Reward Expense','expense') on conflict(org_id,code) do nothing;
 select id into v_cash from public.accounts where org_id=p_org_id and code='1020';select id into v_revenue from public.accounts where org_id=p_org_id and code='4000';select id into v_inventory from public.accounts where org_id=p_org_id and code='1200';select id into v_cogs from public.accounts where org_id=p_org_id and code='5000';select id into v_loyalty_liability from public.accounts where org_id=p_org_id and code='2150';select id into v_loyalty_expense from public.accounts where org_id=p_org_id and code='6100';
 insert into public.journal_entries(org_id,reference,entry_date,description,status,source_type,source_id,created_by,posted_at) values(p_org_id,v_receipt,current_date,'POS sale','posted','pos',v_order,auth.uid(),now()) returning id into v_entry;
 if v_due+v_credit>0 then insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values(v_entry,v_cash,p_payment_method,v_due+v_credit,0);end if;
 insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values(v_entry,v_revenue,'Retail and service sales',0,v_subtotal);
 if p_loyalty_redeemed>0 then insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values(v_entry,v_loyalty_liability,'Loyalty redeemed',p_loyalty_redeemed,0);end if;
 if v_credit>0 then insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values(v_entry,v_loyalty_liability,'Change credited',0,v_credit);end if;
 if v_cost>0 then insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values(v_entry,v_cogs,'Cost of items sold',v_cost,0),(v_entry,v_inventory,'Inventory issued',0,v_cost);end if;
 if v_reward>0 then insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values(v_entry,v_loyalty_expense,'Purchase reward',v_reward,0),(v_entry,v_loyalty_liability,'Reward liability',0,v_reward);end if;
 return jsonb_build_object('order_id',v_order,'receipt_number',v_receipt,'subtotal',v_subtotal,'amount_due',v_due,'cash_received',p_amount_tendered,'change_due',v_change,'change_to_loyalty',v_credit,'loyalty_redeemed',p_loyalty_redeemed,'loyalty_earned',v_reward,'loyalty_balance',v_balance,'appointment_id',v_appointment,'job_card_id',v_job,'items',v_snapshot);
end $$;
grant execute on function public.checkout_pos(uuid,jsonb,uuid,text,numeric,numeric,boolean,uuid) to authenticated;

create or replace function public.modules_for_business_type(target_type text) returns jsonb language sql immutable as $$
 select case target_type when 'retail_grocery' then '["overview","pos","sales_history","customers","inventory","finance","people"]'::jsonb when 'pharmacy' then '["overview","pharmacy","pos","sales_history","customers","inventory","finance","people"]'::jsonb when 'salon' then '["overview","salon","service_catalog","reminders","pos","sales_history","customers","inventory","finance","people"]'::jsonb when 'automotive' then '["overview","automotive","pos","sales_history","customers","inventory","finance","people"]'::jsonb when 'general_erp' then '["overview","sales","sales_history","finance","inventory","people","services"]'::jsonb else '[]'::jsonb end
$$;
update public.organization_settings s set enabled_modules=public.modules_for_business_type(o.business_type) from public.organizations o where o.id=s.org_id and o.business_type='automotive';
