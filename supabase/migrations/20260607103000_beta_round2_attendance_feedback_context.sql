alter table public.activity_attendance
drop constraint if exists activity_attendance_status_check;

alter table public.activity_attendance
add constraint activity_attendance_status_check
check (status in ('present', 'absent', 'unknown'));

create or replace function public.activity_profile_context_json(
  p_activity_id uuid,
  p_profile_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with base as (
    select public.profile_json(p_profile_id) as profile
  ),
  attendance as (
    select aa.status, aa.marked_at
    from public.activity_attendance aa
    where aa.activity_id = p_activity_id
      and aa.profile_id = p_profile_id
    limit 1
  ),
  feedback as (
    select af.id, af.rating, af.comment, af.created_at
    from public.activity_feedback af
    where af.activity_id = p_activity_id
      and af.reviewer_id = auth.uid()
      and af.target_profile_id = p_profile_id
    limit 1
  )
  select case
    when base.profile is null then null::jsonb
    else base.profile || jsonb_build_object(
      'attendance_status', attendance.status,
      'attendance_marked_at', attendance.marked_at,
      'feedback_submitted', feedback.id is not null,
      'feedback_rating', feedback.rating,
      'feedback_comment', feedback.comment,
      'feedback_created_at', feedback.created_at
    )
  end
  from base
  left join attendance on true
  left join feedback on true;
$$;

grant execute on function public.activity_profile_context_json(uuid, uuid)
to authenticated;

create or replace function public.activity_participation_snapshot(
  p_activity_id uuid
)
returns table (
  participants jsonb,
  participants_count integer,
  is_joined boolean,
  available_spots integer
)
language sql
stable
security definer
set search_path = public
as $$
  with activity as (
    select id, max_participants
    from public.activities
    where id = p_activity_id
  ),
  joined_participants as (
    select ap.profile_id, ap.joined_at
    from public.activity_participants ap
    where ap.activity_id = p_activity_id
      and ap.status = 'joined'
      and not public.has_user_block(auth.uid(), ap.profile_id)
  ),
  counts as (
    select count(*)::integer as participants_count
    from public.activity_participants ap
    where ap.activity_id = p_activity_id
      and ap.status = 'joined'
  )
  select
    coalesce((
      select jsonb_agg(profile.context order by jp.joined_at)
      from joined_participants jp
      left join lateral (
        select public.activity_profile_context_json(
          p_activity_id,
          jp.profile_id
        ) as context
      ) profile on true
      where jp.profile_id <> auth.uid()
        and profile.context is not null
    ), '[]'::jsonb) as participants,
    counts.participants_count,
    exists (
      select 1
      from public.activity_participants ap
      where ap.activity_id = p_activity_id
        and ap.profile_id = auth.uid()
        and ap.status = 'joined'
    ) as is_joined,
    case
      when activity.max_participants is null then 0
      else greatest(activity.max_participants - counts.participants_count, 0)
    end::integer as available_spots
  from activity
  cross join counts;
$$;

grant execute on function public.activity_participation_snapshot(uuid)
to authenticated;

create or replace function public.mark_activity_attendance(
  p_activity_id uuid,
  p_profile_id uuid,
  p_status text
)
returns table (
  activity_id uuid,
  profile_id uuid,
  status text,
  marked_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_status text := btrim(coalesce(p_status, ''));
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if v_status not in ('present', 'absent', 'unknown') then
    raise exception 'ATTENDANCE_STATUS_INVALID';
  end if;

  if not exists (
    select 1
    from public.activities a
    where a.id = p_activity_id
      and a.organizer_id = v_user_id
      and a.status = 'completed'
  ) then
    raise exception 'ATTENDANCE_FORBIDDEN';
  end if;

  if not exists (
    select 1
    from public.activities a
    where a.id = p_activity_id
      and exists (
        select 1
        from public.activity_participants ap
        where ap.activity_id = a.id
          and ap.profile_id = p_profile_id
          and ap.status = 'joined'
      )
  ) then
    raise exception 'ATTENDANCE_TARGET_INVALID';
  end if;

  return query
  with attendance as (
    insert into public.activity_attendance (
      activity_id,
      profile_id,
      status,
      marked_by,
      marked_at
    )
    values (
      p_activity_id,
      p_profile_id,
      v_status,
      v_user_id,
      now()
    )
    on conflict on constraint activity_attendance_pkey
    do update set
      status = excluded.status,
      marked_by = excluded.marked_by,
      marked_at = now(),
      updated_at = now()
    returning *
  ),
  recalculated as (
    select * from public.recalculate_profile_trust(p_profile_id)
  )
  select
    attendance.activity_id,
    attendance.profile_id,
    attendance.status,
    attendance.marked_at
  from attendance;
end;
$$;

grant execute on function public.mark_activity_attendance(uuid, uuid, text)
to authenticated;

create or replace function public.list_completed_activities_for_user(
  p_user_id uuid default null,
  p_limit integer default 100
)
returns table (
  id uuid,
  category_id uuid,
  organizer_id uuid,
  title text,
  description text,
  latitude double precision,
  longitude double precision,
  address_line text,
  city text,
  country_code text,
  starts_at timestamptz,
  ends_at timestamptz,
  max_participants integer,
  price_cents integer,
  currency text,
  image_url text,
  status public.activity_status,
  metadata jsonb,
  created_at timestamptz,
  updated_at timestamptz,
  distance_km double precision,
  category jsonb,
  host jsonb,
  participants jsonb,
  participants_count integer,
  is_joined boolean,
  available_spots integer
)
language sql
stable
security definer
set search_path = public
as $$
  with target_user as (
    select coalesce(p_user_id, auth.uid()) as id
  )
  select
    a.id,
    a.category_id,
    a.organizer_id,
    a.title,
    a.description,
    a.latitude,
    a.longitude,
    a.address_line,
    a.city,
    a.country_code,
    a.starts_at,
    a.ends_at,
    a.max_participants,
    a.price_cents,
    a.currency,
    a.image_url,
    a.status,
    a.metadata,
    a.created_at,
    a.updated_at,
    null::double precision as distance_km,
    jsonb_build_object(
      'id', c.id,
      'slug', c.slug,
      'title', c.title,
      'description', c.description,
      'background_color', c.background_color,
      'foreground_color', c.foreground_color,
      'icon_key', c.icon_key
    ) as category,
    public.activity_profile_context_json(a.id, a.organizer_id) as host,
    coalesce(participation.participants, '[]'::jsonb) as participants,
    coalesce(participation.participants_count, 0) as participants_count,
    coalesce(participation.is_joined, false) as is_joined,
    coalesce(participation.available_spots, 0) as available_spots
  from target_user
  join public.activities a
    on a.status = 'completed'
   and (
      a.organizer_id = target_user.id
      or exists (
        select 1
        from public.activity_participants ap
        where ap.activity_id = a.id
          and ap.profile_id = target_user.id
          and ap.status = 'joined'
      )
   )
  join public.activity_categories c on c.id = a.category_id
  left join lateral public.activity_participation_snapshot(a.id) participation on true
  where target_user.id = auth.uid()
  order by a.starts_at desc, a.updated_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 200);
$$;

grant execute on function public.list_completed_activities_for_user(uuid, integer)
to authenticated;

create or replace function public.get_activity_detail(
  p_activity_id uuid
)
returns table (
  id uuid,
  category_id uuid,
  organizer_id uuid,
  title text,
  description text,
  latitude double precision,
  longitude double precision,
  address_line text,
  city text,
  country_code text,
  starts_at timestamptz,
  ends_at timestamptz,
  max_participants integer,
  price_cents integer,
  currency text,
  image_url text,
  status public.activity_status,
  metadata jsonb,
  created_at timestamptz,
  updated_at timestamptz,
  distance_km double precision,
  category jsonb,
  host jsonb,
  participants jsonb,
  participants_count integer,
  is_joined boolean,
  available_spots integer,
  group_type text,
  min_reputation_level text,
  requires_identity_verified boolean,
  is_private_location boolean,
  target_age_bands text[],
  target_genders text[]
)
language sql
stable
security definer
set search_path = public
as $$
  select
    a.id,
    a.category_id,
    a.organizer_id,
    a.title,
    a.description,
    a.latitude,
    a.longitude,
    a.address_line,
    a.city,
    a.country_code,
    a.starts_at,
    a.ends_at,
    a.max_participants,
    a.price_cents,
    a.currency,
    a.image_url,
    a.status,
    a.metadata,
    a.created_at,
    a.updated_at,
    null::double precision as distance_km,
    jsonb_build_object(
      'id', c.id,
      'slug', c.slug,
      'title', c.title,
      'description', c.description,
      'background_color', c.background_color,
      'foreground_color', c.foreground_color,
      'icon_key', c.icon_key
    ) as category,
    public.activity_profile_context_json(a.id, a.organizer_id) as host,
    coalesce(participation.participants, '[]'::jsonb) as participants,
    coalesce(participation.participants_count, 0) as participants_count,
    coalesce(participation.is_joined, false) as is_joined,
    coalesce(participation.available_spots, 0) as available_spots,
    a.group_type,
    a.min_reputation_level,
    a.requires_identity_verified,
    a.is_private_location,
    a.target_age_bands,
    a.target_genders
  from public.activities a
  join public.activity_categories c on c.id = a.category_id
  left join lateral public.activity_participation_snapshot(a.id) participation on true
  where a.id = p_activity_id
    and c.is_active
    and not public.has_user_block(auth.uid(), a.organizer_id)
    and (
      a.organizer_id = auth.uid()
      or exists (
        select 1
        from public.activity_participants ap
        where ap.activity_id = a.id
          and ap.profile_id = auth.uid()
          and ap.status in ('joined', 'pending')
      )
      or (
        a.status = 'published'
        and a.starts_at >= now()
      )
    );
$$;

grant execute on function public.get_activity_detail(uuid) to authenticated;

notify pgrst, 'reload schema';
