-- Production hotel inventory and multi-doctor medical queue modules.
-- Both modules are tenant and branch isolated and use security-definer RPCs for
-- race-sensitive inventory / queue operations.

create table if not exists public.hotel_properties (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  location_id uuid not null references public.salon_locations(id) on delete restrict,
  name text not null,
  public_slug text not null unique,
  description text,
  address text,
  phone text,
  email text,
  check_in_time time not null default '14:00',
  check_out_time time not null default '11:00',
  currency text not null default 'LKR',
  amenities text[] not null default '{}',
  active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(org_id, location_id)
);

create table if not exists public.hotel_room_types (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  property_id uuid not null references public.hotel_properties(id) on delete cascade,
  name text not null,
  code text not null,
  description text,
  room_count integer not null check(room_count > 0),
  max_adults integer not null default 2 check(max_adults > 0),
  max_children integer not null default 0 check(max_children >= 0),
  nightly_rate numeric(14,2) not null default 0 check(nightly_rate >= 0),
  includes text[] not null default '{}',
  images text[] not null default '{}',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(cardinality(images) <= 5),
  unique(property_id, code)
);

create table if not exists public.hotel_bookings (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  property_id uuid not null references public.hotel_properties(id) on delete cascade,
  room_type_id uuid not null references public.hotel_room_types(id) on delete restrict,
  booking_number text not null,
  guest_name text not null,
  whatsapp text not null,
  email text,
  arrival_date date not null,
  departure_date date not null,
  adults integer not null default 1 check(adults > 0),
  children integer not null default 0 check(children >= 0),
  rooms_requested integer not null default 1 check(rooms_requested > 0),
  status text not null default 'pending' check(status in ('pending','confirmed','checked_in','checked_out','cancelled','no_show')),
  source text not null default 'direct',
  external_reservation_id text,
  nightly_rate numeric(14,2) not null default 0,
  nights integer not null check(nights > 0),
  subtotal numeric(14,2) not null default 0,
  tax_amount numeric(14,2) not null default 0,
  total_amount numeric(14,2) not null default 0,
  paid_amount numeric(14,2) not null default 0,
  invoice_number text,
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(departure_date > arrival_date),
  unique(org_id, booking_number)
);

create unique index if not exists hotel_external_reservation_unique
  on public.hotel_bookings(property_id, source, external_reservation_id)
  where external_reservation_id is not null;
create index if not exists hotel_bookings_inventory_idx
  on public.hotel_bookings(room_type_id, arrival_date, departure_date, status);
create index if not exists hotel_room_types_property_idx on public.hotel_room_types(property_id, active);

create table if not exists public.hotel_channel_connections (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  property_id uuid not null references public.hotel_properties(id) on delete cascade,
  provider text not null,
  external_property_id text,
  api_base_url text,
  credential_reference text,
  status text not null default 'draft' check(status in ('draft','connected','paused','error')),
  last_sync_at timestamptz,
  last_sync_status text,
  settings jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(property_id, provider)
);

create table if not exists public.medical_centers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  location_id uuid not null references public.salon_locations(id) on delete restrict,
  name text not null,
  public_slug text not null unique,
  phone text,
  address text,
  timezone text not null default 'Asia/Colombo',
  default_slot_minutes integer not null default 15 check(default_slot_minutes between 5 and 240),
  active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(org_id, location_id)
);

create table if not exists public.medical_doctors (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  center_id uuid not null references public.medical_centers(id) on delete cascade,
  employee_id uuid references public.employees(id) on delete set null,
  name text not null,
  specialty text,
  room_label text,
  queue_prefix text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(center_id, queue_prefix)
);

