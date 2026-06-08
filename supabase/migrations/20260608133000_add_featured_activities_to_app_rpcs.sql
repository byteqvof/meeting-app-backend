alter table public.activities
add column if not exists featured boolean not null default false;

create index if not exists activities_featured_published_starts_at_idx
  on public.activities (featured desc, starts_at)
  where status = 'published';

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
  featured boolean,
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
      a.featured,
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
    scoped.featured,
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
    scoped.featured desc,
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
  featured boolean,
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
    a.featured,
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
  featured boolean,
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
  is_private_location boolean
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
    a.featured,
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
    a.is_private_location
  from target_user
  join public.activities a on a.organizer_id = target_user.id
  join public.activity_categories c on c.id = a.category_id
  left join lateral public.activity_participation_snapshot(a.id) participation on true
  where (
      target_user.id = auth.uid()
      or (
        a.status = 'published'
        and a.starts_at >= now()
        and not public.has_user_block(auth.uid(), a.organizer_id)
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
  order by a.featured desc, a.starts_at desc, a.created_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 200);
$$;

grant execute on function public.list_activities_for_user(
  uuid,
  public.activity_status,
  integer
) to authenticated;

drop function if exists public.list_completed_activities_for_user(uuid, integer);

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
  featured boolean,
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
    a.featured,
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

drop function if exists public.list_joined_activities_for_user(uuid, integer);

create or replace function public.list_joined_activities_for_user(
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
  featured boolean,
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
  target_genders text[],
  participation_status text,
  can_send_chat boolean
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
    a.featured,
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
    ap.status = 'joined' as is_joined,
    coalesce(participation.available_spots, 0) as available_spots,
    a.group_type,
    a.min_reputation_level,
    a.requires_identity_verified,
    a.is_private_location,
    a.target_age_bands,
    a.target_genders,
    ap.status::text as participation_status,
    public.can_send_activity_chat(a.id, target_user.id) as can_send_chat
  from target_user
  join public.activity_participants ap
    on ap.profile_id = target_user.id
   and ap.status in ('joined', 'cancelled')
  join public.activities a on a.id = ap.activity_id
  join public.activity_categories c on c.id = a.category_id
  left join lateral public.activity_participation_snapshot(a.id) participation on true
  where target_user.id = auth.uid()
    and a.status = 'published'
    and (
      a.starts_at >= now()
      or exists (
        select 1
        from public.activity_chat_messages m
        where m.activity_id = a.id
      )
    )
  order by
    case when ap.status = 'joined' then 0 else 1 end,
    a.featured desc,
    a.starts_at asc,
    ap.joined_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 200);
$$;

grant execute on function public.list_joined_activities_for_user(uuid, integer)
to authenticated;

notify pgrst, 'reload schema';
