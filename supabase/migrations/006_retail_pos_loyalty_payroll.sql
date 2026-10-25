-- Grocery POS, customer loyalty, and payroll extensions.
-- Loyalty points are monetary credits: 1 point = Rs. 1.

create table if not exists public.retail_customers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  phone text not null,
  phone_normalized text not null,
  birthday date,
  email text,
  loyalty_balance numeric(14,2) not null default 0 check (loyalty_balance >= 0),
  total_spent numeric(14,2) not null default 0 check (total_spent >= 0),
  visits integer not null default 0 check (visits >= 0),
  last_purchase_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(org_id, phone_normalized)
);

alter table public.products add column if not exists barcode text;
alter table public.products add column if not exists tax_rate numeric(6,3) not null default 0;
create unique index if not exists products_org_barcode_unique on public.products(org_id, barcode) where barcode is not null;

alter table public.pos_orders add column if not exists customer_id uuid references public.retail_customers(id) on delete set null;
alter table public.pos_orders add column if not exists subtotal numeric(14,2) not null default 0;
alter table public.pos_orders add column if not exists discount numeric(14,2) not null default 0;
alter table public.pos_orders add column if not exists loyalty_redeemed numeric(14,2) not null default 0;
alter table public.pos_orders add column if not exists loyalty_earned numeric(14,2) not null default 0;
alter table public.pos_orders add column if not exists cash_received numeric(14,2) not null default 0;
alter table public.pos_orders add column if not exists change_due numeric(14,2) not null default 0;
alter table public.pos_orders add column if not exists change_to_loyalty numeric(14,2) not null default 0;

create table if not exists public.pos_order_items (
  id uuid primary key default gen_random_uuid(),
  pos_order_id uuid not null references public.pos_orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  sku text not null,
  item_name text not null,
  quantity numeric(12,3) not null check (quantity > 0),
  unit_cost numeric(14,2) not null default 0,
  unit_price numeric(14,2) not null check (unit_price >= 0),
  line_total numeric(14,2) generated always as (round(quantity * unit_price, 2)) stored
);

create table if not exists public.loyalty_transactions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid not null references public.retail_customers(id) on delete cascade,
  pos_order_id uuid references public.pos_orders(id) on delete set null,
  transaction_type text not null check (transaction_type in ('purchase_reward','change_credit','redemption','adjustment')),
  points numeric(14,2) not null,
  balance_after numeric(14,2) not null check (balance_after >= 0),
  description text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.employee_compensation (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  pay_type text not null default 'monthly' check (pay_type in ('monthly','hourly')),
  base_salary numeric(14,2) not null default 0 check (base_salary >= 0),
  hourly_rate numeric(14,2) not null default 0 check (hourly_rate >= 0),
  standard_hours numeric(8,2) not null default 0 check (standard_hours >= 0),
  fixed_allowances numeric(14,2) not null default 0 check (fixed_allowances >= 0),
  fixed_deductions numeric(14,2) not null default 0 check (fixed_deductions >= 0),
  epf_employee_rate numeric(6,3) not null default 8 check (epf_employee_rate >= 0),
  epf_employer_rate numeric(6,3) not null default 12 check (epf_employer_rate >= 0),
  etf_rate numeric(6,3) not null default 3 check (etf_rate >= 0),
  payment_method text not null default 'bank',
  bank_account_last4 text,
  effective_from date not null default current_date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(employee_id)
);

create table if not exists public.payroll_runs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  period_month date not null,
  status text not null default 'draft' check (status in ('draft','approved','paid','cancelled')),
  gross_pay numeric(14,2) not null default 0,
  employee_deductions numeric(14,2) not null default 0,
  employer_contributions numeric(14,2) not null default 0,
  net_pay numeric(14,2) not null default 0,
  approved_by uuid references auth.users(id) on delete set null,
  approved_at timestamptz,
  paid_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(org_id, period_month)
);

