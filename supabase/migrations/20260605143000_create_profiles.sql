create extension if not exists pgcrypto with schema extensions;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 2 and 120),
  initials text not null check (char_length(initials) between 1 and 8),
  city_name text,
  member_since timestamptz not null default now(),
  avatar_url text,
  attendance_score integer not null default 100
    check (attendance_score between 0 and 100),
  activities_joined_count integer not null default 0
    check (activities_joined_count >= 0),
  activities_hosted_count integer not null default 0
    check (activities_hosted_count >= 0),
  rating numeric(2, 1) not null default 0
    check (rating between 0 and 5),
  is_verified boolean not null default false,
  is_premium boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.profile_category_links (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  category_id uuid not null references public.activity_categories(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (profile_id, category_id)
);

create index if not exists profiles_display_name_idx
  on public.profiles (display_name);

create index if not exists profiles_city_name_idx
  on public.profiles (city_name);

create index if not exists profile_category_links_category_idx
  on public.profile_category_links (category_id);

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

alter table public.profiles enable row level security;
alter table public.profile_category_links enable row level security;

grant select, insert, update, delete on table public.profiles to authenticated;
grant select, insert, update, delete on table public.profile_category_links to authenticated;

drop policy if exists "Authenticated users can read profiles" on public.profiles;
create policy "Authenticated users can read profiles"
on public.profiles
for select
to authenticated
using (true);

drop policy if exists "Users can create their own profile" on public.profiles;
create policy "Users can create their own profile"
on public.profiles
for insert
to authenticated
with check (id = auth.uid());

drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile"
on public.profiles
for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

drop policy if exists "Users can delete their own profile" on public.profiles;
create policy "Users can delete their own profile"
on public.profiles
for delete
to authenticated
using (id = auth.uid());

drop policy if exists "Authenticated users can read profile categories" on public.profile_category_links;
create policy "Authenticated users can read profile categories"
on public.profile_category_links
for select
to authenticated
using (true);

drop policy if exists "Users can create their own profile categories" on public.profile_category_links;
create policy "Users can create their own profile categories"
on public.profile_category_links
for insert
to authenticated
with check (profile_id = auth.uid());

drop policy if exists "Users can update their own profile categories" on public.profile_category_links;
create policy "Users can update their own profile categories"
on public.profile_category_links
for update
to authenticated
using (profile_id = auth.uid())
with check (profile_id = auth.uid());

drop policy if exists "Users can delete their own profile categories" on public.profile_category_links;
create policy "Users can delete their own profile categories"
on public.profile_category_links
for delete
to authenticated
using (profile_id = auth.uid());

notify pgrst, 'reload schema';
