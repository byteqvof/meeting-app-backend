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

notify pgrst, 'reload schema';
