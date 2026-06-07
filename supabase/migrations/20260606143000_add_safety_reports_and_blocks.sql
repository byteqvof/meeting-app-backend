create table if not exists public.user_blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_profile_id),
  constraint user_blocks_not_self check (blocker_id <> blocked_profile_id)
);

create index if not exists user_blocks_blocked_profile_idx
  on public.user_blocks (blocked_profile_id);

alter table public.user_blocks enable row level security;

grant select, insert, delete on table public.user_blocks to authenticated;

drop policy if exists "Users can read their own blocks" on public.user_blocks;
create policy "Users can read their own blocks"
on public.user_blocks
for select
to authenticated
using (blocker_id = auth.uid());

drop policy if exists "Users can create their own blocks" on public.user_blocks;
create policy "Users can create their own blocks"
on public.user_blocks
for insert
to authenticated
with check (blocker_id = auth.uid());

drop policy if exists "Users can remove their own blocks" on public.user_blocks;
create policy "Users can remove their own blocks"
on public.user_blocks
for delete
to authenticated
using (blocker_id = auth.uid());

create table if not exists public.content_reports (
  id uuid primary key default extensions.gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  target_type text not null check (
    target_type in ('profile', 'activity', 'chat_message')
  ),
  target_id uuid not null,
  reason text not null check (char_length(btrim(reason)) between 3 and 80),
  details text not null default '' check (char_length(details) <= 1000),
  status text not null default 'open' check (
    status in ('open', 'reviewing', 'resolved', 'dismissed')
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists content_reports_target_idx
  on public.content_reports (target_type, target_id, created_at desc);

create index if not exists content_reports_reporter_idx
  on public.content_reports (reporter_id, created_at desc);

drop trigger if exists content_reports_set_updated_at on public.content_reports;
create trigger content_reports_set_updated_at
before update on public.content_reports
for each row execute function public.set_updated_at();

alter table public.content_reports enable row level security;

grant select, insert on table public.content_reports to authenticated;

drop policy if exists "Users can read their own reports" on public.content_reports;
create policy "Users can read their own reports"
on public.content_reports
for select
to authenticated
using (reporter_id = auth.uid());

drop policy if exists "Users can create their own reports" on public.content_reports;
create policy "Users can create their own reports"
on public.content_reports
for insert
to authenticated
with check (reporter_id = auth.uid());

create or replace function public.set_user_block(
  p_blocked_profile_id uuid,
  p_block boolean default true
)
returns table (
  blocked_profile_id uuid,
  is_blocked boolean
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if p_blocked_profile_id = v_user_id then
    raise exception 'SAFETY_BLOCK_SELF';
  end if;

  if not exists (
    select 1 from public.profiles p where p.id = p_blocked_profile_id
  ) then
    raise exception 'SAFETY_PROFILE_NOT_FOUND';
  end if;

  if coalesce(p_block, true) then
    insert into public.user_blocks (blocker_id, blocked_profile_id)
    values (v_user_id, p_blocked_profile_id)
    on conflict (blocker_id, blocked_profile_id) do nothing;

    return query select p_blocked_profile_id, true;
    return;
  end if;

  delete from public.user_blocks b
  where b.blocker_id = v_user_id
    and b.blocked_profile_id = p_blocked_profile_id;

  return query select p_blocked_profile_id, false;
end;
$$;

grant execute on function public.set_user_block(uuid, boolean)
to authenticated;

create or replace function public.submit_content_report(
  p_target_type text,
  p_target_id uuid,
  p_reason text,
  p_details text default ''
)
returns table (
  id uuid,
  target_type text,
  target_id uuid,
  status text,
  created_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_target_type text := btrim(coalesce(p_target_type, ''));
  v_reason text := btrim(coalesce(p_reason, ''));
  v_details text := btrim(coalesce(p_details, ''));
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if v_target_type not in ('profile', 'activity', 'chat_message') then
    raise exception 'SAFETY_TARGET_INVALID';
  end if;

  if char_length(v_reason) < 3 or char_length(v_reason) > 80 then
    raise exception 'SAFETY_REASON_INVALID';
  end if;

  if char_length(v_details) > 1000 then
    raise exception 'SAFETY_DETAILS_INVALID';
  end if;

  if v_target_type = 'profile' and not exists (
    select 1 from public.profiles p where p.id = p_target_id
  ) then
    raise exception 'SAFETY_TARGET_NOT_FOUND';
  end if;

  if v_target_type = 'activity' and not exists (
    select 1 from public.activities a where a.id = p_target_id
  ) then
    raise exception 'SAFETY_TARGET_NOT_FOUND';
  end if;

  if v_target_type = 'chat_message' and not exists (
    select 1
    from public.activity_chat_messages m
    where m.id = p_target_id
      and public.can_access_activity_chat(m.activity_id, v_user_id)
  ) then
    raise exception 'SAFETY_TARGET_NOT_FOUND';
  end if;

  return query
  insert into public.content_reports (
    reporter_id,
    target_type,
    target_id,
    reason,
    details
  )
  values (
    v_user_id,
    v_target_type,
    p_target_id,
    v_reason,
    v_details
  )
  returning
    content_reports.id,
    content_reports.target_type,
    content_reports.target_id,
    content_reports.status,
    content_reports.created_at;
end;
$$;

grant execute on function public.submit_content_report(
  text,
  uuid,
  text,
  text
) to authenticated;

notify pgrst, 'reload schema';
