alter table public.profiles
add column if not exists age_band text;

alter table public.profiles
add column if not exists gender text;

alter table public.profiles
drop constraint if exists profiles_age_band_check;

alter table public.profiles
add constraint profiles_age_band_check
check (
  age_band is null
  or age_band in ('18_24', '25_34', '35_44', '45_54', '55_64', '65_plus')
);

alter table public.profiles
drop constraint if exists profiles_gender_check;

alter table public.profiles
add constraint profiles_gender_check
check (
  gender is null
  or gender in ('woman', 'man', 'non_binary', 'prefer_not_to_say')
);

alter table public.activities
add column if not exists target_age_bands text[] not null default '{}'::text[];

alter table public.activities
add column if not exists target_genders text[] not null default '{}'::text[];

alter table public.activities
drop constraint if exists activities_target_age_bands_check;

alter table public.activities
add constraint activities_target_age_bands_check
check (
  target_age_bands <@ array[
    '18_24',
    '25_34',
    '35_44',
    '45_54',
    '55_64',
    '65_plus'
  ]::text[]
);

alter table public.activities
drop constraint if exists activities_target_genders_check;

alter table public.activities
add constraint activities_target_genders_check
check (
  target_genders <@ array[
    'woman',
    'man',
    'non_binary',
    'prefer_not_to_say'
  ]::text[]
);

create index if not exists activities_target_age_bands_gin_idx
  on public.activities using gin (target_age_bands);

create index if not exists activities_target_genders_gin_idx
  on public.activities using gin (target_genders);

create or replace function public.profile_json(p_profile_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_profile_id is null then null::jsonb
    when auth.uid() is not null and public.has_user_block(auth.uid(), p_profile_id) then null::jsonb
    else jsonb_build_object(
      'id', p.id,
      'display_name', p.display_name,
      'initials', p.initials,
      'city_name', p.city_name,
      'member_since', p.member_since,
      'avatar_url', p.avatar_url,
      'attendance_score', p.attendance_score,
      'activities_joined_count', p.activities_joined_count,
      'activities_hosted_count', p.activities_hosted_count,
      'rating', p.rating,
      'is_verified', coalesce(t.identity_status = 'verified', false),
      'is_premium', p.is_premium,
      'age_band', p.age_band,
      'gender', p.gender,
      'trust', jsonb_build_object(
        'phone_verified', coalesce(t.phone_verified, false),
        'phone_verified_at', t.phone_verified_at,
        'identity_status', coalesce(t.identity_status, 'unverified'),
        'identity_method', t.identity_method,
        'identity_completed_at', t.identity_completed_at,
        'age_verified', coalesce(t.age_verified, false),
        'reputation_level', coalesce(t.reputation_level, 'new_member'),
        'reputation_score', coalesce(t.reputation_score, 0)
      ),
      'interests', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'id', c.id,
            'label', c.title,
            'icon_key', c.icon_key,
            'foreground_color', c.foreground_color,
            'background_color', c.background_color
          )
          order by c.sort_order, c.title
        )
        from public.profile_category_links pcl
        join public.activity_categories c on c.id = pcl.category_id
        where pcl.profile_id = p.id
      ), '[]'::jsonb)
    )
  end
  from public.profiles p
  left join public.profile_trust t on t.profile_id = p.id
  where p.id = p_profile_id;
$$;

grant execute on function public.profile_json(uuid) to authenticated;

drop function if exists public.set_activity_participation(uuid, boolean);

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

  if v_activity.organizer_id = v_user_id then
    raise exception 'ACTIVITY_OWNER_CANNOT_JOIN';
  end if;

  if public.has_user_block(v_user_id, v_activity.organizer_id) then
    raise exception 'ACTIVITY_BLOCKED';
  end if;

  if v_activity.status <> 'published' or v_activity.starts_at < now() then
    raise exception 'ACTIVITY_UNAVAILABLE';
  end if;

  if coalesce(p_join, true) then
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
  else
    update public.activity_participants ap
    set status = 'cancelled',
        updated_at = now()
    where ap.activity_id = p_activity_id
      and ap.profile_id = v_user_id;
  end if;

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

drop function if exists public.search_activities_nearby(
  double precision,
  double precision,
  double precision,
  uuid,
  integer
);

drop function if exists public.search_activities_nearby(
  double precision,
  double precision,
  double precision,
  uuid[],
  timestamptz,
  timestamptz,
  text[],
  text[],
  boolean,
  boolean,
  integer,
  integer,
  text,
  integer
);

