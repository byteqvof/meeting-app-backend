create table if not exists public.activity_chat_messages (
  id uuid primary key default extensions.gen_random_uuid(),
  activity_id uuid not null references public.activities(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 800),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists activity_chat_messages_activity_created_idx
  on public.activity_chat_messages (activity_id, created_at desc);

create index if not exists activity_chat_messages_sender_idx
  on public.activity_chat_messages (sender_id);

drop trigger if exists activity_chat_messages_set_updated_at
on public.activity_chat_messages;

create trigger activity_chat_messages_set_updated_at
before update on public.activity_chat_messages
for each row execute function public.set_updated_at();

create or replace function public.can_access_activity_chat(
  p_activity_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    p_user_id is not null
    and exists (
      select 1
      from public.activities a
      where a.id = p_activity_id
        and (
          a.organizer_id = p_user_id
          or exists (
            select 1
            from public.activity_participants ap
            where ap.activity_id = a.id
              and ap.profile_id = p_user_id
              and ap.status = 'joined'
          )
        )
    );
$$;

grant execute on function public.can_access_activity_chat(uuid, uuid)
to authenticated;

alter table public.activity_chat_messages enable row level security;

grant select, insert on table public.activity_chat_messages to authenticated;

drop policy if exists "Chat members can read activity messages"
on public.activity_chat_messages;

create policy "Chat members can read activity messages"
on public.activity_chat_messages
for select
to authenticated
using (public.can_access_activity_chat(activity_id, auth.uid()));

drop policy if exists "Chat members can send activity messages"
on public.activity_chat_messages;

create policy "Chat members can send activity messages"
on public.activity_chat_messages
for insert
to authenticated
with check (
  sender_id = auth.uid()
  and public.can_access_activity_chat(activity_id, auth.uid())
);

create or replace function public.list_activity_chat_messages(
  p_activity_id uuid,
  p_limit integer default 50,
  p_before timestamptz default null
)
returns table (
  id uuid,
  activity_id uuid,
  sender_id uuid,
  body text,
  created_at timestamptz,
  sender jsonb
)
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

  if not exists (select 1 from public.activities where id = p_activity_id) then
    raise exception 'ACTIVITY_NOT_FOUND';
  end if;

  if not public.can_access_activity_chat(p_activity_id, v_user_id) then
    raise exception 'ACTIVITY_CHAT_FORBIDDEN';
  end if;

  return query
  with scoped_messages as (
    select m.*
    from public.activity_chat_messages m
    where m.activity_id = p_activity_id
      and (p_before is null or m.created_at < p_before)
    order by m.created_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 100)
  )
  select
    scoped_messages.id,
    scoped_messages.activity_id,
    scoped_messages.sender_id,
    scoped_messages.body,
    scoped_messages.created_at,
    public.profile_json(scoped_messages.sender_id) as sender
  from scoped_messages
  order by scoped_messages.created_at asc;
end;
$$;

grant execute on function public.list_activity_chat_messages(
  uuid,
  integer,
  timestamptz
) to authenticated;

create or replace function public.send_activity_chat_message(
  p_activity_id uuid,
  p_body text
)
returns table (
  id uuid,
  activity_id uuid,
  sender_id uuid,
  body text,
  created_at timestamptz,
  sender jsonb
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_body text := btrim(coalesce(p_body, ''));
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (select 1 from public.activities where id = p_activity_id) then
    raise exception 'ACTIVITY_NOT_FOUND';
  end if;

  if not public.can_access_activity_chat(p_activity_id, v_user_id) then
    raise exception 'ACTIVITY_CHAT_FORBIDDEN';
  end if;

  if char_length(v_body) < 1 or char_length(v_body) > 800 then
    raise exception 'CHAT_MESSAGE_INVALID';
  end if;

  return query
  with inserted_message as (
    insert into public.activity_chat_messages (
      activity_id,
      sender_id,
      body
    )
    values (
      p_activity_id,
      v_user_id,
      v_body
    )
    returning *
  )
  select
    inserted_message.id,
    inserted_message.activity_id,
    inserted_message.sender_id,
    inserted_message.body,
    inserted_message.created_at,
    public.profile_json(inserted_message.sender_id) as sender
  from inserted_message;
end;
$$;

grant execute on function public.send_activity_chat_message(uuid, text)
to authenticated;

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
    true as is_joined,
    coalesce(participation.available_spots, 0) as available_spots
  from target_user
  join public.activity_participants ap
    on ap.profile_id = target_user.id
   and ap.status = 'joined'
  join public.activities a on a.id = ap.activity_id
  join public.activity_categories c on c.id = a.category_id
  left join lateral public.activity_participation_snapshot(a.id) participation on true
  where target_user.id = auth.uid()
    and a.status = 'published'
    and a.starts_at >= now()
  order by a.starts_at asc, ap.joined_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 200);
$$;

grant execute on function public.list_joined_activities_for_user(uuid, integer)
to authenticated;

notify pgrst, 'reload schema';