create table if not exists public.payroll_items (
  id uuid primary key default gen_random_uuid(),
  payroll_run_id uuid not null references public.payroll_runs(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete restrict,
  base_pay numeric(14,2) not null default 0,
  allowances numeric(14,2) not null default 0,
  gross_pay numeric(14,2) not null default 0,
  epf_employee numeric(14,2) not null default 0,
  other_deductions numeric(14,2) not null default 0,
  net_pay numeric(14,2) not null default 0,
  epf_employer numeric(14,2) not null default 0,
  etf_employer numeric(14,2) not null default 0,
  created_at timestamptz not null default now(),
  unique(payroll_run_id, employee_id)
);

create index if not exists retail_customers_org_id_idx on public.retail_customers(org_id);
create index if not exists retail_customers_phone_idx on public.retail_customers(org_id, phone_normalized);
create index if not exists pos_order_items_order_id_idx on public.pos_order_items(pos_order_id);
create index if not exists loyalty_transactions_org_customer_idx on public.loyalty_transactions(org_id, customer_id, created_at desc);
create index if not exists employee_compensation_org_id_idx on public.employee_compensation(org_id);
create index if not exists payroll_runs_org_id_idx on public.payroll_runs(org_id);
create index if not exists payroll_items_run_id_idx on public.payroll_items(payroll_run_id);

drop trigger if exists touch_updated_at on public.retail_customers;
create trigger touch_updated_at before update on public.retail_customers for each row execute function public.touch_updated_at();
drop trigger if exists touch_updated_at on public.employee_compensation;
create trigger touch_updated_at before update on public.employee_compensation for each row execute function public.touch_updated_at();

do $$ declare tab text; begin
  foreach tab in array array['retail_customers','loyalty_transactions','employee_compensation','payroll_runs'] loop
    execute format('alter table public.%I enable row level security',tab);
    execute format('drop policy if exists %I on public.%I',tab||'_select',tab);
    execute format('create policy %I on public.%I for select to authenticated using (public.is_org_member(org_id))',tab||'_select',tab);
    execute format('drop policy if exists %I on public.%I',tab||'_insert',tab);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.is_org_member(org_id))',tab||'_insert',tab);
    execute format('drop policy if exists %I on public.%I',tab||'_update',tab);
    execute format('create policy %I on public.%I for update to authenticated using (public.is_org_member(org_id)) with check (public.is_org_member(org_id))',tab||'_update',tab);
    execute format('drop policy if exists %I on public.%I',tab||'_delete',tab);
    execute format('create policy %I on public.%I for delete to authenticated using (public.can_manage_org(org_id))',tab||'_delete',tab);
  end loop;
end $$;

alter table public.pos_order_items enable row level security;
drop policy if exists pos_order_items_access on public.pos_order_items;
create policy pos_order_items_access on public.pos_order_items for select to authenticated
using (exists(select 1 from public.pos_orders o where o.id=pos_order_id and public.is_org_member(o.org_id)));

alter table public.payroll_items enable row level security;
drop policy if exists payroll_items_access on public.payroll_items;
create policy payroll_items_access on public.payroll_items for all to authenticated
using (exists(select 1 from public.payroll_runs r where r.id=payroll_run_id and public.can_manage_org(r.org_id)))
with check (exists(select 1 from public.payroll_runs r where r.id=payroll_run_id and public.can_manage_org(r.org_id)));

-- Compensation and payroll are intentionally manager-only, unlike the general employee directory.
do $$ declare tab text; begin
  foreach tab in array array['employee_compensation','payroll_runs'] loop
    execute format('drop policy if exists %I on public.%I',tab||'_select',tab);
    execute format('create policy %I on public.%I for select to authenticated using (public.can_manage_org(org_id))',tab||'_select',tab);
    execute format('drop policy if exists %I on public.%I',tab||'_insert',tab);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.can_manage_org(org_id))',tab||'_insert',tab);
    execute format('drop policy if exists %I on public.%I',tab||'_update',tab);
    execute format('create policy %I on public.%I for update to authenticated using (public.can_manage_org(org_id)) with check (public.can_manage_org(org_id))',tab||'_update',tab);
  end loop;
end $$;

create or replace function public.normalize_phone(raw_phone text) returns text language sql immutable as $$
  select regexp_replace(coalesce(raw_phone,''), '[^0-9+]', '', 'g')
