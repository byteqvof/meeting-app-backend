alter table public.activities
add column if not exists auto_completed boolean not null default false;

create index if not exists activities_auto_completed_idx
  on public.activities (auto_completed)
  where auto_completed = true;

create or replace function public.complete_activity(
  p_activity_id uuid
)
returns table (
  activity_id uuid,
  status public.activity_status
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_activity record;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select a.id, a.organizer_id, a.status, a.starts_at
  into v_activity
  from public.activities a
  where a.id = p_activity_id
  for update;

  if not found then
    raise exception 'ACTIVITY_NOT_FOUND';
  end if;

  if v_activity.organizer_id <> v_user_id then
    raise exception 'ACTIVITY_COMPLETION_FORBIDDEN';
  end if;

  if v_activity.status = 'completed' then
    return query select p_activity_id, 'completed'::public.activity_status;
    return;
  end if;

  if v_activity.status <> 'published' then
    raise exception 'ACTIVITY_NOT_COMPLETABLE';
  end if;

  if v_activity.starts_at > now() then
    raise exception 'ACTIVITY_NOT_STARTED';
  end if;

  update public.activities a
  set status = 'completed',
      auto_completed = false,
      updated_at = now()
  where a.id = p_activity_id;

  return query select p_activity_id, 'completed'::public.activity_status;
end;
$$;

grant execute on function public.complete_activity(uuid) to authenticated;

create or replace function public.complete_expired_activities(
  p_grace_interval interval default interval '1 day'
)
returns table (
  activity_id uuid,
  status public.activity_status,
  completed_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  return query
  update public.activities a
  set status = 'completed',
      auto_completed = true,
      updated_at = now()
  where a.status = 'published'
    and coalesce(a.ends_at, a.starts_at + interval '2 hours')
      < now() - greatest(coalesce(p_grace_interval, interval '1 day'), interval '0 seconds')
  returning a.id, a.status, a.updated_at;
end;
$$;

grant execute on function public.complete_expired_activities(interval)
to service_role;

notify pgrst, 'reload schema';
