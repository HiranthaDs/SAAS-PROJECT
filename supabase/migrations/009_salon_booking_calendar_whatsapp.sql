-- Salon public booking, calendar, service checkout, and WhatsApp reminder workflow.

alter table public.organizations add column if not exists booking_slug text;
alter table public.organizations add column if not exists booking_link_updated_at timestamptz;
update public.organizations
set booking_slug=coalesce(booking_slug,slug||'-book'),booking_link_updated_at=coalesce(booking_link_updated_at,now())
where booking_slug is null;
create unique index if not exists organizations_booking_slug_unique on public.organizations(booking_slug) where booking_slug is not null;

create or replace function public.ensure_salon_booking_slug() returns trigger language plpgsql set search_path=public as $$
begin
  if new.business_type='salon' and new.booking_slug is null then
    new.booking_slug:=new.slug||'-book';
    new.booking_link_updated_at:=now();
  end if;
  return new;
end $$;
drop trigger if exists ensure_salon_booking_slug on public.organizations;
create trigger ensure_salon_booking_slug before insert or update of business_type on public.organizations
for each row execute function public.ensure_salon_booking_slug();

alter table public.salon_appointments add column if not exists source text not null default 'admin';
alter table public.salon_appointments add column if not exists reminder_status text not null default 'pending';
alter table public.salon_appointments add column if not exists reminder_sent_at timestamptz;
alter table public.salon_appointments add column if not exists customer_email text;
alter table public.salon_appointments add column if not exists pos_order_id uuid references public.pos_orders(id) on delete set null;
alter table public.pos_orders add column if not exists appointment_id uuid references public.salon_appointments(id) on delete set null;
alter table public.pos_order_items add column if not exists service_id uuid references public.salon_services(id) on delete set null;
alter table public.pos_order_items add column if not exists item_type text not null default 'product';

create index if not exists salon_appointments_start_idx on public.salon_appointments(org_id,starts_at);
create index if not exists salon_appointments_reminder_idx on public.salon_appointments(org_id,reminder_status,starts_at);

create or replace function public.modules_for_business_type(target_type text) returns jsonb
language sql immutable as $$
  select case target_type
    when 'retail_grocery' then '["overview","pos","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'pharmacy' then '["overview","pharmacy","pos","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'salon' then '["overview","salon","reminders","pos","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'automotive' then '["overview","automotive","sales_history","customers","inventory","finance","people"]'::jsonb
    when 'general_erp' then '["overview","sales","sales_history","finance","inventory","people","services"]'::jsonb
    else '[]'::jsonb
  end
$$;

update public.organization_settings s
set enabled_modules=public.modules_for_business_type(o.business_type)
from public.organizations o
where o.id=s.org_id and o.business_type='salon';

create or replace function public.get_public_salon_booking(p_slug text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_org public.organizations%rowtype; v_settings public.organization_settings%rowtype; v_services jsonb;
begin
  select * into v_org from public.organizations where booking_slug=p_slug and business_type='salon';
  if v_org.id is null then raise exception 'This booking link is unavailable'; end if;
  select * into v_settings from public.organization_settings where org_id=v_org.id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'name',name,'category',coalesce(category,'Services'),'duration_minutes',duration_minutes,'price',price
  ) order by name),'[]'::jsonb) into v_services from public.salon_services where org_id=v_org.id and active=true;
  return jsonb_build_object(
    'salon',jsonb_build_object('name',v_org.name,'phone',v_org.phone,'address',v_org.address,'slug',v_org.booking_slug),
    'services',v_services,
    'opening_time',coalesce(v_settings.preferences->>'opening_time','09:00'),
    'closing_time',coalesce(v_settings.preferences->>'closing_time','19:00'),
    'booking_interval',coalesce((v_settings.preferences->>'booking_interval')::integer,30)
  );
end $$;

