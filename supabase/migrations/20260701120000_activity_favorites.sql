create table if not exists public.activity_favorites (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  activity_id uuid not null references public.activities(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (profile_id, activity_id)
);

create index if not exists activity_favorites_activity_idx
  on public.activity_favorites (activity_id);

alter table public.activity_favorites enable row level security;

grant select, insert, delete on table public.activity_favorites to authenticated;
grant select, insert, delete on table public.activity_favorites to service_role;

drop policy if exists "Users can read their activity favorites"
on public.activity_favorites;
create policy "Users can read their activity favorites"
on public.activity_favorites
for select
to authenticated
using (profile_id = auth.uid());

drop policy if exists "Users can add activity favorites"
on public.activity_favorites;
create policy "Users can add activity favorites"
on public.activity_favorites
for insert
to authenticated
with check (profile_id = auth.uid());

drop policy if exists "Users can remove activity favorites"
on public.activity_favorites;
create policy "Users can remove activity favorites"
on public.activity_favorites
for delete
to authenticated
using (profile_id = auth.uid());

create or replace function public.get_activity_favorite_status(
  p_activity_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1 from public.activities a where a.id = p_activity_id
  ) then
    raise exception 'ACTIVITY_NOT_FOUND';
  end if;

  return exists (
    select 1
    from public.activity_favorites af
    where af.profile_id = v_user_id
      and af.activity_id = p_activity_id
  );
end;
$$;

create or replace function public.set_activity_favorite(
  p_activity_id uuid,
  p_is_favorited boolean
)
returns table (
  activity_id uuid,
  is_favorited boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1 from public.activities a where a.id = p_activity_id
  ) then
    raise exception 'ACTIVITY_NOT_FOUND';
  end if;

  if p_is_favorited then
    insert into public.activity_favorites (profile_id, activity_id)
    values (v_user_id, p_activity_id)
    on conflict (profile_id, activity_id) do nothing;
  else
    delete from public.activity_favorites af
    where af.profile_id = v_user_id
      and af.activity_id = p_activity_id;
  end if;

  return query
  select
    p_activity_id,
    exists (
      select 1
      from public.activity_favorites af
      where af.profile_id = v_user_id
        and af.activity_id = p_activity_id
    );
end;
$$;

grant execute on function public.get_activity_favorite_status(uuid)
to authenticated, service_role;

grant execute on function public.set_activity_favorite(uuid, boolean)
to authenticated, service_role;
