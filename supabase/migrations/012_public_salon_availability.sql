-- Privacy-safe public availability for the customer booking experience.

create or replace function public.get_public_salon_availability(
  p_slug text,
  p_service_id uuid,
  p_from_date date,
  p_to_date date
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_org public.organizations%rowtype;
  v_settings public.organization_settings%rowtype;
  v_service public.salon_services%rowtype;
  v_opening time;
  v_closing time;
  v_interval integer;
  v_timezone text;
  v_capacity integer;
  v_day date;
  v_minute integer;
  v_start timestamptz;
  v_end timestamptz;
  v_remaining integer;
  v_slots jsonb;
  v_days jsonb := '[]'::jsonb;
begin
  select * into v_org from public.organizations where booking_slug=p_slug and business_type='salon';
  if v_org.id is null then raise exception 'This booking link is unavailable'; end if;
  select * into v_service from public.salon_services where id=p_service_id and org_id=v_org.id and active=true;
  if v_service.id is null then raise exception 'Service is unavailable'; end if;
  if p_from_date<current_date or p_to_date<p_from_date or p_to_date>p_from_date+30 or p_to_date>current_date+180 then
    raise exception 'Choose an availability range within the next 180 days';
  end if;

  select * into v_settings from public.organization_settings where org_id=v_org.id;
  v_opening:=coalesce(v_settings.preferences->>'opening_time','09:00')::time;
  v_closing:=coalesce(v_settings.preferences->>'closing_time','19:00')::time;
  v_interval:=greatest(15,coalesce((v_settings.preferences->>'booking_interval')::integer,30));
  v_timezone:=coalesce(v_settings.timezone,'Asia/Colombo');
  select count(*) into v_capacity from public.employees
  where org_id=v_org.id and employment_status='active' and bookable_for_appointments=true;
  v_capacity:=greatest(v_capacity,1);

  for v_day in select generate_series(p_from_date,p_to_date,interval '1 day')::date loop
    v_slots:='[]'::jsonb;
    v_minute:=0;
    while v_opening+make_interval(mins=>v_minute)<v_closing loop
      v_start:=((v_day+v_opening+make_interval(mins=>v_minute)) at time zone v_timezone);
      v_end:=v_start+make_interval(mins=>v_service.duration_minutes);
      if (v_end at time zone v_timezone)::date<>v_day or (v_end at time zone v_timezone)::time>v_closing or v_start<=now()+interval '30 minutes' then
        v_remaining:=0;
      elsif exists(
        select 1 from public.salon_unavailability u
        where u.org_id=v_org.id and u.staff_id is null
          and tstzrange(u.starts_at,u.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')
      ) then
        v_remaining:=0;
      elsif exists(
        select 1 from public.employees e
        where e.org_id=v_org.id and e.employment_status='active' and e.bookable_for_appointments=true
      ) then
        select count(*) into v_remaining from public.employees e
        where e.org_id=v_org.id and e.employment_status='active' and e.bookable_for_appointments=true
          and not exists(
            select 1 from public.salon_appointments a
            where a.org_id=v_org.id and a.staff_id=e.id and a.status not in ('cancelled','no_show')
              and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')
          )
          and not exists(
            select 1 from public.salon_unavailability u
            where u.org_id=v_org.id and u.staff_id=e.id
              and tstzrange(u.starts_at,u.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')
          );
      elsif exists(
        select 1 from public.salon_appointments a
        where a.org_id=v_org.id and a.staff_id is null and a.status not in ('cancelled','no_show')
          and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')
      ) then
        v_remaining:=0;
      else
        v_remaining:=1;
      end if;
      v_slots:=v_slots||jsonb_build_array(jsonb_build_object(
        'time',to_char(v_start at time zone v_timezone,'HH24:MI'),
        'starts_at',v_start,
        'available',v_remaining>0,
        'remaining',v_remaining,
        'capacity',v_capacity
      ));
      v_minute:=v_minute+v_interval;
    end loop;
    v_days:=v_days||jsonb_build_array(jsonb_build_object(
      'date',to_char(v_day,'YYYY-MM-DD'),
      'available',exists(select 1 from jsonb_array_elements(v_slots) as slot(value) where (value->>'available')::boolean),
      'slots',v_slots
    ));
  end loop;

  return jsonb_build_object(
    'service_id',v_service.id,
    'service_name',v_service.name,
    'duration_minutes',v_service.duration_minutes,
    'capacity',v_capacity,
    'days',v_days
  );
end $$;

grant execute on function public.get_public_salon_availability(text,uuid,date,date) to anon,authenticated;
