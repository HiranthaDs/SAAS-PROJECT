create table if not exists public.accounts (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  code text not null, name text not null, account_type text not null, active boolean not null default true,
  created_at timestamptz not null default now(), unique(org_id,code)
);
create table if not exists public.journal_entries (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  reference text not null, entry_date date not null default current_date, description text, status text not null default 'draft' check(status in ('draft','posted','cancelled')),
  source_type text, source_id uuid, created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(), posted_at timestamptz
);
create table if not exists public.journal_lines (
  id uuid primary key default gen_random_uuid(), journal_entry_id uuid not null references public.journal_entries(id) on delete cascade,
  account_id uuid not null references public.accounts(id), label text, debit numeric(14,2) not null default 0 check(debit>=0), credit numeric(14,2) not null default 0 check(credit>=0),
  constraint journal_line_one_side check ((debit=0 and credit>0) or (credit=0 and debit>0))
);
create table if not exists public.sales_orders (
  id uuid primary key default gen_random_uuid(), org_id uuid not null references public.organizations(id) on delete cascade,
  number text not null, customer text not null, customer_email text, status text not null default 'draft' check(status in ('draft','sent','confirmed','delivered','cancelled')),
  order_date date not null default current_date, valid_until date, currency text not null default 'USD', untaxed_amount numeric(14,2) not null default 0,
  tax_amount numeric(14,2) not null default 0, total_amount numeric(14,2) not null default 0, invoice_id uuid references public.invoices(id) on delete set null,
  salesperson_id uuid references auth.users(id) on delete set null, notes text, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(org_id,number)
);
create table if not exists public.sales_order_lines (
  id uuid primary key default gen_random_uuid(), sales_order_id uuid not null references public.sales_orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete restrict, description text not null, quantity numeric(12,2) not null check(quantity>0),
  unit_price numeric(14,2) not null check(unit_price>=0), tax_rate numeric(6,3) not null default 0 check(tax_rate>=0),
  subtotal numeric(14,2) generated always as (round(quantity*unit_price,2)) stored,
  tax_amount numeric(14,2) generated always as (round(quantity*unit_price*tax_rate/100,2)) stored
);

create index if not exists accounts_org_id_idx on public.accounts(org_id);
create index if not exists journal_entries_org_id_idx on public.journal_entries(org_id);
create index if not exists journal_lines_entry_id_idx on public.journal_lines(journal_entry_id);
create index if not exists sales_orders_org_id_idx on public.sales_orders(org_id);
create index if not exists sales_order_lines_order_id_idx on public.sales_order_lines(sales_order_id);

create or replace function public.recalculate_sales_order() returns trigger language plpgsql security definer set search_path=public as $$
declare target uuid;
begin
  target := coalesce(new.sales_order_id,old.sales_order_id);
  update public.sales_orders set
    untaxed_amount=coalesce((select sum(subtotal) from public.sales_order_lines where sales_order_id=target),0),
    tax_amount=coalesce((select sum(tax_amount) from public.sales_order_lines where sales_order_id=target),0),
    total_amount=coalesce((select sum(subtotal+tax_amount) from public.sales_order_lines where sales_order_id=target),0), updated_at=now()
  where id=target;
  return coalesce(new,old);
end $$;
drop trigger if exists sales_order_lines_recalculate on public.sales_order_lines;
create trigger sales_order_lines_recalculate after insert or update or delete on public.sales_order_lines for each row execute function public.recalculate_sales_order();
drop trigger if exists touch_updated_at on public.sales_orders;
create trigger touch_updated_at before update on public.sales_orders for each row execute function public.touch_updated_at();

create or replace function public.ensure_default_accounts(target_org uuid) returns void language plpgsql security definer set search_path=public as $$
begin
  insert into public.accounts(org_id,code,name,account_type) values
    (target_org,'1100','Accounts Receivable','asset_receivable'),(target_org,'1010','Bank','asset_cash'),
    (target_org,'4000','Sales Revenue','income'),(target_org,'2100','Tax Payable','liability_current')
  on conflict(org_id,code) do nothing;
end $$;

