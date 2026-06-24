drop policy if exists "Chat members can send activity messages"
on public.activity_chat_messages;

create policy "Chat members can send activity messages"
on public.activity_chat_messages
for insert
to authenticated
with check (
  sender_id = auth.uid()
  and message_type = 'user'
  and public.can_send_activity_chat(activity_id, auth.uid())
);

drop function if exists public.send_activity_chat_message(uuid, text, uuid);

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
  client_message_id uuid,
  message_type text,
  was_inserted boolean
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

  if not public.activity_chat_is_open(p_activity_id) then
    raise exception 'ACTIVITY_CHAT_CLOSED';
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
      client_message_id,
      message_type
    )
    values (
      p_activity_id,
      v_user_id,
      v_body,
      p_client_message_id,
      'user'
    )
    on conflict on constraint activity_chat_messages_sender_client_message_key
    do nothing
    returning *
  ),
  resolved_message as (
    select
      inserted_message.id,
      inserted_message.activity_id,
      inserted_message.sender_id,
      inserted_message.body,
      inserted_message.created_at,
      inserted_message.client_message_id,
      inserted_message.message_type,
      true as was_inserted
    from inserted_message
    union all
    select
      m.id,
      m.activity_id,
      m.sender_id,
      m.body,
      m.created_at,
      m.client_message_id,
      m.message_type,
      false as was_inserted
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
    resolved_message.client_message_id,
    resolved_message.message_type,
    resolved_message.was_inserted
  from resolved_message;
end;
$$;

grant execute on function public.send_activity_chat_message(uuid, text, uuid)
to authenticated;

notify pgrst, 'reload schema';