$$;

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
  v_customer public.retail_customers%rowtype;
  v_order_id uuid;
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
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one item'; end if;
  if p_loyalty_redeemed < 0 then raise exception 'Loyalty redemption cannot be negative'; end if;
  if p_payment_method not in ('cash','card','mobile') then raise exception 'Unsupported payment method'; end if;

  if p_customer_id is not null then
    select * into v_customer from public.retail_customers where id=p_customer_id and org_id=p_org_id for update;
    if v_customer.id is null then raise exception 'Customer not found'; end if;
    if p_loyalty_redeemed > v_customer.loyalty_balance then raise exception 'Not enough loyalty points'; end if;
  elsif p_loyalty_redeemed > 0 or p_store_change_as_loyalty then
    raise exception 'Select a customer to use loyalty';
  end if;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_quantity := coalesce((v_item->>'quantity')::numeric,0);
    if v_quantity <= 0 then raise exception 'Item quantity must be greater than zero'; end if;
    select * into v_product from public.products
      where id=(v_item->>'product_id')::uuid and org_id=p_org_id and active=true for update;
    if v_product.id is null then raise exception 'Product not found'; end if;
    if v_product.stock < v_quantity then raise exception 'Only % units of % are available',v_product.stock,v_product.name; end if;
    v_subtotal := v_subtotal + round(v_quantity*v_product.price,2);
    v_cost_total := v_cost_total + round(v_quantity*v_product.cost,2);
    v_snapshot := v_snapshot || jsonb_build_array(jsonb_build_object(
      'product_id',v_product.id,'sku',v_product.sku,'name',v_product.name,
      'quantity',v_quantity,'unit_price',v_product.price,'unit_cost',v_product.cost,
      'line_total',round(v_quantity*v_product.price,2)
    ));
  end loop;

  if p_loyalty_redeemed > v_subtotal then raise exception 'Loyalty redemption cannot exceed the bill total'; end if;
  v_due := round(v_subtotal-p_loyalty_redeemed,2);
  if p_payment_method='cash' then
    if p_amount_tendered < v_due then raise exception 'Cash received is less than the amount due'; end if;
    v_change := round(p_amount_tendered-v_due,2);
  else
    p_amount_tendered := v_due;
  end if;
  if p_store_change_as_loyalty then v_change_credit := v_change; v_change := 0; end if;
  if p_customer_id is not null then v_reward := floor(v_due/100); end if;

  v_receipt := 'POS-'||to_char(clock_timestamp(),'YYMMDD-HH24MISS')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,4));
  insert into public.pos_orders(org_id,session_ref,receipt_number,customer,customer_id,items,total,payment_method,status,cashier_id,
    subtotal,discount,loyalty_redeemed,loyalty_earned,cash_received,change_due,change_to_loyalty)
  values(p_org_id,to_char(current_date,'YYYYMMDD'),v_receipt,v_customer.name,p_customer_id,v_snapshot,v_due,p_payment_method,'paid',auth.uid(),
    v_subtotal,p_loyalty_redeemed,p_loyalty_redeemed,v_reward,p_amount_tendered,v_change,v_change_credit)
  returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(v_snapshot) loop
    insert into public.pos_order_items(pos_order_id,product_id,sku,item_name,quantity,unit_cost,unit_price)
    values(v_order_id,(v_item->>'product_id')::uuid,v_item->>'sku',v_item->>'name',(v_item->>'quantity')::numeric,(v_item->>'unit_cost')::numeric,(v_item->>'unit_price')::numeric);
    update public.products set stock=stock-(v_item->>'quantity')::numeric, forecast=forecast-(v_item->>'quantity')::numeric where id=(v_item->>'product_id')::uuid;
    insert into public.stock_movements(org_id,product_id,movement_type,quantity,reference,created_by)
    values(p_org_id,(v_item->>'product_id')::uuid,'delivery',-(v_item->>'quantity')::numeric,v_receipt,auth.uid());
  end loop;

  if p_customer_id is not null then
    v_new_balance := round(v_customer.loyalty_balance-p_loyalty_redeemed+v_reward+v_change_credit,2);
    update public.retail_customers set loyalty_balance=v_new_balance,total_spent=total_spent+v_subtotal,
      visits=visits+1,last_purchase_at=now() where id=p_customer_id;
    if p_loyalty_redeemed>0 then
      insert into public.loyalty_transactions(org_id,customer_id,pos_order_id,transaction_type,points,balance_after,description,created_by)
      values(p_org_id,p_customer_id,v_order_id,'redemption',-p_loyalty_redeemed,v_customer.loyalty_balance-p_loyalty_redeemed,'Redeemed on '||v_receipt,auth.uid());
    end if;
    if v_reward>0 then
      insert into public.loyalty_transactions(org_id,customer_id,pos_order_id,transaction_type,points,balance_after,description,created_by)
      values(p_org_id,p_customer_id,v_order_id,'purchase_reward',v_reward,v_customer.loyalty_balance-p_loyalty_redeemed+v_reward,'Rs. 1 earned per Rs. 100 spent',auth.uid());
    end if;
    if v_change_credit>0 then
      insert into public.loyalty_transactions(org_id,customer_id,pos_order_id,transaction_type,points,balance_after,description,created_by)
      values(p_org_id,p_customer_id,v_order_id,'change_credit',v_change_credit,v_new_balance,'Cash change stored as loyalty credit',auth.uid());
    end if;
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
  if v_due+v_change_credit>0 then insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values(v_entry,v_cash,p_payment_method,v_due+v_change_credit,0); end if;
  insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values(v_entry,v_revenue,'Retail sales',0,v_subtotal);
  if p_loyalty_redeemed>0 then insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values(v_entry,v_loyalty_liability,'Loyalty redeemed',p_loyalty_redeemed,0); end if;
  if v_change_credit>0 then insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values(v_entry,v_loyalty_liability,'Change credited',0,v_change_credit); end if;
  if v_cost_total>0 then insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values
    (v_entry,v_cogs,'Cost of items sold',v_cost_total,0),(v_entry,v_inventory,'Inventory issued',0,v_cost_total); end if;
  if v_reward>0 then insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values
    (v_entry,v_loyalty_expense,'Purchase reward',v_reward,0),(v_entry,v_loyalty_liability,'Reward liability',0,v_reward); end if;

  return jsonb_build_object('order_id',v_order_id,'receipt_number',v_receipt,'subtotal',v_subtotal,'loyalty_redeemed',p_loyalty_redeemed,
    'amount_due',v_due,'cash_received',p_amount_tendered,'change_due',v_change,'change_to_loyalty',v_change_credit,
    'loyalty_earned',v_reward,'loyalty_balance',v_new_balance,'items',v_snapshot);