create table if not exists public.medical_staff_assignments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  center_id uuid not null references public.medical_centers(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  doctor_id uuid references public.medical_doctors(id) on delete cascade,
  assignment_role text not null default 'queue_staff' check(assignment_role in ('queue_staff','doctor','supervisor')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(center_id, employee_id, doctor_id, assignment_role)
);

create table if not exists public.medical_sessions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  center_id uuid not null references public.medical_centers(id) on delete cascade,
  doctor_id uuid not null references public.medical_doctors(id) on delete cascade,
  session_date date not null,
  starts_at time not null,
  ends_at time not null,
  slot_minutes integer not null check(slot_minutes between 5 and 240),
  capacity integer not null check(capacity > 0),
  status text not null default 'planned' check(status in ('planned','open','paused','closed','cancelled')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(ends_at > starts_at),
  unique(doctor_id, session_date, starts_at)
);

create table if not exists public.medical_queue_tickets (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  center_id uuid not null references public.medical_centers(id) on delete cascade,
  session_id uuid not null references public.medical_sessions(id) on delete cascade,
  doctor_id uuid not null references public.medical_doctors(id) on delete restrict,
  queue_number integer not null check(queue_number > 0),
  display_number text not null,
  public_token uuid not null default gen_random_uuid() unique,
  patient_name text not null,
  whatsapp text,
  source text not null default 'link' check(source in ('qr','link','staff','walk_in')),
  priority integer not null default 0 check(priority between 0 and 10),
  status text not null default 'waiting' check(status in ('waiting','called','in_consultation','completed','no_show','cancelled')),
  issued_at timestamptz not null default now(),
  called_at timestamptz,
  consultation_started_at timestamptz,
  completed_at timestamptz,
  issued_by uuid references auth.users(id),
  notes text,
  unique(session_id, queue_number)
);

create index if not exists medical_sessions_day_idx on public.medical_sessions(center_id, session_date, status);
create index if not exists medical_queue_next_idx on public.medical_queue_tickets(session_id, status, priority desc, queue_number);
create index if not exists medical_assignments_employee_idx on public.medical_staff_assignments(employee_id, center_id, active);

create or replace function public.calculate_medical_session_capacity() returns trigger
language plpgsql set search_path=public as $$
begin
  if new.ends_at<=new.starts_at then raise exception 'Session end time must be after its start time';end if;
  new.capacity:=floor((extract(epoch from (new.ends_at-new.starts_at))/60)/new.slot_minutes);
  if new.capacity<1 then raise exception 'The session must contain at least one patient slot';end if;
  return new;
end $$;
drop trigger if exists calculate_medical_session_capacity on public.medical_sessions;
create trigger calculate_medical_session_capacity before insert or update of starts_at,ends_at,slot_minutes
on public.medical_sessions for each row execute function public.calculate_medical_session_capacity();

do $$ declare tab text; begin
  foreach tab in array array['hotel_properties','hotel_room_types','hotel_bookings','hotel_channel_connections','medical_centers','medical_doctors','medical_sessions'] loop
    execute format('drop trigger if exists touch_updated_at on public.%I',tab);
    execute format('create trigger touch_updated_at before update on public.%I for each row execute function public.touch_updated_at()',tab);
  end loop;
end $$;

-- Room images live in Supabase Storage. Public read is intentional because the
-- same images are shown on anonymous booking pages; writes remain tenant scoped.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('hotel-room-images','hotel-room-images',true,5242880,array['image/jpeg','image/png','image/webp','image/gif'])
on conflict(id) do update set public=true,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists hotel_room_images_public_read on storage.objects;
create policy hotel_room_images_public_read on storage.objects for select using(bucket_id='hotel-room-images');
drop policy if exists hotel_room_images_member_insert on storage.objects;
create policy hotel_room_images_member_insert on storage.objects for insert to authenticated
with check(bucket_id='hotel-room-images' and public.is_org_member(((storage.foldername(name))[1])::uuid));
drop policy if exists hotel_room_images_member_update on storage.objects;
create policy hotel_room_images_member_update on storage.objects for update to authenticated
using(bucket_id='hotel-room-images' and public.is_org_member(((storage.foldername(name))[1])::uuid))
with check(bucket_id='hotel-room-images' and public.is_org_member(((storage.foldername(name))[1])::uuid));
drop policy if exists hotel_room_images_manager_delete on storage.objects;
create policy hotel_room_images_manager_delete on storage.objects for delete to authenticated
using(bucket_id='hotel-room-images' and public.can_manage_org(((storage.foldername(name))[1])::uuid));

create or replace function public.hotel_booking_payload(
  p_property_id uuid,p_room_type_id uuid,p_guest_name text,p_whatsapp text,p_email text,
  p_arrival date,p_departure date,p_adults integer,p_children integer,p_rooms integer,
  p_notes text,p_source text,p_external_id text,p_created_by uuid
) returns public.hotel_bookings language plpgsql security definer set search_path=public as $$
declare
  v_property public.hotel_properties%rowtype;
  v_room public.hotel_room_types%rowtype;
  v_reserved integer;
  v_nights integer;
  v_sequence integer;
  v_booking public.hotel_bookings%rowtype;
begin
  select * into v_property from public.hotel_properties where id=p_property_id and active=true;
  if v_property.id is null then raise exception 'This hotel booking link is unavailable';end if;
  select * into v_room from public.hotel_room_types where id=p_room_type_id and property_id=v_property.id and active=true for update;
  if v_room.id is null then raise exception 'Choose an available room type';end if;
  if p_arrival is null or p_departure is null or p_departure<=p_arrival then raise exception 'Departure must be after arrival';end if;
  if p_arrival<current_date then raise exception 'Arrival cannot be in the past';end if;
  if coalesce(p_rooms,0)<1 then raise exception 'Choose at least one room';end if;
  if coalesce(p_adults,0)<1 or p_adults>v_room.max_adults*p_rooms then raise exception 'Adult count exceeds this room capacity';end if;
  if coalesce(p_children,0)>v_room.max_children*p_rooms then raise exception 'Child count exceeds this room capacity';end if;
  select coalesce(sum(rooms_requested),0)::integer into v_reserved
  from public.hotel_bookings
  where room_type_id=v_room.id and status not in ('cancelled','no_show')
    and daterange(arrival_date,departure_date,'[)')&&daterange(p_arrival,p_departure,'[)');
  if v_reserved+p_rooms>v_room.room_count then
    raise exception 'Only % room(s) remain for those dates',greatest(v_room.room_count-v_reserved,0);
  end if;
  v_nights:=p_departure-p_arrival;
  select count(*)+1 into v_sequence from public.hotel_bookings where org_id=v_property.org_id;
  insert into public.hotel_bookings(
    org_id,property_id,room_type_id,booking_number,guest_name,whatsapp,email,arrival_date,departure_date,
    adults,children,rooms_requested,status,source,external_reservation_id,nightly_rate,nights,subtotal,total_amount,
    paid_amount,invoice_number,notes,created_by
  ) values(
    v_property.org_id,v_property.id,v_room.id,'HTL-'||to_char(now(),'YYMM')||'-'||lpad(v_sequence::text,5,'0'),
    trim(p_guest_name),trim(p_whatsapp),nullif(trim(p_email),''),p_arrival,p_departure,p_adults,coalesce(p_children,0),p_rooms,
    case when coalesce(p_source,'direct')='direct' then 'pending' else 'confirmed' end,coalesce(nullif(p_source,''),'direct'),
    nullif(p_external_id,''),v_room.nightly_rate,v_nights,v_room.nightly_rate*v_nights*p_rooms,
    v_room.nightly_rate*v_nights*p_rooms,0,'INV-'||to_char(now(),'YYMM')||'-'||lpad(v_sequence::text,5,'0'),nullif(trim(p_notes),''),p_created_by
  ) returning * into v_booking;
  return v_booking;
end $$;

create or replace function public.create_hotel_booking(
  p_property_id uuid,p_room_type_id uuid,p_guest_name text,p_whatsapp text,p_email text default null,
  p_arrival date default null,p_departure date default null,p_adults integer default 1,p_children integer default 0,
  p_rooms integer default 1,p_notes text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_booking public.hotel_bookings%rowtype;v_property public.hotel_properties%rowtype;
begin
  select * into v_property from public.hotel_properties where id=p_property_id;
  if v_property.id is null or not public.can_access_salon_location(v_property.org_id,v_property.location_id) or not public.has_org_permission(v_property.org_id,'hotel_bookings') then raise exception 'Hotel booking access denied';end if;
  v_booking:=public.hotel_booking_payload(p_property_id,p_room_type_id,p_guest_name,p_whatsapp,p_email,p_arrival,p_departure,p_adults,p_children,p_rooms,p_notes,'direct',null,auth.uid());
  insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_booking.org_id,auth.uid(),'hotel.booking.created','hotel_booking',v_booking.id::text,jsonb_build_object('booking_number',v_booking.booking_number,'guest',v_booking.guest_name));
  return to_jsonb(v_booking);
end $$;

create or replace function public.create_public_hotel_booking(
  p_slug text,p_room_type_id uuid,p_guest_name text,p_whatsapp text,p_email text default null,
  p_arrival date default null,p_departure date default null,p_adults integer default 1,p_children integer default 0,
  p_rooms integer default 1,p_notes text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_property public.hotel_properties%rowtype;v_booking public.hotel_bookings%rowtype;
begin
  select p.* into v_property from public.hotel_properties p join public.organizations o on o.id=p.org_id
  where p.public_slug=p_slug and p.active=true and o.business_type='hotel' and o.account_status='active';
  if v_property.id is null then raise exception 'This hotel booking link is unavailable';end if;
  if nullif(trim(p_guest_name),'') is null or nullif(trim(p_whatsapp),'') is null then raise exception 'Guest name and WhatsApp number are required';end if;
  v_booking:=public.hotel_booking_payload(v_property.id,p_room_type_id,p_guest_name,p_whatsapp,p_email,p_arrival,p_departure,p_adults,p_children,p_rooms,p_notes,'direct',null,null);
  return jsonb_build_object('id',v_booking.id,'booking_number',v_booking.booking_number,'invoice_number',v_booking.invoice_number,'status',v_booking.status,'total_amount',v_booking.total_amount,'arrival_date',v_booking.arrival_date,'departure_date',v_booking.departure_date);
end $$;

create or replace function public.upsert_hotel_channel_booking(
  p_property_id uuid,p_room_type_id uuid,p_provider text,p_external_id text,p_guest_name text,p_whatsapp text,
  p_arrival date,p_departure date,p_adults integer default 1,p_children integer default 0,p_rooms integer default 1,p_notes text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_property public.hotel_properties%rowtype;v_existing public.hotel_bookings%rowtype;v_booking public.hotel_bookings%rowtype;
begin
  select * into v_property from public.hotel_properties where id=p_property_id;
  if v_property.id is null or not public.can_access_salon_location(v_property.org_id,v_property.location_id) or not public.has_org_permission(v_property.org_id,'hotel_manage') then raise exception 'Hotel channel access denied';end if;
  if nullif(trim(p_provider),'') is null or nullif(trim(p_external_id),'') is null then raise exception 'Provider and external reservation ID are required';end if;
  select * into v_existing from public.hotel_bookings where property_id=p_property_id and source=lower(trim(p_provider)) and external_reservation_id=trim(p_external_id);
  if v_existing.id is not null then return to_jsonb(v_existing)||jsonb_build_object('idempotent',true);end if;
  v_booking:=public.hotel_booking_payload(p_property_id,p_room_type_id,p_guest_name,coalesce(nullif(trim(p_whatsapp),''),'Channel guest'),null,p_arrival,p_departure,p_adults,p_children,p_rooms,p_notes,lower(trim(p_provider)),trim(p_external_id),auth.uid());
  insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_booking.org_id,auth.uid(),'hotel.channel_booking.imported','hotel_booking',v_booking.id::text,jsonb_build_object('provider',p_provider,'external_id',p_external_id,'booking_number',v_booking.booking_number));
  return to_jsonb(v_booking)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.get_public_hotel(
  p_slug text,p_arrival date default null,p_departure date default null,p_rooms integer default 1
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_property public.hotel_properties%rowtype;v_rooms jsonb;
begin
  select p.* into v_property from public.hotel_properties p join public.organizations o on o.id=p.org_id
  where p.public_slug=p_slug and p.active=true and o.business_type='hotel' and o.account_status='active';
  if v_property.id is null then raise exception 'This hotel booking link is unavailable';end if;
  if p_arrival is not null and (p_departure is null or p_departure<=p_arrival) then raise exception 'Choose valid arrival and departure dates';end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'name',r.name,'code',r.code,'description',r.description,'room_count',r.room_count,
    'max_adults',r.max_adults,'max_children',r.max_children,'nightly_rate',r.nightly_rate,'includes',r.includes,'images',r.images,
    'available_rooms',case when p_arrival is null then r.room_count else greatest(r.room_count-coalesce((select sum(b.rooms_requested) from public.hotel_bookings b where b.room_type_id=r.id and b.status not in ('cancelled','no_show') and daterange(b.arrival_date,b.departure_date,'[)')&&daterange(p_arrival,p_departure,'[)')),0),0) end
  ) order by r.nightly_rate,r.name),'[]'::jsonb) into v_rooms from public.hotel_room_types r where r.property_id=v_property.id and r.active=true;
  return jsonb_build_object('property',jsonb_build_object('id',v_property.id,'name',v_property.name,'description',v_property.description,'address',v_property.address,'phone',v_property.phone,'email',v_property.email,'check_in_time',v_property.check_in_time,'check_out_time',v_property.check_out_time,'currency',v_property.currency,'amenities',v_property.amenities,'slug',v_property.public_slug),'room_types',v_rooms,'requested_rooms',greatest(coalesce(p_rooms,1),1));
