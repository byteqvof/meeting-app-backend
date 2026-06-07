create table if not exists public.activity_chat_reads (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  activity_id uuid not null references public.activities(id) on delete cascade,
  last_read_at timestamptz not null default now(),
  last_read_message_id uuid references public.activity_chat_messages(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (profile_id, activity_id)
);

create index if not exists activity_chat_reads_activity_idx
  on public.activity_chat_reads (activity_id);

drop trigger if exists activity_chat_reads_set_updated_at
on public.activity_chat_reads;

create trigger activity_chat_reads_set_updated_at
before update on public.activity_chat_reads
for each row execute function public.set_updated_at();

alter table public.activity_chat_reads enable row level security;

grant select, insert, update, delete on table public.activity_chat_reads
  to authenticated;
grant select, insert, update, delete on table public.activity_chat_reads
  to service_role;

drop policy if exists "Users can read their own chat reads"
on public.activity_chat_reads;
create policy "Users can read their own chat reads"
on public.activity_chat_reads
for select
to authenticated
using (profile_id = auth.uid());

drop policy if exists "Users can create their own chat reads"
on public.activity_chat_reads;
create policy "Users can create their own chat reads"
on public.activity_chat_reads
for insert
to authenticated
with check (
  profile_id = auth.uid()
  and public.can_access_activity_chat(activity_id, auth.uid())
);

drop policy if exists "Users can update their own chat reads"
on public.activity_chat_reads;
create policy "Users can update their own chat reads"
on public.activity_chat_reads
for update
to authenticated
using (profile_id = auth.uid())
with check (
  profile_id = auth.uid()
  and public.can_access_activity_chat(activity_id, auth.uid())
);

create table if not exists public.device_push_tokens (
  id uuid primary key default extensions.gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  token text not null,
  platform text not null check (platform in ('android', 'ios')),
  device_id text,
  app_version text,
  enabled boolean not null default true,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (token)
);

create index if not exists device_push_tokens_profile_enabled_idx
  on public.device_push_tokens (profile_id, enabled);

drop trigger if exists device_push_tokens_set_updated_at
on public.device_push_tokens;

create trigger device_push_tokens_set_updated_at
before update on public.device_push_tokens
for each row execute function public.set_updated_at();

alter table public.device_push_tokens enable row level security;

grant select, insert, update, delete on table public.device_push_tokens
  to authenticated;
grant select, insert, update, delete on table public.device_push_tokens
  to service_role;

drop policy if exists "Users can manage their own push tokens"
on public.device_push_tokens;
create policy "Users can manage their own push tokens"
on public.device_push_tokens
for all
to authenticated
using (profile_id = auth.uid())
with check (profile_id = auth.uid());

create or replace function public.activity_chat_summary_json(
  p_activity_id uuid,
  p_user_id uuid default auth.uid()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_last public.activity_chat_messages%rowtype;
  v_read public.activity_chat_reads%rowtype;
  v_unread_count integer := 0;
begin
  if p_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not public.can_access_activity_chat(p_activity_id, p_user_id) then
    raise exception 'ACTIVITY_CHAT_FORBIDDEN';
  end if;

  select *
  into v_last
  from public.activity_chat_messages
  where activity_id = p_activity_id
  order by created_at desc, id desc
  limit 1;

  select *
  into v_read
  from public.activity_chat_reads
  where activity_id = p_activity_id
    and profile_id = p_user_id;

  select count(*)::integer
  into v_unread_count
  from public.activity_chat_messages m
  where m.activity_id = p_activity_id
    and m.sender_id <> p_user_id
    and (
      v_read.profile_id is null
      or m.created_at > v_read.last_read_at
    );

  return jsonb_build_object(
    'last_message_id', v_last.id,
    'last_message', v_last.body,
    'last_message_at', v_last.created_at,
    'last_sender_id', v_last.sender_id,
    'last_sender', case
      when v_last.sender_id is null then null
      else public.profile_json(v_last.sender_id)
    end,
    'unread_count', coalesce(v_unread_count, 0)
  );
end;
$$;

grant execute on function public.activity_chat_summary_json(uuid, uuid)
  to authenticated, service_role;

create or replace function public.mark_activity_chat_read(
  p_activity_id uuid,
  p_message_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_message public.activity_chat_messages%rowtype;
  v_read_at timestamptz := now();
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not public.can_access_activity_chat(p_activity_id, v_user_id) then
    raise exception 'ACTIVITY_CHAT_FORBIDDEN';
  end if;

  if p_message_id is not null then
    select *
    into v_message
    from public.activity_chat_messages
    where id = p_message_id
      and activity_id = p_activity_id;

    if v_message.id is null then
      raise exception 'CHAT_MESSAGE_NOT_FOUND';
    end if;
  else
    select *
    into v_message
    from public.activity_chat_messages
    where activity_id = p_activity_id
    order by created_at desc, id desc
    limit 1;
  end if;

  if v_message.id is not null then
    v_read_at := v_message.created_at;
  end if;

  insert into public.activity_chat_reads (
    profile_id,
    activity_id,
    last_read_at,
    last_read_message_id
  )
  values (
    v_user_id,
    p_activity_id,
    v_read_at,
    v_message.id
  )
  on conflict (profile_id, activity_id)
  do update set
    last_read_at = greatest(
      public.activity_chat_reads.last_read_at,
      excluded.last_read_at
    ),
    last_read_message_id = case
      when excluded.last_read_at >= public.activity_chat_reads.last_read_at
      then excluded.last_read_message_id
      else public.activity_chat_reads.last_read_message_id
    end;

  return public.activity_chat_summary_json(p_activity_id, v_user_id);
end;
$$;

grant execute on function public.mark_activity_chat_read(uuid, uuid)
  to authenticated;