end $$;

create or replace function public.prepare_payroll_run(p_org_id uuid,p_period_month date) returns uuid
language plpgsql security definer set search_path=public as $$
declare v_run uuid; v_comp record; v_base numeric; v_gross numeric; v_epf numeric; v_net numeric;
begin
  if not public.can_manage_org(p_org_id) then raise exception 'Only workspace managers can prepare payroll'; end if;
  insert into public.payroll_runs(org_id,period_month,status,created_by)
  values(p_org_id,date_trunc('month',p_period_month)::date,'draft',auth.uid())
  on conflict(org_id,period_month) do update set status=case when payroll_runs.status='cancelled' then 'draft' else payroll_runs.status end returning id into v_run;
  if exists(select 1 from public.payroll_runs where id=v_run and status not in ('draft')) then raise exception 'Only a draft payroll can be recalculated'; end if;
  delete from public.payroll_items where payroll_run_id=v_run;
  for v_comp in select c.* from public.employee_compensation c join public.employees e on e.id=c.employee_id
    where c.org_id=p_org_id and e.employment_status='active' loop
    v_base := case when v_comp.pay_type='hourly' then round(v_comp.hourly_rate*v_comp.standard_hours,2) else v_comp.base_salary end;
    v_gross := v_base+v_comp.fixed_allowances;
    v_epf := round(v_base*v_comp.epf_employee_rate/100,2);
    v_net := v_gross-v_epf-v_comp.fixed_deductions;
    insert into public.payroll_items(payroll_run_id,employee_id,base_pay,allowances,gross_pay,epf_employee,other_deductions,net_pay,epf_employer,etf_employer)
    values(v_run,v_comp.employee_id,v_base,v_comp.fixed_allowances,v_gross,v_epf,v_comp.fixed_deductions,v_net,
      round(v_base*v_comp.epf_employer_rate/100,2),round(v_base*v_comp.etf_rate/100,2));
  end loop;
  update public.payroll_runs set
    gross_pay=coalesce((select sum(gross_pay) from public.payroll_items where payroll_run_id=v_run),0),
    employee_deductions=coalesce((select sum(epf_employee+other_deductions) from public.payroll_items where payroll_run_id=v_run),0),
    employer_contributions=coalesce((select sum(epf_employer+etf_employer) from public.payroll_items where payroll_run_id=v_run),0),
    net_pay=coalesce((select sum(net_pay) from public.payroll_items where payroll_run_id=v_run),0)
    where id=v_run;
  return v_run;