end $$;

create or replace function public.update_hotel_booking_status(p_booking_id uuid,p_status text,p_paid_amount numeric default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_booking public.hotel_bookings%rowtype;v_property public.hotel_properties%rowtype;
begin
  if p_status not in ('pending','confirmed','checked_in','checked_out','cancelled','no_show') then raise exception 'Invalid booking status';end if;
  select * into v_booking from public.hotel_bookings where id=p_booking_id for update;
  select * into v_property from public.hotel_properties where id=v_booking.property_id;
  if v_booking.id is null or not public.can_access_salon_location(v_booking.org_id,v_property.location_id) or not public.has_org_permission(v_booking.org_id,'hotel_bookings') then raise exception 'Booking access denied';end if;
  update public.hotel_bookings set status=p_status,paid_amount=coalesce(p_paid_amount,paid_amount) where id=p_booking_id returning * into v_booking;
  return to_jsonb(v_booking);
end $$;

create or replace function public.can_operate_medical_center(p_center_id uuid,p_permission text default 'medical_view')
returns boolean language sql stable security definer set search_path=public as $$
  select exists(
    select 1 from public.medical_centers c
    where c.id=p_center_id and public.can_access_salon_location(c.org_id,c.location_id)
      and public.has_org_permission(c.org_id,p_permission)
  );
$$;

create or replace function public.get_public_medical_center(p_slug text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_center public.medical_centers%rowtype;v_sessions jsonb;v_today date;
begin
  select c.* into v_center from public.medical_centers c join public.organizations o on o.id=c.org_id
  where c.public_slug=p_slug and c.active=true and o.business_type='healthcare_clinic' and o.account_status='active';
  if v_center.id is null then raise exception 'This medical queue link is unavailable';end if;
  v_today:=(now() at time zone v_center.timezone)::date;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',s.id,'doctor_id',d.id,'doctor_name',d.name,'specialty',d.specialty,'room_label',d.room_label,
    'queue_prefix',d.queue_prefix,'starts_at',s.starts_at,'ends_at',s.ends_at,'slot_minutes',s.slot_minutes,'capacity',s.capacity,'status',s.status,
    'issued',(select count(*) from public.medical_queue_tickets q where q.session_id=s.id and q.status<>'cancelled'),
    'waiting',(select count(*) from public.medical_queue_tickets q where q.session_id=s.id and q.status='waiting'),
    'currently_serving',(select q.display_number from public.medical_queue_tickets q where q.session_id=s.id and q.status in ('called','in_consultation') order by q.called_at desc nulls last limit 1)
  ) order by s.starts_at,d.name),'[]'::jsonb) into v_sessions
  from public.medical_sessions s join public.medical_doctors d on d.id=s.doctor_id
  where s.center_id=v_center.id and s.session_date=v_today and s.status in ('open','planned') and d.active=true;
  return jsonb_build_object('center',jsonb_build_object('id',v_center.id,'name',v_center.name,'phone',v_center.phone,'address',v_center.address,'slug',v_center.public_slug,'default_slot_minutes',v_center.default_slot_minutes),'sessions',v_sessions,'date',v_today);
