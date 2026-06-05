create extension if not exists pgcrypto with schema extensions;
create extension if not exists postgis with schema extensions;

do $$
begin
  create type public.activity_status as enum (
    'draft',
    'published',
    'cancelled',
    'archived'
  );
exception
  when duplicate_object then null;
end $$;

create table if not exists public.activity_categories (
  id uuid primary key default extensions.gen_random_uuid(),
  slug text not null unique,
  title text not null,
  description text,
  background_color text not null default '#eef2ff'
    check (background_color ~ '^#[0-9a-fA-F]{6}$'),
  foreground_color text not null default '#111827'
    check (foreground_color ~ '^#[0-9a-fA-F]{6}$'),
  icon_key text not null,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.activities (
  id uuid primary key default extensions.gen_random_uuid(),
  category_id uuid not null references public.activity_categories(id) on delete restrict,
  organizer_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 3 and 120),
  description text not null check (char_length(description) between 10 and 4000),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  location extensions.geography(Point, 4326) generated always as (
    extensions.st_setsrid(extensions.st_makepoint(longitude, latitude), 4326)::extensions.geography
  ) stored,
  address_line text,
  city text,
  country_code text not null default 'NL' check (country_code ~ '^[A-Z]{2}$'),
  starts_at timestamptz not null,
  ends_at timestamptz check (ends_at is null or ends_at > starts_at),
  max_participants integer check (max_participants is null or max_participants > 0),
  price_cents integer not null default 0 check (price_cents >= 0),
  currency text not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  image_url text,
  status public.activity_status not null default 'published',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists activity_categories_active_sort_idx
  on public.activity_categories (is_active, sort_order, title);

create index if not exists activities_location_gist_idx
  on public.activities using gist (location);

create index if not exists activities_category_starts_at_idx
  on public.activities (category_id, starts_at);

create index if not exists activities_organizer_idx
  on public.activities (organizer_id);

create index if not exists activities_status_starts_at_idx
  on public.activities (status, starts_at);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists activity_categories_set_updated_at on public.activity_categories;
create trigger activity_categories_set_updated_at
before update on public.activity_categories
for each row execute function public.set_updated_at();

drop trigger if exists activities_set_updated_at on public.activities;
create trigger activities_set_updated_at
before update on public.activities
for each row execute function public.set_updated_at();

alter table public.activity_categories enable row level security;
alter table public.activities enable row level security;

grant select on table public.activity_categories to authenticated;
grant select, insert, update, delete on table public.activities to authenticated;

drop policy if exists "Authenticated users can read active categories" on public.activity_categories;
create policy "Authenticated users can read active categories"
on public.activity_categories
for select
to authenticated
using (is_active);

drop policy if exists "Authenticated users can read published activities" on public.activities;
create policy "Authenticated users can read published activities"
on public.activities
for select
to authenticated
using (
  status = 'published'
  or organizer_id = auth.uid()
);

drop policy if exists "Users can create their own activities" on public.activities;
create policy "Users can create their own activities"
on public.activities
for insert
to authenticated
with check (organizer_id = auth.uid());

drop policy if exists "Users can update their own activities" on public.activities;
create policy "Users can update their own activities"
on public.activities
for update
to authenticated
using (organizer_id = auth.uid())
with check (organizer_id = auth.uid());

drop policy if exists "Users can delete their own activities" on public.activities;
create policy "Users can delete their own activities"
on public.activities
for delete
to authenticated
using (organizer_id = auth.uid());

insert into public.activity_categories (
  slug,
  title,
  description,
  background_color,
  foreground_color,
  icon_key,
  sort_order
)
values
  ('sport', 'Sport', 'Samen bewegen, trainen of een wedstrijd spelen.', '#dcfce7', '#14532d', 'dumbbell', 10),
  ('food-drinks', 'Eten en drinken', 'Koffie, lunch, diner of proeverijen met anderen.', '#ffedd5', '#7c2d12', 'utensils', 20),
  ('culture', 'Cultuur', 'Museum, theater, film, lezing of lokale kunst.', '#f3e8ff', '#581c87', 'palette', 30),
  ('music', 'Muziek', 'Concerten, jamsessies, koren en muziekavonden.', '#dbeafe', '#1e3a8a', 'music', 40),
  ('outdoors', 'Buiten', 'Wandelen, natuur, parkactiviteiten en buitenlucht.', '#ccfbf1', '#134e4a', 'trees', 50),
  ('volunteering', 'Vrijwilligerswerk', 'Iets goeds doen in de buurt of voor een initiatief.', '#fee2e2', '#7f1d1d', 'heart-handshake', 60),
  ('games', 'Spelletjes', 'Bordspellen, quizzen, kaartspellen en game-avonden.', '#fef9c3', '#713f12', 'dice-5', 70),
  ('networking', 'Netwerken', 'Nieuwe mensen ontmoeten rondom werk, studie of interesses.', '#e0e7ff', '#312e81', 'users', 80)
on conflict (slug) do update
set
  title = excluded.title,
  description = excluded.description,
  background_color = excluded.background_color,
  foreground_color = excluded.foreground_color,
  icon_key = excluded.icon_key,
  sort_order = excluded.sort_order,
  is_active = true;

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
  category jsonb
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
    ) as category
  from public.activities a
  join public.activity_categories c on c.id = a.category_id
  cross join origin
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
