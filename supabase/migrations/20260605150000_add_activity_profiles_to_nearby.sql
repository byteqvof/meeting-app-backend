do $$
begin
  create type public.activity_participant_status as enum (
    'joined',
    'cancelled'
  );
exception
  when duplicate_object then null;
end $$;

create table if not exists public.activity_participants (
  activity_id uuid not null references public.activities(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  status public.activity_participant_status not null default 'joined',
  joined_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (activity_id, profile_id)
);

create index if not exists activity_participants_profile_idx
  on public.activity_participants (profile_id);

create index if not exists activity_participants_status_idx
  on public.activity_participants (activity_id, status);

drop trigger if exists activity_participants_set_updated_at on public.activity_participants;
create trigger activity_participants_set_updated_at
before update on public.activity_participants
for each row execute function public.set_updated_at();

alter table public.activity_participants enable row level security;

grant select, insert, update, delete on table public.activity_participants to authenticated;

drop policy if exists "Authenticated users can read activity participants" on public.activity_participants;
create policy "Authenticated users can read activity participants"
on public.activity_participants
for select
to authenticated
using (true);

drop policy if exists "Users can join activities as themselves" on public.activity_participants;
create policy "Users can join activities as themselves"
on public.activity_participants
for insert
to authenticated
with check (profile_id = auth.uid());

drop policy if exists "Users can update their own activity participation" on public.activity_participants;
create policy "Users can update their own activity participation"
on public.activity_participants
for update
to authenticated
using (profile_id = auth.uid())
with check (profile_id = auth.uid());

drop policy if exists "Users can delete their own activity participation" on public.activity_participants;
create policy "Users can delete their own activity participation"
on public.activity_participants
for delete
to authenticated
using (profile_id = auth.uid());

create or replace function public.profile_json(p_profile_id uuid)
returns jsonb
language sql
stable
set search_path = public
as $$
  select jsonb_build_object(
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
    'is_verified', p.is_verified,
    'is_premium', p.is_premium,
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
  from public.profiles p
  where p.id = p_profile_id;
$$;

grant execute on function public.profile_json(uuid) to authenticated;

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
  participants_count integer
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
    coalesce(participant_profiles.participants, '[]'::jsonb) as participants,
    coalesce(participant_profiles.participants_count, 0) as participants_count
  from public.activities a
  join public.activity_categories c on c.id = a.category_id
  cross join origin
  left join lateral (
    select
      jsonb_agg(public.profile_json(ap.profile_id) order by ap.joined_at) as participants,
      count(*)::integer as participants_count
    from public.activity_participants ap
    where ap.activity_id = a.id
      and ap.status = 'joined'
  ) participant_profiles on true
  where c.is_active
    and a.status = 'published'
    and a.starts_at >= now()
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

notify pgrst, 'reload schema';
