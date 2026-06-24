create or replace function public.activity_chat_is_open(
  p_activity_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.activities a
    where a.id = p_activity_id
      and a.status = 'published'
      and coalesce(a.ends_at, a.starts_at + interval '2 hours')
        >= now() - interval '1 day'
  );
$$;

grant execute on function public.activity_chat_is_open(uuid)
to authenticated, service_role;

create or replace function public.can_send_activity_chat(
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
    public.can_access_activity_chat(p_activity_id, p_user_id)
    and public.activity_chat_is_open(p_activity_id);
$$;

grant execute on function public.can_send_activity_chat(uuid, uuid)
to authenticated, service_role;

drop policy if exists "Chat members can send activity messages"
on public.activity_chat_messages;

create policy "Chat members can send activity messages"
on public.activity_chat_messages
for insert
to authenticated
with check (
  sender_id = auth.uid()
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

create or replace function public.complete_expired_activities(
  p_grace_interval interval default interval '1 day'
)
returns table (
  activity_id uuid,
  status public.activity_status,
  completed_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  return query
  update public.activities a
  set status = 'completed',
      updated_at = now()
  where a.status = 'published'
    and coalesce(a.ends_at, a.starts_at + interval '2 hours')
      < now() - greatest(coalesce(p_grace_interval, interval '1 day'), interval '0 seconds')
  returning a.id, a.status, a.updated_at;
end;
$$;

grant execute on function public.complete_expired_activities(interval)
to service_role;

create or replace function public.purge_expired_activity_chats(
  p_retention_interval interval default interval '7 days'
)
returns table (
  activity_id uuid,
  deleted_messages integer,
  purged_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  return query
  with expired_activities as (
    select a.id
    from public.activities a
    where (
        a.status = 'completed'
        or coalesce(a.ends_at, a.starts_at + interval '2 hours') < now()
      )
      and coalesce(a.ends_at, a.starts_at + interval '2 hours')
        < now() - greatest(coalesce(p_retention_interval, interval '7 days'), interval '0 seconds')
  ),
  deleted as (
    delete from public.activity_chat_messages m
    using expired_activities ea
    where m.activity_id = ea.id
    returning m.activity_id
  )
  select
    deleted.activity_id,
    count(*)::integer as deleted_messages,
    now() as purged_at
  from deleted
  group by deleted.activity_id;
end;
$$;

grant execute on function public.purge_expired_activity_chats(interval)
to service_role;

notify pgrst, 'reload schema';
