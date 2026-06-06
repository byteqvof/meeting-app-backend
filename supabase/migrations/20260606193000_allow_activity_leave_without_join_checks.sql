create or replace function public.set_activity_participation(
  p_activity_id uuid,
  p_join boolean default true
)
returns table (
  activity_id uuid,
  is_joined boolean,
  participants jsonb,
  participants_count integer,
  available_spots integer,
  participation_status text
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
  v_trust record;
  v_profile record;
  v_next_status public.activity_participant_status := 'joined'::public.activity_participant_status;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select
    a.id,
    a.organizer_id,
    a.max_participants,
    a.status,
    a.starts_at,
    a.group_type,
    a.min_reputation_level,
    a.requires_identity_verified,
    a.target_age_bands,
    a.target_genders
  into v_activity
  from public.activities a
  where a.id = p_activity_id
  for update;

  if not found then
    raise exception 'ACTIVITY_NOT_FOUND';
  end if;

  if not coalesce(p_join, true) then
    update public.activity_participants ap
    set status = 'cancelled',
        updated_at = now()
    where ap.activity_id = p_activity_id
      and ap.profile_id = v_user_id;

    update public.profiles p
    set activities_joined_count = (
      select count(*)::integer
      from public.activity_participants ap
      where ap.profile_id = v_user_id
        and ap.status = 'joined'
    )
    where p.id = v_user_id;

    if exists (select 1 from public.profiles p where p.id = v_user_id) then
      perform public.recalculate_profile_trust(v_user_id);
    end if;

    return query
    select
      p_activity_id,
      snapshot.is_joined,
      snapshot.participants,
      snapshot.participants_count,
      snapshot.available_spots,
      coalesce((
        select ap.status::text
        from public.activity_participants ap
        where ap.activity_id = p_activity_id
          and ap.profile_id = v_user_id
      ), 'cancelled') as participation_status
    from public.activity_participation_snapshot(p_activity_id) snapshot;

    return;
  end if;

  select p.age_band, p.gender
  into v_profile
  from public.profiles p
  where p.id = v_user_id;

  if not found then
    raise exception 'PROFILE_REQUIRED';
  end if;

  select *
  into v_trust
  from public.profile_trust t
  where t.profile_id = v_user_id;

  if not coalesce(v_trust.phone_verified, false) then
    raise exception 'PROFILE_PHONE_REQUIRED';
  end if;

  if v_activity.organizer_id = v_user_id then
    raise exception 'ACTIVITY_OWNER_CANNOT_JOIN';
  end if;

  if public.has_user_block(v_user_id, v_activity.organizer_id) then
    raise exception 'ACTIVITY_BLOCKED';
  end if;

  if v_activity.status <> 'published' or v_activity.starts_at < now() then
    raise exception 'ACTIVITY_UNAVAILABLE';
  end if;

  if v_activity.group_type = 'closed' then
    raise exception 'ACTIVITY_CLOSED';
  end if;

  if v_activity.requires_identity_verified
    and coalesce(v_trust.identity_status, 'unverified') <> 'verified'
  then
    raise exception 'ACTIVITY_IDENTITY_REQUIRED';
  end if;

  if public.reputation_rank(coalesce(v_trust.reputation_level, 'new_member'))
    < public.reputation_rank(coalesce(v_activity.min_reputation_level, 'new_member'))
  then
    raise exception 'ACTIVITY_REPUTATION_TOO_LOW';
  end if;

  if cardinality(coalesce(v_activity.target_age_bands, '{}'::text[])) > 0
    and (
      v_profile.age_band is null
      or not (v_profile.age_band = any(v_activity.target_age_bands))
    )
  then
    raise exception 'ACTIVITY_TARGET_MISMATCH';
  end if;

  if cardinality(coalesce(v_activity.target_genders, '{}'::text[])) > 0
    and (
      v_profile.gender is null
      or not (v_profile.gender = any(v_activity.target_genders))
    )
  then
    raise exception 'ACTIVITY_TARGET_MISMATCH';
  end if;

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

  v_next_status := case
    when v_activity.group_type = 'approval' then 'pending'::public.activity_participant_status
    else 'joined'::public.activity_participant_status
  end;

  insert into public.activity_participants as ap (
    activity_id,
    profile_id,
    status,
    joined_at
  )
  values (
    p_activity_id,
    v_user_id,
    v_next_status,
    now()
  )
  on conflict on constraint activity_participants_pkey
  do update set
    status = v_next_status,
    joined_at = case
      when ap.status = v_next_status then ap.joined_at
      else now()
    end,
    updated_at = now();

  update public.profiles p
  set activities_joined_count = (
    select count(*)::integer
    from public.activity_participants ap
    where ap.profile_id = v_user_id
      and ap.status = 'joined'
  )
  where p.id = v_user_id;

  perform public.recalculate_profile_trust(v_user_id);

  return query
  select
    p_activity_id,
    snapshot.is_joined,
    snapshot.participants,
    snapshot.participants_count,
    snapshot.available_spots,
    coalesce((
      select ap.status::text
      from public.activity_participants ap
      where ap.activity_id = p_activity_id
        and ap.profile_id = v_user_id
    ), 'cancelled') as participation_status
  from public.activity_participation_snapshot(p_activity_id) snapshot;
end;
$$;

grant execute on function public.set_activity_participation(uuid, boolean)
to authenticated;

notify pgrst, 'reload schema';
