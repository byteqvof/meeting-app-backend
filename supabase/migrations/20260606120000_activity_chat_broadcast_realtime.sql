alter table public.activity_chat_messages
add column if not exists client_message_id uuid;

create unique index if not exists activity_chat_messages_sender_client_message_idx
  on public.activity_chat_messages (sender_id, client_message_id)
  where client_message_id is not null;

create index if not exists activity_chat_messages_activity_created_id_idx
  on public.activity_chat_messages (activity_id, created_at desc, id desc);

create or replace function public.activity_chat_id_from_realtime_topic(
  p_topic text
)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_activity_id text;
begin
  if p_topic is null then
    return null;
  end if;

  if p_topic !~* '^activity-chat:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return null;
  end if;

  v_activity_id := split_part(p_topic, ':', 2);
  return v_activity_id::uuid;
end;
$$;

grant execute on function public.activity_chat_id_from_realtime_topic(text)
to authenticated;

drop function if exists public.list_activity_chat_messages(
  uuid,
  integer,
  timestamptz
);

create or replace function public.list_activity_chat_messages(
  p_activity_id uuid,
  p_limit integer default 50,
  p_before timestamptz default null,
  p_after_created_at timestamptz default null,
  p_after_id uuid default null
)
returns table (
  id uuid,
  activity_id uuid,
  sender_id uuid,
  body text,
  created_at timestamptz,
  sender jsonb,
  client_message_id uuid
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_after_id uuid := coalesce(
    p_after_id,
    '00000000-0000-0000-0000-000000000000'::uuid
  );
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.activities a
    where a.id = p_activity_id
  ) then
    raise exception 'ACTIVITY_NOT_FOUND';
  end if;

  if not public.can_access_activity_chat(p_activity_id, v_user_id) then
    raise exception 'ACTIVITY_CHAT_FORBIDDEN';
  end if;

  if p_after_created_at is not null then
    return query
    select
      m.id,
      m.activity_id,
      m.sender_id,
      m.body,
      m.created_at,
      public.profile_json(m.sender_id) as sender,
      m.client_message_id
    from public.activity_chat_messages m
    where m.activity_id = p_activity_id
      and (
        m.created_at > p_after_created_at
        or (m.created_at = p_after_created_at and m.id > v_after_id)
      )
    order by m.created_at asc, m.id asc
    limit v_limit;
    return;
  end if;

  return query
  with scoped_messages as (
    select m.*
    from public.activity_chat_messages m
    where m.activity_id = p_activity_id
      and (p_before is null or m.created_at < p_before)
    order by m.created_at desc, m.id desc
    limit v_limit
  )
  select
    scoped_messages.id,
    scoped_messages.activity_id,
    scoped_messages.sender_id,
    scoped_messages.body,
    scoped_messages.created_at,
    public.profile_json(scoped_messages.sender_id) as sender,
    scoped_messages.client_message_id
  from scoped_messages
  order by scoped_messages.created_at asc, scoped_messages.id asc;
end;
$$;

grant execute on function public.list_activity_chat_messages(
  uuid,
  integer,
  timestamptz,
  timestamptz,
  uuid
) to authenticated;

drop function if exists public.send_activity_chat_message(uuid, text);

create or replace function public.send_activity_chat_message(
  p_activity_id uuid,
  p_body text,
  p_client_message_id uuid default null
)
returns table (
  id uuid,
  activity_id uuid,
  sender_id uuid,
  body text,
  created_at timestamptz,
  sender jsonb,
  client_message_id uuid
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

  if not exists (
    select 1
    from public.activities a
    where a.id = p_activity_id
  ) then
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
      body,
      client_message_id
    )
    values (
      p_activity_id,
      v_user_id,
      v_body,
      p_client_message_id
    )
    on conflict (sender_id, client_message_id)
      where client_message_id is not null
      do nothing
    returning *
  ),
  resolved_message as (
    select *
    from inserted_message
    union all
    select m.*
    from public.activity_chat_messages m
    where p_client_message_id is not null
      and m.sender_id = v_user_id
      and m.client_message_id = p_client_message_id
      and not exists (select 1 from inserted_message)
    limit 1
  )
  select
    resolved_message.id,
    resolved_message.activity_id,
    resolved_message.sender_id,
    resolved_message.body,
    resolved_message.created_at,
    public.profile_json(resolved_message.sender_id) as sender,
    resolved_message.client_message_id
  from resolved_message;
end;
$$;

grant execute on function public.send_activity_chat_message(uuid, text, uuid)
to authenticated;

create or replace function public.broadcast_activity_chat_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform realtime.send(
    jsonb_build_object(
      'id', new.id,
      'activity_id', new.activity_id,
      'sender_id', new.sender_id,
      'body', new.body,
      'created_at', new.created_at,
      'sender', public.profile_json(new.sender_id),
      'client_message_id', new.client_message_id
    ),
    'message_created',
    'activity-chat:' || new.activity_id::text,
    true
  );
  return new;
end;
$$;

drop trigger if exists activity_chat_messages_broadcast_insert
on public.activity_chat_messages;

create trigger activity_chat_messages_broadcast_insert
after insert on public.activity_chat_messages
for each row execute function public.broadcast_activity_chat_message();

alter table realtime.messages enable row level security;

drop policy if exists "Chat members can receive activity chat broadcasts"
on realtime.messages;

create policy "Chat members can receive activity chat broadcasts"
on realtime.messages
for select
to authenticated
using (
  extension = 'broadcast'
  and public.can_access_activity_chat(
    public.activity_chat_id_from_realtime_topic(realtime.topic()),
    auth.uid()
  )
);

notify pgrst, 'reload schema';