end $$;

create or replace function public.advance_payroll_run(p_run_id uuid,p_action text) returns text
language plpgsql security definer set search_path=public as $$
declare v_run public.payroll_runs%rowtype; v_entry uuid; v_expense uuid; v_cash uuid; v_payable uuid;
begin
  select * into v_run from public.payroll_runs where id=p_run_id for update;
  if v_run.id is null or not public.can_manage_org(v_run.org_id) then raise exception 'Payroll run not found or access denied'; end if;
  if p_action='approve' then
    if v_run.status<>'draft' then raise exception 'Only a draft payroll can be approved'; end if;
    if not exists(select 1 from public.payroll_items where payroll_run_id=v_run.id) then raise exception 'Payroll has no employee pay items'; end if;
    update public.payroll_runs set status='approved',approved_by=auth.uid(),approved_at=now() where id=v_run.id;
    return 'approved';
  elsif p_action='pay' then
    if v_run.status<>'approved' then raise exception 'Approve payroll before marking it paid'; end if;
    perform public.ensure_default_accounts(v_run.org_id);
    insert into public.accounts(org_id,code,name,account_type) values
      (v_run.org_id,'6000','Payroll & Employer Cost','expense'),(v_run.org_id,'2200','Payroll Liabilities','liability_current')
      on conflict(org_id,code) do nothing;
    select id into v_expense from public.accounts where org_id=v_run.org_id and code='6000';
    select id into v_cash from public.accounts where org_id=v_run.org_id and code='1010';
    select id into v_payable from public.accounts where org_id=v_run.org_id and code='2200';
    insert into public.journal_entries(org_id,reference,entry_date,description,status,source_type,source_id,created_by,posted_at)
    values(v_run.org_id,'PAYROLL-'||to_char(v_run.period_month,'YYYY-MM'),current_date,'Payroll payment','posted','payroll',v_run.id,auth.uid(),now()) returning id into v_entry;
    insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values
      (v_entry,v_expense,'Gross payroll and employer contributions',v_run.gross_pay+v_run.employer_contributions,0),
      (v_entry,v_cash,'Net pay disbursed',0,v_run.net_pay),
      (v_entry,v_payable,'Deductions and statutory contributions',0,v_run.employee_deductions+v_run.employer_contributions);
    update public.payroll_runs set status='paid',paid_at=now() where id=v_run.id;
    return 'paid';
  else
    raise exception 'Unsupported payroll action';
  end if;
end $$;

grant select,insert,update,delete on public.retail_customers,public.employee_compensation,public.payroll_runs to authenticated;
grant select on public.pos_order_items,public.loyalty_transactions to authenticated;
grant select,insert,update,delete on public.payroll_items to authenticated;
grant execute on function public.normalize_phone(text),public.checkout_pos(uuid,jsonb,uuid,text,numeric,numeric,boolean),public.prepare_payroll_run(uuid,date),public.advance_payroll_run(uuid,text) to authenticated;

-- Convert only the original, recognizable demo catalog into a grocery-ready demo.
update public.products set sku='GR-1001',barcode='479100100001',name='Samba Rice 5kg',category='Rice & grains',cost=2050,price=2390,reorder_level=20
where sku='NX-1001' and name='Ergo Task Chair';
update public.products set sku='GR-1002',barcode='479100100002',name='Fresh Milk 1L',category='Dairy',cost=370,price=440,reorder_level=20
where sku='NX-1002' and name='Walnut Standing Desk';
update public.products set sku='GR-2004',barcode='479100100003',name='Coconut Oil 1L',category='Cooking',cost=780,price=920,reorder_level=15
where sku='NX-2004' and name='Studio Lamp';
update public.products set sku='GR-3012',barcode='479100100004',name='Brown Sugar 1kg',category='Essentials',cost=285,price=340,reorder_level=20
where sku='NX-3012' and name='Acoustic Panel Set';
