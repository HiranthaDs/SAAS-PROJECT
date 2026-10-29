-- Platform messages sent by the system administrator to customer workspaces.
create table if not exists public.system_notifications(
 id uuid primary key default gen_random_uuid(),
 org_id uuid not null references public.organizations(id) on delete cascade,
 title text not null,
 body text not null,
 severity text not null default 'info' check(severity in ('info','success','warning','critical')),
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 expires_at timestamptz
);
create index if not exists system_notifications_org_created_idx on public.system_notifications(org_id,created_at desc);

create table if not exists public.system_notification_reads(
 notification_id uuid not null references public.system_notifications(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 read_at timestamptz not null default now(),
 primary key(notification_id,user_id)
);

alter table public.system_notifications enable row level security;
alter table public.system_notification_reads enable row level security;
drop policy if exists system_notifications_select on public.system_notifications;
create policy system_notifications_select on public.system_notifications for select to authenticated using(public.is_system_admin() or public.is_org_member(org_id));
drop policy if exists system_notifications_insert on public.system_notifications;
create policy system_notifications_insert on public.system_notifications for insert to authenticated with check(public.is_system_admin());
drop policy if exists system_notifications_update on public.system_notifications;
create policy system_notifications_update on public.system_notifications for update to authenticated using(public.is_system_admin()) with check(public.is_system_admin());
drop policy if exists system_notifications_delete on public.system_notifications;
create policy system_notifications_delete on public.system_notifications for delete to authenticated using(public.is_system_admin());
drop policy if exists system_notification_reads_select on public.system_notification_reads;
create policy system_notification_reads_select on public.system_notification_reads for select to authenticated using(user_id=auth.uid() or public.is_system_admin());
drop policy if exists system_notification_reads_insert on public.system_notification_reads;
create policy system_notification_reads_insert on public.system_notification_reads for insert to authenticated with check(user_id=auth.uid());
drop policy if exists system_notification_reads_update on public.system_notification_reads;
create policy system_notification_reads_update on public.system_notification_reads for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());

create or replace function public.send_system_notification(p_org_id uuid,p_title text,p_body text,p_severity text default 'info',p_expires_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_notice public.system_notifications%rowtype;
begin
 if not public.is_system_admin() then raise exception 'System administrator access required';end if;
 if not exists(select 1 from public.organizations where id=p_org_id) then raise exception 'Workspace not found';end if;
 if nullif(trim(p_title),'') is null or nullif(trim(p_body),'') is null then raise exception 'Title and message are required';end if;
 if p_severity not in ('info','success','warning','critical') then raise exception 'Invalid message priority';end if;
 insert into public.system_notifications(org_id,title,body,severity,created_by,expires_at)
 values(p_org_id,trim(p_title),trim(p_body),p_severity,auth.uid(),p_expires_at) returning * into v_notice;
 insert into public.activity_log(org_id,actor_id,action,entity_type,entity_id,metadata)
 values(p_org_id,auth.uid(),'system.notification.sent','system_notification',v_notice.id::text,jsonb_build_object('title',v_notice.title,'severity',v_notice.severity));
 return to_jsonb(v_notice);
end $$;

create or replace function public.get_my_system_notifications()
returns jsonb language sql stable security definer set search_path=public as $$
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',n.id,'org_id',n.org_id,'title',n.title,'body',n.body,'severity',n.severity,'created_at',n.created_at,'expires_at',n.expires_at,
  'read',exists(select 1 from public.system_notification_reads r where r.notification_id=n.id and r.user_id=auth.uid())
 ) order by n.created_at desc),'[]'::jsonb)
 from public.system_notifications n
 where public.is_org_member(n.org_id) and (n.expires_at is null or n.expires_at>now())
$$;

create or replace function public.mark_system_notification_read(p_notification_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from public.system_notifications n where n.id=p_notification_id and public.is_org_member(n.org_id)) then raise exception 'Notification not found';end if;
 insert into public.system_notification_reads(notification_id,user_id) values(p_notification_id,auth.uid()) on conflict(notification_id,user_id) do update set read_at=now();return true;
end $$;

grant select,insert,update,delete on public.system_notifications to authenticated;
grant select,insert,update on public.system_notification_reads to authenticated;
grant execute on function public.send_system_notification(uuid,text,text,text,timestamptz) to authenticated;
grant execute on function public.get_my_system_notifications() to authenticated;
grant execute on function public.mark_system_notification_read(uuid) to authenticated;
