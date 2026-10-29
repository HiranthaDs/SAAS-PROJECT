begin;

-- Every doctor session receives a private, unguessable capability URL. The token
-- is scoped to one session, so sharing a link never grants access to another
-- doctor, branch, or date.
alter table public.medical_sessions
  add column if not exists doctor_portal_token uuid;

update public.medical_sessions
set doctor_portal_token=gen_random_uuid()
where doctor_portal_token is null;

alter table public.medical_sessions
  alter column doctor_portal_token set default gen_random_uuid(),
  alter column doctor_portal_token set not null;

create unique index if not exists medical_sessions_doctor_portal_token_idx
  on public.medical_sessions(doctor_portal_token);

-- This table is intentionally safe for public realtime subscriptions. It never
-- contains patient names, phone numbers, notes, or private ticket tokens.
create table if not exists public.medical_public_queue_snapshots (
  session_id uuid primary key references public.medical_sessions(id) on delete cascade,
  org_id uuid not null references public.organizations(id) on delete cascade,
  center_id uuid not null references public.medical_centers(id) on delete cascade,
  doctor_id uuid not null references public.medical_doctors(id) on delete cascade,
  session_date date not null,
  starts_at time not null,
  ends_at time not null,
  slot_minutes integer not null,
  capacity integer not null,
  session_status text not null,
  doctor_name text not null,
  specialty text,
  room_label text,
  queue_prefix text not null,
  current_number text,
  current_status text,
  waiting_count integer not null default 0,
  issued_count integer not null default 0,
  completed_count integer not null default 0,
  updated_at timestamptz not null default now()
);

create index if not exists medical_public_queue_center_day_idx
  on public.medical_public_queue_snapshots(center_id,session_date,starts_at);

