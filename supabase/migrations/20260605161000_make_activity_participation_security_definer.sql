create or replace function public.set_activity_participation(
  p_activity_id uuid,
  p_join boolean default true
)
returns table (
  activity_id uuid,
  is_joined boolean,
  participants jsonb,
  participants_count integer,
  available_spots integer
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_activity record;
  v_joined_count integer;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (select 1 from public.profiles where id = v_user_id) then
    raise exception 'PROFILE_REQUIRED';
  end if;

  select id, organizer_id, max_participants, status, starts_at
  into v_activity
  from public.activities
  where id = p_activity_id
  for update;

  if not found then
    raise exception 'ACTIVITY_NOT_FOUND';
  end if;

  if v_activity.organizer_id = v_user_id then
    raise exception 'ACTIVITY_OWNER_CANNOT_JOIN';
  end if;

  if v_activity.status <> 'published' or v_activity.starts_at < now() then
    raise exception 'ACTIVITY_UNAVAILABLE';
  end if;

  if coalesce(p_join, true) then
    select count(*)::integer
    into v_joined_count
    from public.activity_participants ap
    where ap.activity_id = p_activity_id
      and ap.status = 'joined';

    if not exists (
        select 1
        from public.activity_participants ap
        where ap.activity_id = p_activity_id
          and ap.profile_id = v_user_id
          and ap.status = 'joined'
      )
      and v_activity.max_participants is not null
      and v_joined_count >= v_activity.max_participants
    then
      raise exception 'ACTIVITY_FULL';
    end if;

    insert into public.activity_participants as ap (
      activity_id,
      profile_id,
      status,
      joined_at
    )
    values (
      p_activity_id,
      v_user_id,
      'joined',
      now()
    )
    on conflict (activity_id, profile_id)
    do update set
      status = 'joined',
      joined_at = case
        when ap.status = 'joined'
          then ap.joined_at
        else now()
      end,
      updated_at = now();
  else
    update public.activity_participants ap
    set status = 'cancelled',
        updated_at = now()
    where ap.activity_id = p_activity_id
      and ap.profile_id = v_user_id;
  end if;

  update public.profiles
  set activities_joined_count = (
    select count(*)::integer
    from public.activity_participants ap
    where ap.profile_id = v_user_id
      and ap.status = 'joined'
  )
  where id = v_user_id;

  return query
  select
    p_activity_id,
    snapshot.is_joined,
    snapshot.participants,
    snapshot.participants_count,
    snapshot.available_spots
  from public.activity_participation_snapshot(p_activity_id) snapshot;
end;
$$;

grant execute on function public.set_activity_participation(uuid, boolean)
to authenticated;

notify pgrst, 'reload schema';
