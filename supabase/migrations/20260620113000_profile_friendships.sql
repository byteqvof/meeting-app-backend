create table if not exists public.profile_friendships (
  id uuid primary key default extensions.gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete cascade,
  addressee_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (
    status in ('pending', 'accepted', 'declined')
  ),
  requested_at timestamptz not null default now(),
  responded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profile_friendships_not_self check (requester_id <> addressee_id)
);

create unique index if not exists profile_friendships_pair_idx
  on public.profile_friendships (
    least(requester_id, addressee_id),
    greatest(requester_id, addressee_id)
  );

create index if not exists profile_friendships_requester_status_idx
  on public.profile_friendships (requester_id, status, updated_at desc);

create index if not exists profile_friendships_addressee_status_idx
  on public.profile_friendships (addressee_id, status, updated_at desc);

drop trigger if exists profile_friendships_set_updated_at
on public.profile_friendships;

create trigger profile_friendships_set_updated_at
before update on public.profile_friendships
for each row execute function public.set_updated_at();

alter table public.profile_friendships enable row level security;

grant select on table public.profile_friendships to authenticated;

drop policy if exists "Users can read their friendships"
on public.profile_friendships;

create policy "Users can read their friendships"
on public.profile_friendships
for select
to authenticated
using (requester_id = auth.uid() or addressee_id = auth.uid());

create or replace function public.profile_friendship_status(
  p_profile_id uuid,
  p_user_id uuid default auth.uid()
)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_user_id is null then 'none'
    when p_profile_id is null then 'none'
    when p_profile_id = p_user_id then 'self'
    when public.has_user_block(p_user_id, p_profile_id) then 'blocked'
    when f.status = 'accepted' then 'accepted'
    when f.status = 'pending' and f.requester_id = p_user_id then 'pending_sent'
    when f.status = 'pending' and f.addressee_id = p_user_id then 'pending_received'
    when f.status = 'declined' then 'declined'
    else 'none'
  end
  from (select 1) seed
  left join public.profile_friendships f
    on (
      (f.requester_id = p_user_id and f.addressee_id = p_profile_id)
      or (f.requester_id = p_profile_id and f.addressee_id = p_user_id)
    )
  limit 1;
$$;

grant execute on function public.profile_friendship_status(uuid, uuid)
to authenticated;

create or replace function public.set_profile_friendship(
  p_target_profile_id uuid,
  p_action text
)
returns table (
  profile_id uuid,
  status text,
  direction text
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_action text := btrim(coalesce(p_action, ''));
  v_friendship public.profile_friendships%rowtype;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if p_target_profile_id = v_user_id then
    raise exception 'FRIEND_SELF';
  end if;

  if not exists (
    select 1 from public.profiles p where p.id = p_target_profile_id
  ) then
    raise exception 'FRIEND_PROFILE_NOT_FOUND';
  end if;

  if public.has_user_block(v_user_id, p_target_profile_id) then
    raise exception 'FRIEND_BLOCKED';
  end if;

  select f.*
  into v_friendship
  from public.profile_friendships f
  where (
    f.requester_id = v_user_id and f.addressee_id = p_target_profile_id
  ) or (
    f.requester_id = p_target_profile_id and f.addressee_id = v_user_id
  )
  for update;

  if v_action = 'request' then
    if not found then
      insert into public.profile_friendships (
        requester_id,
        addressee_id,
        status
      )
      values (v_user_id, p_target_profile_id, 'pending')
      returning * into v_friendship;
    elsif v_friendship.status = 'declined' then
      update public.profile_friendships f
      set requester_id = v_user_id,
          addressee_id = p_target_profile_id,
          status = 'pending',
          requested_at = now(),
          responded_at = null,
          updated_at = now()
      where f.id = v_friendship.id
      returning * into v_friendship;
    end if;
  elsif v_action = 'accept' then
    if not found or v_friendship.status <> 'pending' or v_friendship.addressee_id <> v_user_id then
      raise exception 'FRIEND_REQUEST_NOT_FOUND';
    end if;

    update public.profile_friendships f
    set status = 'accepted',
        responded_at = now(),
        updated_at = now()
    where f.id = v_friendship.id
    returning * into v_friendship;
  elsif v_action = 'decline' then
    if not found or v_friendship.status <> 'pending' or v_friendship.addressee_id <> v_user_id then
      raise exception 'FRIEND_REQUEST_NOT_FOUND';
    end if;

    update public.profile_friendships f
    set status = 'declined',
        responded_at = now(),
        updated_at = now()
    where f.id = v_friendship.id
    returning * into v_friendship;
  elsif v_action = 'remove' then
    if found then
      delete from public.profile_friendships f where f.id = v_friendship.id;
    end if;

    return query select p_target_profile_id, 'none'::text, 'none'::text;
    return;
  else
    raise exception 'FRIEND_ACTION_INVALID';
  end if;

  return query
  select
    p_target_profile_id,
    public.profile_friendship_status(p_target_profile_id, v_user_id),
    case
      when v_friendship.requester_id = v_user_id then 'outgoing'
      else 'incoming'
    end;
end;
$$;

grant execute on function public.set_profile_friendship(uuid, text)
to authenticated;

create or replace function public.list_profile_friendships(
  p_status text default null
)
returns table (
  friendship_id uuid,
  profile_id uuid,
  status text,
  direction text,
  updated_at timestamptz,
  profile jsonb
)
language sql
stable
security definer
set search_path = public
as $$
  with current_profile as (
    select auth.uid() as id
  ),
  scoped as (
    select
      f.*,
      case
        when f.requester_id = current_profile.id then f.addressee_id
        else f.requester_id
      end as other_profile_id,
      case
        when f.requester_id = current_profile.id then 'outgoing'
        else 'incoming'
      end as direction
    from current_profile
    join public.profile_friendships f
      on current_profile.id in (f.requester_id, f.addressee_id)
    where current_profile.id is not null
      and f.status <> 'declined'
      and (p_status is null or f.status = p_status)
  )
  select
    scoped.id as friendship_id,
    scoped.other_profile_id as profile_id,
    scoped.status,
    scoped.direction,
    scoped.updated_at,
    public.profile_json(scoped.other_profile_id) as profile
  from scoped
  where not public.has_user_block(auth.uid(), scoped.other_profile_id)
  order by
    case scoped.status when 'pending' then 0 else 1 end,
    scoped.updated_at desc;
$$;

grant execute on function public.list_profile_friendships(text)
to authenticated;

notify pgrst, 'reload schema';
