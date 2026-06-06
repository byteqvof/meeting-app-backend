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
  ),
  counts as (
    select count(*)::integer as participants_count
    from joined_participants
  )
  select
    coalesce((
      select jsonb_agg(public.profile_json(jp.profile_id) order by jp.joined_at)
      from joined_participants jp
      where jp.profile_id <> auth.uid()
    ), '[]'::jsonb) as participants,
    counts.participants_count,
    exists (
      select 1
      from joined_participants jp
      where jp.profile_id = auth.uid()
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

drop function if exists public.search_activities_nearby(
  double precision,
  double precision,
  double precision,
  uuid,
  integer
);

create or replace function public.search_activities_nearby(
  p_latitude double precision,
  p_longitude double precision,
  p_radius_km double precision default 10,
  p_category_id uuid default null,
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
  available_spots integer
)
language sql
stable
set search_path = public, extensions
as $$
  with origin as (
    select st_setsrid(st_makepoint(p_longitude, p_latitude), 4326)::geography as point
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
    round((st_distance(a.location, origin.point) / 1000)::numeric, 2)::double precision as distance_km,
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
    coalesce(participation.available_spots, 0) as available_spots
  from public.activities a
  join public.activity_categories c on c.id = a.category_id
  cross join origin
  left join lateral public.activity_participation_snapshot(a.id) participation on true
  where c.is_active
    and a.status = 'published'
    and a.starts_at >= now()
    and a.organizer_id <> auth.uid()
    and (p_category_id is null or a.category_id = p_category_id)
    and st_dwithin(
      a.location,
      origin.point,
      least(greatest(coalesce(p_radius_km, 10), 0.1), 100) * 1000
    )
  order by st_distance(a.location, origin.point), a.starts_at
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
$$;

grant execute on function public.search_activities_nearby(
  double precision,
  double precision,
  double precision,
  uuid,
  integer
) to authenticated;

drop function if exists public.list_activities_for_user(
  uuid,
  public.activity_status,
  integer
);

create or replace function public.list_activities_for_user(
  p_user_id uuid default null,
  p_status public.activity_status default null,
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
    public.profile_json(a.organizer_id) as host,
    coalesce(participation.participants, '[]'::jsonb) as participants,
    coalesce(participation.participants_count, 0) as participants_count,
    coalesce(participation.is_joined, false) as is_joined,
    coalesce(participation.available_spots, 0) as available_spots
  from target_user
  join public.activities a on a.organizer_id = target_user.id
  join public.activity_categories c on c.id = a.category_id
  left join lateral public.activity_participation_snapshot(a.id) participation on true
  where (
      target_user.id = auth.uid()
      or (
        a.status = 'published'
        and a.starts_at >= now()
      )
    )
    and (
      p_status is null
      or (
        target_user.id = auth.uid()
        and a.status = p_status
      )
      or (
        target_user.id <> auth.uid()
        and p_status = 'published'
        and a.status = 'published'
      )
    )
  order by a.starts_at desc, a.created_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 200);
$$;

grant execute on function public.list_activities_for_user(
  uuid,
  public.activity_status,
  integer
) to authenticated;

notify pgrst, 'reload schema';