create or replace function public.book_public_salon_appointment(
  p_slug text,p_service_id uuid,p_customer_name text,p_customer_phone text,p_customer_email text,
  p_starts_at timestamptz,p_notes text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_org public.organizations%rowtype;
  v_service public.salon_services%rowtype;
  v_customer public.retail_customers%rowtype;
  v_staff public.employees%rowtype;
  v_phone text;
  v_ends_at timestamptz;
  v_appointment uuid;
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

  select * into v_staff from public.employees e where e.org_id=v_org.id and e.employment_status='active'
    and not exists(select 1 from public.salon_appointments a where a.org_id=v_org.id and a.staff_id=e.id
      and a.status not in ('cancelled','no_show') and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(p_starts_at,v_ends_at,'[)'))
    order by e.name limit 1;
  if exists(select 1 from public.employees where org_id=v_org.id and employment_status='active') and v_staff.id is null then
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
  return jsonb_build_object('appointment_id',v_appointment,'salon',v_org.name,'service',v_service.name,'starts_at',p_starts_at,
    'ends_at',v_ends_at,'staff',v_staff.name,'status','booked');
end $$;

create or replace function public.regenerate_salon_booking_link(p_org_id uuid) returns text
language plpgsql security definer set search_path=public as $$
declare v_slug text;
begin
  if not public.can_manage_org(p_org_id) then raise exception 'Only a workspace manager can update the booking link'; end if;
  select slug||'-book-'||lower(substr(replace(gen_random_uuid()::text,'-',''),1,6)) into v_slug from public.organizations where id=p_org_id;
  update public.organizations set booking_slug=v_slug,booking_link_updated_at=now() where id=p_org_id;
  return v_slug;
end $$;

create or replace function public.mark_whatsapp_reminder_sent(p_appointment_id uuid) returns text
language plpgsql security definer set search_path=public as $$
declare v_org uuid;
begin
  select org_id into v_org from public.salon_appointments where id=p_appointment_id;
  if v_org is null or not public.is_org_member(v_org) then raise exception 'Appointment not found or access denied'; end if;
  update public.salon_appointments set reminder_status='sent',reminder_sent_at=now() where id=p_appointment_id;
  return 'sent';
end $$;

create or replace function public.checkout_pos(
  p_org_id uuid,
  p_items jsonb,
  p_customer_id uuid default null,
  p_payment_method text default 'cash',
  p_amount_tendered numeric default 0,
  p_loyalty_redeemed numeric default 0,
  p_store_change_as_loyalty boolean default false
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_item jsonb;
  v_product public.products%rowtype;
  v_service public.salon_services%rowtype;
  v_customer public.retail_customers%rowtype;
  v_order_id uuid;
  v_appointment_id uuid;
  v_receipt text;
  v_quantity numeric(12,3);
  v_subtotal numeric(14,2) := 0;
  v_cost_total numeric(14,2) := 0;
  v_due numeric(14,2);
  v_change numeric(14,2) := 0;
  v_change_credit numeric(14,2) := 0;
  v_reward numeric(14,2) := 0;
  v_new_balance numeric(14,2) := 0;
  v_snapshot jsonb := '[]'::jsonb;
  v_entry uuid;
  v_cash uuid;
  v_revenue uuid;
  v_inventory uuid;
  v_cogs uuid;
  v_loyalty_liability uuid;
  v_loyalty_expense uuid;
begin
  if not public.is_org_member(p_org_id) then raise exception 'Access denied'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one item or service'; end if;
  if p_loyalty_redeemed<0 then raise exception 'Loyalty redemption cannot be negative'; end if;
  if p_payment_method not in ('cash','card','mobile') then raise exception 'Unsupported payment method'; end if;
  if p_customer_id is not null then
    select * into v_customer from public.retail_customers where id=p_customer_id and org_id=p_org_id for update;
    if v_customer.id is null then raise exception 'Customer not found'; end if;
    if p_loyalty_redeemed>v_customer.loyalty_balance then raise exception 'Not enough loyalty points'; end if;
  elsif p_loyalty_redeemed>0 or p_store_change_as_loyalty then raise exception 'Select a customer to use loyalty'; end if;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_quantity:=coalesce((v_item->>'quantity')::numeric,0);
    if v_quantity<=0 then raise exception 'Quantity must be greater than zero'; end if;
    if nullif(v_item->>'service_id','') is not null then
      select * into v_service from public.salon_services where id=(v_item->>'service_id')::uuid and org_id=p_org_id and active=true;
      if v_service.id is null then raise exception 'Salon service not found'; end if;
      if nullif(v_item->>'appointment_id','') is not null then
        v_appointment_id:=(v_item->>'appointment_id')::uuid;
        if not exists(select 1 from public.salon_appointments where id=v_appointment_id and org_id=p_org_id and service_id=v_service.id) then raise exception 'Appointment does not match this service'; end if;
      end if;
      v_subtotal:=v_subtotal+round(v_quantity*v_service.price,2);
      v_snapshot:=v_snapshot||jsonb_build_array(jsonb_build_object('item_type','service','service_id',v_service.id,
        'appointment_id',v_appointment_id,'sku','SRV-'||upper(left(replace(v_service.id::text,'-',''),6)),'name',v_service.name,
        'quantity',v_quantity,'unit_price',v_service.price,'unit_cost',0,'line_total',round(v_quantity*v_service.price,2)));
    else
      select * into v_product from public.products where id=(v_item->>'product_id')::uuid and org_id=p_org_id and active=true for update;
      if v_product.id is null then raise exception 'Product not found'; end if;
      if v_product.stock<v_quantity then raise exception 'Only % units of % are available',v_product.stock,v_product.name; end if;
      v_subtotal:=v_subtotal+round(v_quantity*v_product.price,2);v_cost_total:=v_cost_total+round(v_quantity*v_product.cost,2);
      v_snapshot:=v_snapshot||jsonb_build_array(jsonb_build_object('item_type','product','product_id',v_product.id,'sku',v_product.sku,
        'name',v_product.name,'quantity',v_quantity,'unit_price',v_product.price,'unit_cost',v_product.cost,
        'line_total',round(v_quantity*v_product.price,2)));
    end if;
  end loop;

  if p_loyalty_redeemed>v_subtotal then raise exception 'Loyalty redemption cannot exceed the bill total'; end if;
  v_due:=round(v_subtotal-p_loyalty_redeemed,2);
  if p_payment_method='cash' then
    if p_amount_tendered<v_due then raise exception 'Cash received is less than the amount due'; end if;
    v_change:=round(p_amount_tendered-v_due,2);
  else p_amount_tendered:=v_due; end if;
  if p_store_change_as_loyalty then v_change_credit:=v_change;v_change:=0;end if;
  if p_customer_id is not null then v_reward:=floor(v_due/100);end if;

  v_receipt:='POS-'||to_char(clock_timestamp(),'YYMMDD-HH24MISS')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,4));
  insert into public.pos_orders(org_id,session_ref,receipt_number,customer,customer_id,items,total,payment_method,status,cashier_id,
    subtotal,discount,loyalty_redeemed,loyalty_earned,cash_received,change_due,change_to_loyalty,appointment_id)
  values(p_org_id,to_char(current_date,'YYYYMMDD'),v_receipt,v_customer.name,p_customer_id,v_snapshot,v_due,p_payment_method,'paid',auth.uid(),
    v_subtotal,p_loyalty_redeemed,p_loyalty_redeemed,v_reward,p_amount_tendered,v_change,v_change_credit,v_appointment_id) returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(v_snapshot) loop
    insert into public.pos_order_items(pos_order_id,product_id,service_id,item_type,sku,item_name,quantity,unit_cost,unit_price)
    values(v_order_id,nullif(v_item->>'product_id','')::uuid,nullif(v_item->>'service_id','')::uuid,coalesce(v_item->>'item_type','product'),
      v_item->>'sku',v_item->>'name',(v_item->>'quantity')::numeric,(v_item->>'unit_cost')::numeric,(v_item->>'unit_price')::numeric);
    if coalesce(v_item->>'item_type','product')='product' then
      update public.products set stock=stock-(v_item->>'quantity')::numeric,forecast=forecast-(v_item->>'quantity')::numeric where id=(v_item->>'product_id')::uuid;
      insert into public.stock_movements(org_id,product_id,movement_type,quantity,reference,created_by)
      values(p_org_id,(v_item->>'product_id')::uuid,'delivery',-(v_item->>'quantity')::numeric,v_receipt,auth.uid());
    end if;
  end loop;
  if v_appointment_id is not null then update public.salon_appointments set status='completed',pos_order_id=v_order_id where id=v_appointment_id;end if;

  if p_customer_id is not null then
    v_new_balance:=round(v_customer.loyalty_balance-p_loyalty_redeemed+v_reward+v_change_credit,2);
    update public.retail_customers set loyalty_balance=v_new_balance,total_spent=total_spent+v_subtotal,visits=visits+1,last_purchase_at=now() where id=p_customer_id;
    if p_loyalty_redeemed>0 then insert into public.loyalty_transactions(org_id,customer_id,pos_order_id,transaction_type,points,balance_after,description,created_by)
      values(p_org_id,p_customer_id,v_order_id,'redemption',-p_loyalty_redeemed,v_customer.loyalty_balance-p_loyalty_redeemed,'Redeemed on '||v_receipt,auth.uid());end if;
    if v_reward>0 then insert into public.loyalty_transactions(org_id,customer_id,pos_order_id,transaction_type,points,balance_after,description,created_by)
      values(p_org_id,p_customer_id,v_order_id,'purchase_reward',v_reward,v_customer.loyalty_balance-p_loyalty_redeemed+v_reward,'Rs. 1 earned per Rs. 100 spent',auth.uid());end if;
    if v_change_credit>0 then insert into public.loyalty_transactions(org_id,customer_id,pos_order_id,transaction_type,points,balance_after,description,created_by)
      values(p_org_id,p_customer_id,v_order_id,'change_credit',v_change_credit,v_new_balance,'Cash change stored as loyalty credit',auth.uid());end if;
  end if;

  perform public.ensure_default_accounts(p_org_id);
  insert into public.accounts(org_id,code,name,account_type) values
    (p_org_id,'1020','POS Cash & Card','asset_cash'),(p_org_id,'1200','Inventory','asset_current'),
    (p_org_id,'2150','Loyalty Credit Liability','liability_current'),(p_org_id,'5000','Cost of Goods Sold','expense'),
    (p_org_id,'6100','Loyalty Reward Expense','expense') on conflict(org_id,code) do nothing;
  select id into v_cash from public.accounts where org_id=p_org_id and code='1020';
  select id into v_revenue from public.accounts where org_id=p_org_id and code='4000';
  select id into v_inventory from public.accounts where org_id=p_org_id and code='1200';
  select id into v_cogs from public.accounts where org_id=p_org_id and code='5000';
  select id into v_loyalty_liability from public.accounts where org_id=p_org_id and code='2150';
  select id into v_loyalty_expense from public.accounts where org_id=p_org_id and code='6100';
  insert into public.journal_entries(org_id,reference,entry_date,description,status,source_type,source_id,created_by,posted_at)
  values(p_org_id,v_receipt,current_date,'POS sale','posted','pos',v_order_id,auth.uid(),now()) returning id into v_entry;
  if v_due+v_change_credit>0 then insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values(v_entry,v_cash,p_payment_method,v_due+v_change_credit,0);end if;
  insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values(v_entry,v_revenue,'Retail and service sales',0,v_subtotal);
  if p_loyalty_redeemed>0 then insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values(v_entry,v_loyalty_liability,'Loyalty redeemed',p_loyalty_redeemed,0);end if;
  if v_change_credit>0 then insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values(v_entry,v_loyalty_liability,'Change credited',0,v_change_credit);end if;
  if v_cost_total>0 then insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values
    (v_entry,v_cogs,'Cost of items sold',v_cost_total,0),(v_entry,v_inventory,'Inventory issued',0,v_cost_total);end if;
  if v_reward>0 then insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values
    (v_entry,v_loyalty_expense,'Purchase reward',v_reward,0),(v_entry,v_loyalty_liability,'Reward liability',0,v_reward);end if;
  return jsonb_build_object('order_id',v_order_id,'receipt_number',v_receipt,'subtotal',v_subtotal,'loyalty_redeemed',p_loyalty_redeemed,
    'amount_due',v_due,'cash_received',p_amount_tendered,'change_due',v_change,'change_to_loyalty',v_change_credit,
    'loyalty_earned',v_reward,'loyalty_balance',v_new_balance,'appointment_id',v_appointment_id,'items',v_snapshot);
end $$;

grant execute on function public.get_public_salon_booking(text) to anon,authenticated;
grant execute on function public.book_public_salon_appointment(text,uuid,text,text,text,timestamptz,text) to anon,authenticated;
grant execute on function public.regenerate_salon_booking_link(uuid),public.mark_whatsapp_reminder_sent(uuid) to authenticated;
