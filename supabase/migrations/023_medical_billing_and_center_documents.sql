begin;

alter table public.medical_centers
  add column if not exists email text,
  add column if not exists registration_number text,
  add column if not exists tax_number text,
  add column if not exists currency text not null default 'LKR',
  add column if not exists invoice_footer text;

alter table public.medical_doctors
  add column if not exists consultation_fee numeric(14,2) not null default 0 check(consultation_fee>=0);

alter table public.medical_queue_tickets
  add column if not exists consultation_fee numeric(14,2) not null default 0 check(consultation_fee>=0),
  add column if not exists paid_amount numeric(14,2) not null default 0 check(paid_amount>=0),
  add column if not exists invoice_number text,
  add column if not exists payment_status text not null default 'pending' check(payment_status in ('pending','part_paid','paid','waived')),
  add column if not exists payment_method text,
  add column if not exists invoice_issued_at timestamptz not null default now();

update public.medical_queue_tickets q
set consultation_fee=d.consultation_fee
from public.medical_doctors d
where d.id=q.doctor_id and q.consultation_fee=0 and d.consultation_fee>0;

update public.medical_queue_tickets
set invoice_number='MED-'||to_char(invoice_issued_at,'YYMM')||'-'||upper(substr(replace(id::text,'-',''),1,8))
where invoice_number is null;

create unique index if not exists medical_queue_invoice_number_idx
  on public.medical_queue_tickets(invoice_number)
  where invoice_number is not null;

create or replace function public.prepare_medical_queue_invoice()
returns trigger
language plpgsql
set search_path=public
as $$
declare v_fee numeric;
begin
  if new.consultation_fee is null or new.consultation_fee=0 then
    select consultation_fee into v_fee from public.medical_doctors where id=new.doctor_id;
    new.consultation_fee:=coalesce(v_fee,0);
  end if;
  if new.invoice_number is null then
    new.invoice_number:='MED-'||to_char(coalesce(new.invoice_issued_at,now()),'YYMM')||'-'||upper(substr(replace(new.id::text,'-',''),1,8));
  end if;
  return new;
end;
$$;

drop trigger if exists prepare_medical_queue_invoice on public.medical_queue_tickets;
create trigger prepare_medical_queue_invoice
before insert or update of doctor_id,consultation_fee,invoice_number
on public.medical_queue_tickets
for each row execute function public.prepare_medical_queue_invoice();

create or replace function public.record_medical_queue_payment(p_ticket_id uuid,p_amount numeric,p_method text default 'cash')
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_ticket public.medical_queue_tickets%rowtype;
begin
  if coalesce(p_amount,0)<=0 then raise exception 'Payment amount must be greater than zero'; end if;
  select * into v_ticket from public.medical_queue_tickets where id=p_ticket_id for update;
  if v_ticket.id is null or not public.can_operate_medical_center(v_ticket.center_id,'medical_issue') then raise exception 'Medical billing access denied'; end if;
  update public.medical_queue_tickets set
    paid_amount=least(consultation_fee,paid_amount+p_amount),
    payment_method=nullif(trim(p_method),''),
    payment_status=case when paid_amount+p_amount>=consultation_fee then 'paid' else 'part_paid' end
  where id=v_ticket.id returning * into v_ticket;
  insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_ticket.org_id,auth.uid(),'medical.invoice.payment_recorded','medical_queue_ticket',v_ticket.id::text,jsonb_build_object('invoice_number',v_ticket.invoice_number,'amount',p_amount,'method',p_method));
  return to_jsonb(v_ticket);
end;
$$;

create or replace function public.get_medical_ticket_status(p_token uuid)
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'display_number',q.display_number,
    'status',q.status,
    'doctor_name',d.name,
    'specialty',d.specialty,
    'room_label',d.room_label,
    'issued_at',q.issued_at,
    'called_at',q.called_at,
    'invoice_number',q.invoice_number,
    'consultation_fee',q.consultation_fee,
    'payment_status',q.payment_status,
    'center_name',c.name,
    'center_phone',c.phone,
    'center_email',c.email,
    'center_address',c.address,
    'center_registration_number',c.registration_number,
    'people_ahead',(select count(*) from public.medical_queue_tickets a where a.session_id=q.session_id and a.status='waiting' and a.queue_number<q.queue_number)
  )
  from public.medical_queue_tickets q
  join public.medical_doctors d on d.id=q.doctor_id
  join public.medical_centers c on c.id=q.center_id
  where q.public_token=p_token;
$$;

grant execute on function public.record_medical_queue_payment(uuid,numeric,text) to authenticated;
grant execute on function public.get_medical_ticket_status(uuid) to anon,authenticated;

commit;