create or replace function public.refresh_medical_public_queue_snapshot(p_session_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_session public.medical_sessions%rowtype;
  v_doctor public.medical_doctors%rowtype;
  v_current public.medical_queue_tickets%rowtype;
  v_waiting integer;
  v_issued integer;
  v_completed integer;
begin
  select * into v_session from public.medical_sessions where id=p_session_id;
  if v_session.id is null then
    delete from public.medical_public_queue_snapshots where session_id=p_session_id;
    return;
  end if;

  select * into v_doctor from public.medical_doctors where id=v_session.doctor_id;
  if v_doctor.id is null then return; end if;

  select count(*) filter(where status='waiting')::integer,
         count(*) filter(where status<>'cancelled')::integer,
         count(*) filter(where status='completed')::integer
  into v_waiting,v_issued,v_completed
  from public.medical_queue_tickets
  where session_id=v_session.id;

  select * into v_current
  from public.medical_queue_tickets
  where session_id=v_session.id and status in ('called','in_consultation')
  order by case when status='in_consultation' then 0 else 1 end,
           called_at desc nulls last,
           queue_number
  limit 1;

  insert into public.medical_public_queue_snapshots(
    session_id,org_id,center_id,doctor_id,session_date,starts_at,ends_at,
    slot_minutes,capacity,session_status,doctor_name,specialty,room_label,
    queue_prefix,current_number,current_status,waiting_count,issued_count,
    completed_count,updated_at
  ) values(
    v_session.id,v_session.org_id,v_session.center_id,v_session.doctor_id,
    v_session.session_date,v_session.starts_at,v_session.ends_at,
    v_session.slot_minutes,v_session.capacity,v_session.status,v_doctor.name,
    v_doctor.specialty,v_doctor.room_label,v_doctor.queue_prefix,
    v_current.display_number,v_current.status,coalesce(v_waiting,0),
    coalesce(v_issued,0),coalesce(v_completed,0),now()
  )
  on conflict(session_id) do update set
    org_id=excluded.org_id,
    center_id=excluded.center_id,
    doctor_id=excluded.doctor_id,
    session_date=excluded.session_date,
    starts_at=excluded.starts_at,
    ends_at=excluded.ends_at,
    slot_minutes=excluded.slot_minutes,
    capacity=excluded.capacity,
    session_status=excluded.session_status,
    doctor_name=excluded.doctor_name,
    specialty=excluded.specialty,
    room_label=excluded.room_label,
    queue_prefix=excluded.queue_prefix,
    current_number=excluded.current_number,
    current_status=excluded.current_status,
    waiting_count=excluded.waiting_count,
    issued_count=excluded.issued_count,
    completed_count=excluded.completed_count,
    updated_at=now();
end;
$$;

create or replace function public.medical_queue_snapshot_ticket_trigger()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if tg_op='DELETE' then
    perform public.refresh_medical_public_queue_snapshot(old.session_id);
    return old;
  end if;
  perform public.refresh_medical_public_queue_snapshot(new.session_id);
  if tg_op='UPDATE' and old.session_id<>new.session_id then
    perform public.refresh_medical_public_queue_snapshot(old.session_id);
  end if;
  return new;
end;
$$;

drop trigger if exists medical_queue_snapshot_after_ticket on public.medical_queue_tickets;
create trigger medical_queue_snapshot_after_ticket
after insert or update or delete on public.medical_queue_tickets
for each row execute function public.medical_queue_snapshot_ticket_trigger();

create or replace function public.medical_queue_snapshot_session_trigger()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if tg_op='DELETE' then
    delete from public.medical_public_queue_snapshots where session_id=old.id;
    return old;
  end if;
  perform public.refresh_medical_public_queue_snapshot(new.id);
  return new;
end;
$$;

drop trigger if exists medical_queue_snapshot_after_session on public.medical_sessions;
create trigger medical_queue_snapshot_after_session
after insert or update or delete on public.medical_sessions
for each row execute function public.medical_queue_snapshot_session_trigger();

create or replace function public.medical_queue_snapshot_doctor_trigger()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare v_session record;
begin
  for v_session in select id from public.medical_sessions where doctor_id=new.id loop
    perform public.refresh_medical_public_queue_snapshot(v_session.id);
  end loop;
  return new;
end;
$$;

drop trigger if exists medical_queue_snapshot_after_doctor on public.medical_doctors;
create trigger medical_queue_snapshot_after_doctor
after update of name,specialty,room_label,queue_prefix,active on public.medical_doctors
for each row execute function public.medical_queue_snapshot_doctor_trigger();

select public.refresh_medical_public_queue_snapshot(id)
from public.medical_sessions;

create or replace function public.get_public_medical_monitor(p_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_center public.medical_centers%rowtype;
  v_today date;
  v_sessions jsonb;
begin
  select c.* into v_center
  from public.medical_centers c
  join public.organizations o on o.id=c.org_id
  where c.public_slug=p_slug
    and c.active=true
    and o.business_type='healthcare_clinic'
    and o.account_status='active';
  if v_center.id is null then raise exception 'This medical monitor is unavailable'; end if;

  v_today:=(now() at time zone v_center.timezone)::date;
  select coalesce(jsonb_agg(to_jsonb(s) order by s.starts_at,s.doctor_name),'[]'::jsonb)
  into v_sessions
  from public.medical_public_queue_snapshots s
  where s.center_id=v_center.id
    and s.session_date=v_today
    and s.session_status<>'cancelled';

  return jsonb_build_object(
    'center',jsonb_build_object(
      'id',v_center.id,
      'name',v_center.name,
      'phone',v_center.phone,
      'address',v_center.address,
      'slug',v_center.public_slug
    ),
    'date',v_today,
    'sessions',v_sessions
  );
end;
$$;

create or replace function public.get_medical_doctor_portal(p_token uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_session public.medical_sessions%rowtype;
  v_doctor public.medical_doctors%rowtype;
  v_center public.medical_centers%rowtype;
  v_tickets jsonb;
begin
  select s.* into v_session
  from public.medical_sessions s
  join public.medical_centers c on c.id=s.center_id and c.active=true
  join public.organizations o on o.id=s.org_id and o.account_status='active'
  where s.doctor_portal_token=p_token and s.status<>'cancelled';
  if v_session.id is null then raise exception 'This doctor portal is unavailable'; end if;

  select * into v_doctor from public.medical_doctors where id=v_session.doctor_id and active=true;
  select * into v_center from public.medical_centers where id=v_session.center_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',q.id,
    'display_number',q.display_number,
    'patient_name',q.patient_name,
    'status',q.status,
    'priority',q.priority,
    'issued_at',q.issued_at,
    'called_at',q.called_at,
    'consultation_started_at',q.consultation_started_at
  ) order by q.priority desc,q.queue_number),'[]'::jsonb)
  into v_tickets
  from public.medical_queue_tickets q
  where q.session_id=v_session.id and q.status<>'cancelled';

  return jsonb_build_object(
    'center',jsonb_build_object('id',v_center.id,'name',v_center.name,'address',v_center.address,'phone',v_center.phone),
    'doctor',jsonb_build_object('id',v_doctor.id,'name',v_doctor.name,'specialty',v_doctor.specialty,'room_label',v_doctor.room_label,'queue_prefix',v_doctor.queue_prefix),
    'session',jsonb_build_object('id',v_session.id,'session_date',v_session.session_date,'starts_at',v_session.starts_at,'ends_at',v_session.ends_at,'slot_minutes',v_session.slot_minutes,'capacity',v_session.capacity,'status',v_session.status),
    'tickets',v_tickets
  );