create or replace function public.confirm_sales_order(order_id uuid) returns uuid language plpgsql security definer set search_path=public as $$
declare so public.sales_orders%rowtype; ln record; new_invoice uuid; new_entry uuid; ar uuid; revenue uuid; tax_account uuid; invoice_number text;
begin
  select * into so from public.sales_orders where id=order_id for update;
  if so.id is null or not public.is_org_member(so.org_id) then raise exception 'Sales order not found or access denied'; end if;
  if so.status not in ('draft','sent') then raise exception 'Only draft or sent orders can be confirmed'; end if;
  if not exists(select 1 from public.sales_order_lines where sales_order_id=so.id) then raise exception 'Add at least one order line'; end if;
  for ln in select l.*,p.stock,p.name product_name from public.sales_order_lines l left join public.products p on p.id=l.product_id where l.sales_order_id=so.id loop
    if ln.product_id is not null and not exists(select 1 from public.products p where p.id=ln.product_id and p.org_id=so.org_id) then raise exception 'Product does not belong to this workspace'; end if;
    if ln.product_id is not null and ln.stock < ln.quantity then raise exception 'Insufficient stock for %: % available, % requested',ln.product_name,ln.stock,ln.quantity; end if;
  end loop;
  invoice_number := 'INV-'||to_char(current_date,'YYYY')||'-'||upper(substr(replace(so.id::text,'-',''),1,8));
  insert into public.invoices(org_id,number,customer,issue_date,due_date,status,currency,subtotal,tax,notes,created_by)
  values(so.org_id,invoice_number,so.customer,current_date,current_date+30,'Pending',so.currency,so.untaxed_amount,so.tax_amount,'Created from '||so.number,(select auth.uid())) returning id into new_invoice;
  for ln in select l.*,p.name product_name from public.sales_order_lines l left join public.products p on p.id=l.product_id where l.sales_order_id=so.id loop
    insert into public.invoice_items(invoice_id,description,quantity,unit_price) values(new_invoice,ln.description,ln.quantity,ln.unit_price);
    if ln.product_id is not null then
      update public.products set stock=stock-ln.quantity,forecast=forecast-ln.quantity where id=ln.product_id;
      insert into public.stock_movements(org_id,product_id,movement_type,quantity,reference,created_by) values(so.org_id,ln.product_id,'delivery',-ln.quantity,so.number,(select auth.uid()));
    end if;
  end loop;
  perform public.ensure_default_accounts(so.org_id);
  select id into ar from public.accounts where org_id=so.org_id and code='1100';
  select id into revenue from public.accounts where org_id=so.org_id and code='4000';
  select id into tax_account from public.accounts where org_id=so.org_id and code='2100';
  insert into public.journal_entries(org_id,reference,description,status,source_type,source_id,created_by,posted_at)
  values(so.org_id,invoice_number,'Customer invoice for '||so.number,'posted','invoice',new_invoice,(select auth.uid()),now()) returning id into new_entry;
  insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values
    (new_entry,ar,so.customer,so.total_amount,0),(new_entry,revenue,'Sales revenue',0,so.untaxed_amount);
  if so.tax_amount>0 then insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values(new_entry,tax_account,'Sales tax',0,so.tax_amount); end if;
  update public.sales_orders set status='confirmed',invoice_id=new_invoice where id=so.id;
  return new_invoice;
end $$;

create or replace function public.record_invoice_payment(invoice_id uuid, payment_amount numeric) returns uuid language plpgsql security definer set search_path=public as $$
declare inv public.invoices%rowtype; entry_id uuid; bank uuid; ar uuid;
begin
  select * into inv from public.invoices where id=invoice_id for update;
  if inv.id is null or not public.is_org_member(inv.org_id) then raise exception 'Invoice not found or access denied'; end if;
  if inv.status='Paid' then raise exception 'Invoice is already paid'; end if;
  if payment_amount<>inv.total then raise exception 'Payment must equal outstanding invoice total of %',inv.total; end if;
  perform public.ensure_default_accounts(inv.org_id);
  select id into bank from public.accounts where org_id=inv.org_id and code='1010'; select id into ar from public.accounts where org_id=inv.org_id and code='1100';
  insert into public.journal_entries(org_id,reference,description,status,source_type,source_id,created_by,posted_at)
  values(inv.org_id,'PAY-'||inv.number,'Payment for '||inv.number,'posted','payment',inv.id,(select auth.uid()),now()) returning id into entry_id;
  insert into public.journal_lines(journal_entry_id,account_id,label,debit,credit) values(entry_id,bank,'Bank receipt',payment_amount,0),(entry_id,ar,inv.customer,0,payment_amount);
  update public.invoices set status='Paid' where id=inv.id;
  return entry_id;
end $$;

do $$ declare tab text; begin
  foreach tab in array array['accounts','journal_entries','sales_orders'] loop
    execute format('alter table public.%I enable row level security',tab);
    execute format('drop policy if exists %I on public.%I',tab||'_select',tab); execute format('create policy %I on public.%I for select to authenticated using (public.is_org_member(org_id))',tab||'_select',tab);
    execute format('drop policy if exists %I on public.%I',tab||'_insert',tab); execute format('create policy %I on public.%I for insert to authenticated with check (public.is_org_member(org_id))',tab||'_insert',tab);
    execute format('drop policy if exists %I on public.%I',tab||'_update',tab); execute format('create policy %I on public.%I for update to authenticated using (public.is_org_member(org_id)) with check (public.is_org_member(org_id))',tab||'_update',tab);
    execute format('drop policy if exists %I on public.%I',tab||'_delete',tab); execute format('create policy %I on public.%I for delete to authenticated using (public.can_manage_org(org_id))',tab||'_delete',tab);
  end loop;
end $$;
alter table public.sales_order_lines enable row level security; alter table public.journal_lines enable row level security;
drop policy if exists sales_order_lines_access on public.sales_order_lines;
create policy sales_order_lines_access on public.sales_order_lines for all to authenticated
using(exists(select 1 from public.sales_orders s where s.id=sales_order_id and public.is_org_member(s.org_id)))
with check(exists(
  select 1 from public.sales_orders s
  where s.id=sales_order_id and public.is_org_member(s.org_id)
    and (product_id is null or exists(select 1 from public.products p where p.id=product_id and p.org_id=s.org_id))
));
drop policy if exists journal_lines_access on public.journal_lines;
create policy journal_lines_access on public.journal_lines for select to authenticated using(exists(select 1 from public.journal_entries e where e.id=journal_entry_id and public.is_org_member(e.org_id)));
grant select,insert,update,delete on public.accounts,public.journal_entries,public.sales_orders,public.sales_order_lines to authenticated;
grant select on public.journal_lines to authenticated;
grant execute on function public.confirm_sales_order(uuid),public.record_invoice_payment(uuid,numeric) to authenticated;