end $$;

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
  return jsonb_build_object('id',v_ticket.id,'token',v_ticket.public_token,'display_number',v_ticket.display_number,'doctor_name',v_doctor.name,'specialty',v_doctor.specialty,'room_label',v_doctor.room_label,'status',v_ticket.status,'issued_at',v_ticket.issued_at,'people_ahead',(select count(*) from public.medical_queue_tickets q where q.session_id=v_session.id and q.status='waiting' and q.queue_number<v_ticket.queue_number));
end $$;

create or replace function public.call_next_medical_queue(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_session public.medical_sessions%rowtype;v_ticket public.medical_queue_tickets%rowtype;
begin
  select * into v_session from public.medical_sessions where id=p_session_id for update;
  if v_session.id is null or not public.can_operate_medical_center(v_session.center_id,'medical_call') then raise exception 'You cannot call this queue';end if;
  select * into v_ticket from public.medical_queue_tickets where session_id=v_session.id and status='waiting' order by priority desc,queue_number for update skip locked limit 1;
  if v_ticket.id is null then return jsonb_build_object('empty',true);end if;
  update public.medical_queue_tickets set status='called',called_at=now() where id=v_ticket.id returning * into v_ticket;
  insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_ticket.org_id,auth.uid(),'medical.queue.called','medical_queue_ticket',v_ticket.id::text,jsonb_build_object('display_number',v_ticket.display_number,'session_id',v_ticket.session_id));
  return to_jsonb(v_ticket);