end;
$$;

-- Calling the next patient is serialized per session. An already active patient
-- is returned instead of allowing two patients to be called simultaneously.
create or replace function public.call_next_medical_queue(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_session public.medical_sessions%rowtype;
  v_ticket public.medical_queue_tickets%rowtype;
begin
  select * into v_session from public.medical_sessions where id=p_session_id for update;
  if v_session.id is null or not public.can_operate_medical_center(v_session.center_id,'medical_call') then raise exception 'You cannot call this queue'; end if;
  if v_session.status not in ('planned','open') then raise exception 'This doctor session is not accepting calls'; end if;

  select * into v_ticket
  from public.medical_queue_tickets
  where session_id=v_session.id and status in ('called','in_consultation')
  order by case when status='in_consultation' then 0 else 1 end,called_at desc nulls last
  limit 1 for update;
  if v_ticket.id is not null then return to_jsonb(v_ticket)||jsonb_build_object('already_active',true); end if;

  select * into v_ticket
  from public.medical_queue_tickets
  where session_id=v_session.id and status='waiting'
  order by priority desc,queue_number
  for update skip locked limit 1;
  if v_ticket.id is null then return jsonb_build_object('empty',true); end if;

  update public.medical_sessions set status='open' where id=v_session.id and status='planned';
  update public.medical_queue_tickets set status='called',called_at=now() where id=v_ticket.id returning * into v_ticket;
  insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_ticket.org_id,auth.uid(),'medical.queue.called','medical_queue_ticket',v_ticket.id::text,jsonb_build_object('display_number',v_ticket.display_number,'session_id',v_ticket.session_id));
  return to_jsonb(v_ticket);
end;
$$;

create or replace function public.call_next_medical_queue_by_token(p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_session public.medical_sessions%rowtype;
  v_center public.medical_centers%rowtype;
  v_ticket public.medical_queue_tickets%rowtype;
  v_today date;
begin
  select * into v_session from public.medical_sessions where doctor_portal_token=p_token for update;
  if v_session.id is null then raise exception 'This doctor portal is unavailable'; end if;
  select * into v_center from public.medical_centers where id=v_session.center_id and active=true;
  v_today:=(now() at time zone v_center.timezone)::date;
  if v_session.session_date<>v_today then raise exception 'This portal can call patients only on the session date'; end if;
  if v_session.status not in ('planned','open') then raise exception 'This doctor session is not accepting calls'; end if;

  select * into v_ticket
  from public.medical_queue_tickets
  where session_id=v_session.id and status in ('called','in_consultation')
  order by case when status='in_consultation' then 0 else 1 end,called_at desc nulls last
  limit 1 for update;
  if v_ticket.id is not null then return to_jsonb(v_ticket)||jsonb_build_object('already_active',true); end if;

  select * into v_ticket
  from public.medical_queue_tickets
  where session_id=v_session.id and status='waiting'
  order by priority desc,queue_number
  for update skip locked limit 1;
  if v_ticket.id is null then return jsonb_build_object('empty',true); end if;

  update public.medical_sessions set status='open' where id=v_session.id and status='planned';
  update public.medical_queue_tickets set status='called',called_at=now() where id=v_ticket.id returning * into v_ticket;
  insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_ticket.org_id,null,'medical.queue.called_by_portal','medical_queue_ticket',v_ticket.id::text,jsonb_build_object('display_number',v_ticket.display_number,'session_id',v_ticket.session_id));
  return to_jsonb(v_ticket);
end;
$$;

