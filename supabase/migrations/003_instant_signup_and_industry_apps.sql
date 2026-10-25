create or replace function public.confirm_password_signup(account_email text, account_password text)
returns boolean
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  target_user auth.users%rowtype;
begin
  select * into target_user
  from auth.users
  where lower(email) = lower(trim(account_email))
  order by created_at desc
  limit 1;

  if target_user.id is null then return false; end if;
  if target_user.email_confirmed_at is not null then return true; end if;
  if target_user.created_at < now() - interval '30 minutes' then return false; end if;
  if target_user.encrypted_password is null or crypt(account_password, target_user.encrypted_password) <> target_user.encrypted_password then return false; end if;

  update auth.users
  set email_confirmed_at = now(), confirmed_at = now(), updated_at = now()
  where id = target_user.id and email_confirmed_at is null;
  return true;
end;
$$;
revoke all on function public.confirm_password_signup(text,text) from public;
grant execute on function public.confirm_password_signup(text,text) to anon, authenticated;

create table if not exists public.module_records (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  module_key text not null,
  record_type text not null default 'record',
  title text not null,
  status text not null default 'new',
  reference text,
  assigned_to uuid references auth.users(id) on delete set null,
  amount numeric(14,2),
  due_date date,
  data jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists module_records_org_id_idx on public.module_records(org_id);
create index if not exists module_records_module_key_idx on public.module_records(org_id,module_key);
alter table public.module_records enable row level security;
drop policy if exists module_records_select on public.module_records;
create policy module_records_select on public.module_records for select to authenticated using (public.is_org_member(org_id));
drop policy if exists module_records_insert on public.module_records;
create policy module_records_insert on public.module_records for insert to authenticated with check (public.is_org_member(org_id));
drop policy if exists module_records_update on public.module_records;
create policy module_records_update on public.module_records for update to authenticated using (public.is_org_member(org_id)) with check (public.is_org_member(org_id));
drop policy if exists module_records_delete on public.module_records;
create policy module_records_delete on public.module_records for delete to authenticated using (public.can_manage_org(org_id));
drop trigger if exists touch_updated_at on public.module_records;
create trigger touch_updated_at before update on public.module_records for each row execute function public.touch_updated_at();
grant select,insert,update,delete on public.module_records to authenticated;