end $$;

create or replace function public.advance_medical_queue(p_ticket_id uuid,p_status text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_ticket public.medical_queue_tickets%rowtype;
begin
  if p_status not in ('waiting','called','in_consultation','completed','no_show','cancelled') then raise exception 'Invalid queue status';end if;
  select * into v_ticket from public.medical_queue_tickets where id=p_ticket_id for update;
  if v_ticket.id is null or not public.can_operate_medical_center(v_ticket.center_id,case when p_status in ('called','in_consultation','completed','no_show') then 'medical_call' else 'medical_issue' end) then raise exception 'Queue access denied';end if;
  update public.medical_queue_tickets set status=p_status,
    called_at=case when p_status='called' then coalesce(called_at,now()) else called_at end,
    consultation_started_at=case when p_status='in_consultation' then coalesce(consultation_started_at,now()) else consultation_started_at end,
    completed_at=case when p_status in ('completed','no_show','cancelled') then now() else null end
  where id=p_ticket_id returning * into v_ticket;
  return to_jsonb(v_ticket);
end $$;

create or replace function public.get_medical_ticket_status(p_token uuid)
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object('display_number',q.display_number,'status',q.status,'doctor_name',d.name,'specialty',d.specialty,'room_label',d.room_label,'issued_at',q.issued_at,'called_at',q.called_at,
    'people_ahead',(select count(*) from public.medical_queue_tickets a where a.session_id=q.session_id and a.status='waiting' and a.queue_number<q.queue_number))
  from public.medical_queue_tickets q join public.medical_doctors d on d.id=q.doctor_id where q.public_token=p_token;
$$;

alter table public.hotel_properties enable row level security;
alter table public.hotel_room_types enable row level security;
alter table public.hotel_bookings enable row level security;
alter table public.hotel_channel_connections enable row level security;
alter table public.medical_centers enable row level security;
alter table public.medical_doctors enable row level security;
alter table public.medical_staff_assignments enable row level security;
alter table public.medical_sessions enable row level security;
alter table public.medical_queue_tickets enable row level security;

drop policy if exists hotel_properties_select on public.hotel_properties;
create policy hotel_properties_select on public.hotel_properties for select to authenticated using(public.can_access_salon_location(org_id,location_id) and public.has_org_permission(org_id,'hotel_view'));
drop policy if exists hotel_properties_write on public.hotel_properties;
create policy hotel_properties_write on public.hotel_properties for all to authenticated using(public.can_access_salon_location(org_id,location_id) and public.has_org_permission(org_id,'hotel_manage')) with check(public.can_access_salon_location(org_id,location_id) and public.has_org_permission(org_id,'hotel_manage'));
drop policy if exists hotel_room_types_select on public.hotel_room_types;
create policy hotel_room_types_select on public.hotel_room_types for select to authenticated using(exists(select 1 from public.hotel_properties p where p.id=property_id and public.can_access_salon_location(p.org_id,p.location_id) and public.has_org_permission(p.org_id,'hotel_view')));
drop policy if exists hotel_room_types_write on public.hotel_room_types;
create policy hotel_room_types_write on public.hotel_room_types for all to authenticated using(exists(select 1 from public.hotel_properties p where p.id=property_id and public.can_access_salon_location(p.org_id,p.location_id) and public.has_org_permission(p.org_id,'hotel_manage'))) with check(exists(select 1 from public.hotel_properties p where p.id=property_id and public.can_access_salon_location(p.org_id,p.location_id) and public.has_org_permission(p.org_id,'hotel_manage')));
drop policy if exists hotel_bookings_select on public.hotel_bookings;
create policy hotel_bookings_select on public.hotel_bookings for select to authenticated using(exists(select 1 from public.hotel_properties p where p.id=property_id and public.can_access_salon_location(p.org_id,p.location_id) and public.has_org_permission(p.org_id,'hotel_view')));
drop policy if exists hotel_channels_all on public.hotel_channel_connections;
create policy hotel_channels_all on public.hotel_channel_connections for all to authenticated using(exists(select 1 from public.hotel_properties p where p.id=property_id and public.can_access_salon_location(p.org_id,p.location_id) and public.has_org_permission(p.org_id,'hotel_manage'))) with check(exists(select 1 from public.hotel_properties p where p.id=property_id and public.can_access_salon_location(p.org_id,p.location_id) and public.has_org_permission(p.org_id,'hotel_manage')));

drop policy if exists medical_centers_select on public.medical_centers;
create policy medical_centers_select on public.medical_centers for select to authenticated using(public.can_access_salon_location(org_id,location_id) and public.has_org_permission(org_id,'medical_view'));
drop policy if exists medical_centers_write on public.medical_centers;
create policy medical_centers_write on public.medical_centers for all to authenticated using(public.can_access_salon_location(org_id,location_id) and public.has_org_permission(org_id,'medical_manage')) with check(public.can_access_salon_location(org_id,location_id) and public.has_org_permission(org_id,'medical_manage'));
drop policy if exists medical_doctors_select on public.medical_doctors;
create policy medical_doctors_select on public.medical_doctors for select to authenticated using(public.can_operate_medical_center(center_id,'medical_view'));
drop policy if exists medical_doctors_write on public.medical_doctors;
create policy medical_doctors_write on public.medical_doctors for all to authenticated using(public.can_operate_medical_center(center_id,'medical_manage')) with check(public.can_operate_medical_center(center_id,'medical_manage'));
drop policy if exists medical_staff_assignments_all on public.medical_staff_assignments;
create policy medical_staff_assignments_all on public.medical_staff_assignments for all to authenticated using(public.can_operate_medical_center(center_id,'medical_manage')) with check(public.can_operate_medical_center(center_id,'medical_manage'));
drop policy if exists medical_sessions_select on public.medical_sessions;
create policy medical_sessions_select on public.medical_sessions for select to authenticated using(public.can_operate_medical_center(center_id,'medical_view'));
drop policy if exists medical_sessions_write on public.medical_sessions;
create policy medical_sessions_write on public.medical_sessions for all to authenticated using(public.can_operate_medical_center(center_id,'medical_manage')) with check(public.can_operate_medical_center(center_id,'medical_manage'));
drop policy if exists medical_queue_select on public.medical_queue_tickets;
create policy medical_queue_select on public.medical_queue_tickets for select to authenticated using(public.can_operate_medical_center(center_id,'medical_view'));

grant select,insert,update,delete on public.hotel_properties,public.hotel_room_types,public.hotel_channel_connections,public.medical_centers,public.medical_doctors,public.medical_staff_assignments,public.medical_sessions to authenticated;
grant select on public.hotel_bookings,public.medical_queue_tickets to authenticated;
revoke execute on function public.hotel_booking_payload(uuid,uuid,text,text,text,date,date,integer,integer,integer,text,text,text,uuid) from public,anon,authenticated;
grant execute on function public.create_hotel_booking(uuid,uuid,text,text,text,date,date,integer,integer,integer,text),public.upsert_hotel_channel_booking(uuid,uuid,text,text,text,text,date,date,integer,integer,integer,text),public.update_hotel_booking_status(uuid,text,numeric),public.can_operate_medical_center(uuid,text),public.call_next_medical_queue(uuid),public.advance_medical_queue(uuid,text) to authenticated;
grant execute on function public.get_public_hotel(text,date,date,integer),public.create_public_hotel_booking(text,uuid,text,text,text,date,date,integer,integer,integer,text),public.get_public_medical_center(text),public.issue_medical_queue_number(text,text,text,uuid,text),public.get_medical_ticket_status(uuid) to anon,authenticated;