create or replace function public.advance_medical_queue_by_token(p_token uuid,p_ticket_id uuid,p_status text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_session public.medical_sessions%rowtype;
  v_ticket public.medical_queue_tickets%rowtype;
begin
  if p_status not in ('in_consultation','completed','no_show') then raise exception 'Invalid doctor portal action'; end if;
  select * into v_session from public.medical_sessions where doctor_portal_token=p_token;
  if v_session.id is null then raise exception 'This doctor portal is unavailable'; end if;
  select * into v_ticket from public.medical_queue_tickets where id=p_ticket_id and session_id=v_session.id for update;
  if v_ticket.id is null then raise exception 'Patient number not found in this doctor session'; end if;
  if p_status='in_consultation' and v_ticket.status<>'called' then raise exception 'Call this patient before starting the consultation'; end if;
  if p_status in ('completed','no_show') and v_ticket.status not in ('called','in_consultation') then raise exception 'Only the active patient can be completed or marked no-show'; end if;

  update public.medical_queue_tickets set
    status=p_status,
    consultation_started_at=case when p_status='in_consultation' then coalesce(consultation_started_at,now()) else consultation_started_at end,
    completed_at=case when p_status in ('completed','no_show') then now() else completed_at end
  where id=v_ticket.id returning * into v_ticket;
  return to_jsonb(v_ticket);
end;
$$;

-- Include the session identifier in newly issued ticket payloads so the patient
-- page can subscribe to the corresponding sanitized realtime snapshot.
create or replace function public.issue_medical_queue_number(
  p_slug text,p_patient_name text,p_whatsapp text default null,p_session_id uuid default null,p_source text default 'link'
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_center public.medical_centers%rowtype;v_session public.medical_sessions%rowtype;v_doctor public.medical_doctors%rowtype;v_issued integer;v_number integer;v_ticket public.medical_queue_tickets%rowtype;v_today date;
begin
  select c.* into v_center from public.medical_centers c join public.organizations o on o.id=c.org_id
  where c.public_slug=p_slug and c.active=true and o.business_type='healthcare_clinic' and o.account_status='active';
  if v_center.id is null then raise exception 'This medical queue link is unavailable';end if;
  if nullif(trim(p_patient_name),'') is null then raise exception 'Patient name is required';end if;
  if p_source not in ('qr','link','staff','walk_in') then p_source:='link';end if;
  v_today:=(now() at time zone v_center.timezone)::date;
  if p_session_id is not null then
    select * into v_session from public.medical_sessions where id=p_session_id and center_id=v_center.id and session_date=v_today and status in ('open','planned') for update;
  else
    select s.* into v_session from public.medical_sessions s
    where s.center_id=v_center.id and s.session_date=v_today and s.status in ('open','planned')
      and (select count(*) from public.medical_queue_tickets q where q.session_id=s.id and q.status<>'cancelled')<s.capacity
    order by (select count(*) from public.medical_queue_tickets q where q.session_id=s.id and q.status in ('waiting','called','in_consultation')),s.starts_at
    for update of s skip locked limit 1;
  end if;
  if v_session.id is null then raise exception 'No doctor session is accepting numbers right now';end if;
  select count(*)::integer into v_issued from public.medical_queue_tickets where session_id=v_session.id and status<>'cancelled';
  if v_issued>=v_session.capacity then raise exception 'This doctor session is full';end if;
  select * into v_doctor from public.medical_doctors where id=v_session.doctor_id and active=true;
  select coalesce(max(queue_number),0)+1 into v_number from public.medical_queue_tickets where session_id=v_session.id;
  insert into public.medical_queue_tickets(org_id,center_id,session_id,doctor_id,queue_number,display_number,patient_name,whatsapp,source,issued_by)
  values(v_center.org_id,v_center.id,v_session.id,v_doctor.id,v_number,v_doctor.queue_prefix||'-'||lpad(v_number::text,3,'0'),trim(p_patient_name),nullif(trim(p_whatsapp),''),p_source,auth.uid()) returning * into v_ticket;
  return jsonb_build_object('id',v_ticket.id,'session_id',v_session.id,'token',v_ticket.public_token,'display_number',v_ticket.display_number,'doctor_name',v_doctor.name,'specialty',v_doctor.specialty,'room_label',v_doctor.room_label,'status',v_ticket.status,'issued_at',v_ticket.issued_at,'people_ahead',(select count(*) from public.medical_queue_tickets q where q.session_id=v_session.id and q.status='waiting' and q.queue_number<v_ticket.queue_number));
end $$;

alter table public.medical_public_queue_snapshots enable row level security;
drop policy if exists medical_public_queue_snapshots_read on public.medical_public_queue_snapshots;
create policy medical_public_queue_snapshots_read
on public.medical_public_queue_snapshots for select
to anon,authenticated
using(true);

revoke all on public.medical_public_queue_snapshots from public,anon,authenticated;
grant select on public.medical_public_queue_snapshots to anon,authenticated;

revoke execute on function public.refresh_medical_public_queue_snapshot(uuid) from public,anon,authenticated;
revoke execute on function public.medical_queue_snapshot_ticket_trigger() from public,anon,authenticated;
revoke execute on function public.medical_queue_snapshot_session_trigger() from public,anon,authenticated;
revoke execute on function public.medical_queue_snapshot_doctor_trigger() from public,anon,authenticated;
grant execute on function public.get_public_medical_monitor(text),public.get_medical_doctor_portal(uuid),public.call_next_medical_queue_by_token(uuid),public.advance_medical_queue_by_token(uuid,uuid,text) to anon,authenticated;
grant execute on function public.call_next_medical_queue(uuid) to authenticated;

do $$
begin
  if not exists(
    select 1 from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='medical_public_queue_snapshots'
  ) then
    alter publication supabase_realtime add table public.medical_public_queue_snapshots;
  end if;
end $$;

commit;