create or replace function public.search_activities_nearby(
  p_latitude double precision,
  p_longitude double precision,
  p_radius_km double precision default 10,
  p_category_ids uuid[] default '{}'::uuid[],
  p_date_from timestamptz default null,
  p_date_to timestamptz default null,
  p_target_age_bands text[] default '{}'::text[],
  p_target_genders text[] default '{}'::text[],
  p_requires_identity_verified boolean default false,
  p_available_only boolean default false,
  p_min_participants integer default null,
  p_max_participants integer default null,
  p_sort text default 'distance',
  p_limit integer default 50
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
set search_path = public, extensions
as $$
  with input as (
    select
      least(greatest(coalesce(p_radius_km, 10), 0.1), 100) as radius_km,
      coalesce(p_category_ids, '{}'::uuid[]) as category_ids,
      coalesce(p_target_age_bands, '{}'::text[]) as target_age_bands,
      coalesce(p_target_genders, '{}'::text[]) as target_genders,
      coalesce(p_requires_identity_verified, false) as requires_identity_verified,
      coalesce(p_available_only, false) as available_only,
      p_min_participants as min_participants,
      p_max_participants as max_participants,
      case
        when p_sort in ('distance', 'start_time', 'participants') then p_sort
        else 'distance'
      end as requested_sort,
      least(greatest(coalesce(p_limit, 50), 1), 100) as result_limit
  ),
  origin as (
    select st_setsrid(st_makepoint(p_longitude, p_latitude), 4326)::geography as point
  ),
  scoped as (
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
      st_distance(a.location, origin.point) as distance_m,
      jsonb_build_object(
        'id', c.id,
        'slug', c.slug,
        'title', c.title,
        'description', c.description,
        'background_color', c.background_color,
        'foreground_color', c.foreground_color,
        'icon_key', c.icon_key
      ) as category,
      public.profile_json(a.organizer_id) as host,
      coalesce(participation.participants, '[]'::jsonb) as participants,
      coalesce(participation.participants_count, 0) as participants_count,
      coalesce(participation.is_joined, false) as is_joined,
      coalesce(participation.available_spots, 0) as available_spots,
      a.group_type,
      a.min_reputation_level,
      a.requires_identity_verified,
      a.is_private_location,
      a.target_age_bands,
      a.target_genders,
      input.requested_sort,
      input.result_limit
    from public.activities a
    join public.activity_categories c on c.id = a.category_id
    cross join origin
    cross join input
    left join lateral public.activity_participation_snapshot(a.id) participation on true
    where c.is_active
      and a.status = 'published'
      and a.starts_at >= now()
      and a.organizer_id <> auth.uid()
      and not public.has_user_block(auth.uid(), a.organizer_id)
      and (
        cardinality(input.category_ids) = 0
        or a.category_id = any(input.category_ids)
      )
      and (p_date_from is null or a.starts_at >= p_date_from)
      and (p_date_to is null or a.starts_at < p_date_to)
      and (
        not input.requires_identity_verified
        or a.requires_identity_verified
      )
      and (
        cardinality(input.target_age_bands) = 0
        or cardinality(a.target_age_bands) = 0
        or a.target_age_bands && input.target_age_bands
      )
      and (
        cardinality(input.target_genders) = 0
        or cardinality(a.target_genders) = 0
        or a.target_genders && input.target_genders
      )
      and (
        not input.available_only
        or a.max_participants is null
        or coalesce(participation.available_spots, 0) > 0
      )
      and (
        input.min_participants is null
        or coalesce(participation.participants_count, 0) >= input.min_participants
      )
      and (
        input.max_participants is null
        or coalesce(participation.participants_count, 0) <= input.max_participants
      )
      and st_dwithin(
        a.location,
        origin.point,
        input.radius_km * 1000
      )
  )
  select
    scoped.id,
    scoped.category_id,
    scoped.organizer_id,
    scoped.title,
    scoped.description,
    scoped.latitude,
    scoped.longitude,
    scoped.address_line,
    scoped.city,
    scoped.country_code,
    scoped.starts_at,
    scoped.ends_at,
    scoped.max_participants,
    scoped.price_cents,
    scoped.currency,
    scoped.image_url,
    scoped.status,
    scoped.metadata,
    scoped.created_at,
    scoped.updated_at,
    round((scoped.distance_m / 1000)::numeric, 2)::double precision as distance_km,
    scoped.category,
    scoped.host,
    scoped.participants,
    scoped.participants_count,
    scoped.is_joined,
    scoped.available_spots,
    scoped.group_type,
    scoped.min_reputation_level,
    scoped.requires_identity_verified,
    scoped.is_private_location,
    scoped.target_age_bands,
    scoped.target_genders
  from scoped
  order by
    case when scoped.requested_sort = 'start_time' then scoped.starts_at end asc,
    case when scoped.requested_sort = 'participants' then scoped.participants_count end desc,
    case when scoped.requested_sort = 'distance' then scoped.distance_m end asc,
    scoped.starts_at asc,
    scoped.created_at desc
  limit (select result_limit from input);
$$;

grant execute on function public.search_activities_nearby(
  double precision,
  double precision,
  double precision,
  uuid[],
  timestamptz,
  timestamptz,
  text[],
  text[],
  boolean,
  boolean,
  integer,
  integer,
  text,
  integer
) to authenticated;

drop function if exists public.get_activity_detail(uuid);

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
    public.profile_json(a.organizer_id) as host,
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

create or replace function public.sync_current_user_trust()
returns table (
  profile_id uuid,
  phone_verified boolean,
  phone_verified_at timestamptz,
  identity_status text,
  identity_method text,
  identity_completed_at timestamptz,
  age_verified boolean,
  reputation_level text,
  reputation_score integer
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_phone_confirmed_at timestamptz;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select u.phone_confirmed_at
  into v_phone_confirmed_at
  from auth.users u
  where u.id = v_user_id;

  insert into public.profile_trust (
    profile_id,
    phone_verified,
    phone_verified_at
  )
  values (
    v_user_id,
    v_phone_confirmed_at is not null,
    v_phone_confirmed_at
  )
  on conflict on constraint profile_trust_pkey
  do update set
    phone_verified = excluded.phone_verified,
    phone_verified_at = excluded.phone_verified_at,
    updated_at = now();

  return query
  select
    t.profile_id,
    t.phone_verified,
    t.phone_verified_at,
    t.identity_status,
    t.identity_method,
    t.identity_completed_at,
    t.age_verified,
    t.reputation_level,
    t.reputation_score
  from public.profile_trust t
  where t.profile_id = v_user_id;
end;
$$;

grant execute on function public.sync_current_user_trust() to authenticated;

create or replace function public.recalculate_profile_trust(p_profile_id uuid)
returns table (
  profile_id uuid,
  reputation_level text,
  reputation_score integer
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_account_days integer := 0;
  v_completed_joined integer := 0;
  v_completed_hosted integer := 0;
  v_present_count integer := 0;
  v_absent_count integer := 0;
  v_avg_rating numeric := 0;
  v_moderation_penalty integer := 0;
  v_score integer := 0;
  v_level text := 'new_member';
begin
  if p_profile_id is null then
    raise exception 'PROFILE_REQUIRED';
  end if;

  select greatest(0, floor(extract(epoch from now() - p.member_since) / 86400)::integer)
  into v_account_days
  from public.profiles p
  where p.id = p_profile_id;

  if not found then
    raise exception 'PROFILE_REQUIRED';
  end if;

  select count(*)::integer
  into v_completed_joined
  from public.activity_participants ap
  join public.activities a on a.id = ap.activity_id
  where ap.profile_id = p_profile_id
    and ap.status = 'joined'
    and a.status = 'completed';

  select count(*)::integer
  into v_completed_hosted
  from public.activities a
  where a.organizer_id = p_profile_id
    and a.status = 'completed';

  select
    count(*) filter (where aa.status = 'present')::integer,
    count(*) filter (where aa.status = 'absent')::integer
  into v_present_count, v_absent_count
  from public.activity_attendance aa
  where aa.profile_id = p_profile_id;

  select coalesce(avg(af.rating), 0)
  into v_avg_rating
  from public.activity_feedback af
  where af.target_profile_id = p_profile_id;

  select (count(*) * 20)::integer
  into v_moderation_penalty
  from public.moderation_actions ma
  where ma.profile_id = p_profile_id
    and ma.action_type in ('warning', 'temporary_suspension', 'ban');

  v_score :=
    least(v_account_days / 14, 20)
    + least(v_completed_joined * 5, 20)
    + least(v_completed_hosted * 7, 20)
    + least(v_present_count * 4, 20)
    + case
        when v_avg_rating >= 4.5 then 20
        when v_avg_rating >= 4 then 15
        when v_avg_rating >= 3 then 8
        else 0
      end
    - least(v_absent_count * 8, 30)
    - least(v_moderation_penalty, 60);

  v_score := least(greatest(v_score, 0), 100);
  v_level := public.reputation_level_for_score(v_score);

  insert into public.profile_trust (
    profile_id,
    reputation_level,
    reputation_score,
    last_calculated_at
  )
  values (
    p_profile_id,
    v_level,
    v_score,
    now()
  )
  on conflict on constraint profile_trust_pkey
  do update set
    reputation_level = excluded.reputation_level,
    reputation_score = excluded.reputation_score,
    last_calculated_at = now(),
    updated_at = now();

  return query select p_profile_id, v_level, v_score;
end;
$$;

grant execute on function public.recalculate_profile_trust(uuid) to authenticated;

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

  if v_status not in ('present', 'absent') then
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
      and (
        a.organizer_id = p_profile_id
        or exists (
          select 1
          from public.activity_participants ap
          where ap.activity_id = a.id
            and ap.profile_id = p_profile_id
            and ap.status = 'joined'
        )
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

notify pgrst, 'reload schema';
