alter table public.activity_chat_messages
add column if not exists message_type text not null default 'user';

alter table public.activity_chat_messages
drop constraint if exists activity_chat_messages_message_type_check;

alter table public.activity_chat_messages
add constraint activity_chat_messages_message_type_check
check (message_type in ('user', 'system'));

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
        and not public.has_user_block(p_user_id, a.organizer_id)
        and (
          a.organizer_id = p_user_id
          or exists (
            select 1
            from public.activity_participants ap
            where ap.activity_id = a.id
              and ap.profile_id = p_user_id
              and ap.status in ('joined', 'pending', 'cancelled')
          )
        )
    );
$$;

grant execute on function public.can_access_activity_chat(uuid, uuid)
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
    p_user_id is not null
    and exists (
      select 1
      from public.activities a
      where a.id = p_activity_id
        and not public.has_user_block(p_user_id, a.organizer_id)
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
  and message_type = 'user'
  and public.can_send_activity_chat(activity_id, auth.uid())
);

drop function if exists public.list_activity_chat_messages(
  uuid,
  integer,
  timestamptz,
  timestamptz,
  uuid
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
  client_message_id uuid,
  message_type text
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
      m.client_message_id,
      m.message_type
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
    scoped_messages.client_message_id,
    scoped_messages.message_type
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
  message_type text
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

  if not public.can_send_activity_chat(p_activity_id, v_user_id) then
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
    select inserted_message.*
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
    resolved_message.client_message_id,
    resolved_message.message_type
  from resolved_message;
end;
$$;

grant execute on function public.send_activity_chat_message(uuid, text, uuid)
to authenticated;

create or replace function public.set_activity_participation(
  p_activity_id uuid,
  p_join boolean default true
)
returns table (
  activity_id uuid,
  is_joined boolean,
  participants jsonb,
  participants_count integer,
  available_spots integer,
  participation_status text
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_activity record;
  v_joined_count integer;
  v_trust record;
  v_profile record;
  v_previous_status public.activity_participant_status;
  v_next_status public.activity_participant_status := 'joined'::public.activity_participant_status;
  v_display_name text;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select
    a.id,
    a.organizer_id,
    a.max_participants,
    a.status,
    a.starts_at,
    a.group_type,
    a.min_reputation_level,
    a.requires_identity_verified,
    a.target_age_bands,
    a.target_genders
  into v_activity
  from public.activities a
  where a.id = p_activity_id
  for update;

  if not found then
    raise exception 'ACTIVITY_NOT_FOUND';
  end if;

  if not coalesce(p_join, true) then
    select ap.status
    into v_previous_status
    from public.activity_participants ap
    where ap.activity_id = p_activity_id
      and ap.profile_id = v_user_id;

    update public.activity_participants ap
    set status = 'cancelled',
        updated_at = now()
    where ap.activity_id = p_activity_id
      and ap.profile_id = v_user_id;

    if v_previous_status in ('joined', 'pending') then
      select coalesce(nullif(btrim(p.display_name), ''), 'Iemand')
      into v_display_name
      from public.profiles p
      where p.id = v_user_id;

      insert into public.activity_chat_messages (
        activity_id,
        sender_id,
        body,
        message_type
      )
      values (
        p_activity_id,
        v_user_id,
        coalesce(v_display_name, 'Iemand') || ' heeft zich afgemeld',
        'system'
      );
    end if;

    update public.profiles p
    set activities_joined_count = (
      select count(*)::integer
      from public.activity_participants ap
      where ap.profile_id = v_user_id
        and ap.status = 'joined'
    )
    where p.id = v_user_id;

    if exists (select 1 from public.profiles p where p.id = v_user_id) then
      perform public.recalculate_profile_trust(v_user_id);
    end if;

    return query
    select
      p_activity_id,
      snapshot.is_joined,
      snapshot.participants,
      snapshot.participants_count,
      snapshot.available_spots,
      coalesce((
        select ap.status::text
        from public.activity_participants ap
        where ap.activity_id = p_activity_id
          and ap.profile_id = v_user_id
      ), 'cancelled') as participation_status
    from public.activity_participation_snapshot(p_activity_id) snapshot;

    return;
  end if;

  select p.age_band, p.gender
  into v_profile
  from public.profiles p
  where p.id = v_user_id;

  if not found then
    raise exception 'PROFILE_REQUIRED';
  end if;

  select *
  into v_trust
  from public.profile_trust t
  where t.profile_id = v_user_id;

  if not coalesce(v_trust.phone_verified, false) then
    raise exception 'PROFILE_PHONE_REQUIRED';
  end if;

  if v_activity.organizer_id = v_user_id then
    raise exception 'ACTIVITY_OWNER_CANNOT_JOIN';
  end if;

  if public.has_user_block(v_user_id, v_activity.organizer_id) then
    raise exception 'ACTIVITY_BLOCKED';
  end if;

  if v_activity.status <> 'published' or v_activity.starts_at < now() then
    raise exception 'ACTIVITY_UNAVAILABLE';
  end if;

  if v_activity.group_type = 'closed' then
    raise exception 'ACTIVITY_CLOSED';
  end if;

  if v_activity.requires_identity_verified
    and coalesce(v_trust.identity_status, 'unverified') <> 'verified'
  then
    raise exception 'ACTIVITY_IDENTITY_REQUIRED';
  end if;

  if public.reputation_rank(coalesce(v_trust.reputation_level, 'new_member'))
    < public.reputation_rank(coalesce(v_activity.min_reputation_level, 'new_member'))
  then
    raise exception 'ACTIVITY_REPUTATION_TOO_LOW';
  end if;

  if cardinality(coalesce(v_activity.target_age_bands, '{}'::text[])) > 0
    and (
      v_profile.age_band is null
      or not (v_profile.age_band = any(v_activity.target_age_bands))
    )
  then
    raise exception 'ACTIVITY_TARGET_MISMATCH';
  end if;

  if cardinality(coalesce(v_activity.target_genders, '{}'::text[])) > 0
    and (
      v_profile.gender is null
      or not (v_profile.gender = any(v_activity.target_genders))
    )
  then
    raise exception 'ACTIVITY_TARGET_MISMATCH';
  end if;

  select count(*)::integer
  into v_joined_count
  from public.activity_participants ap
  where ap.activity_id = p_activity_id
    and ap.status = 'joined';

  if not exists (
      select 1
      from public.activity_participants ap
      where ap.activity_id = p_activity_id
        and ap.profile_id = v_user_id
        and ap.status = 'joined'
    )
    and v_activity.max_participants is not null
    and v_joined_count >= v_activity.max_participants
  then
    raise exception 'ACTIVITY_FULL';
  end if;

  v_next_status := case
    when v_activity.group_type = 'approval' then 'pending'::public.activity_participant_status
    else 'joined'::public.activity_participant_status
  end;

  insert into public.activity_participants as ap (
    activity_id,
    profile_id,
    status,
    joined_at
  )
  values (
    p_activity_id,
    v_user_id,
    v_next_status,
    now()
  )
  on conflict on constraint activity_participants_pkey
  do update set
    status = v_next_status,
    joined_at = case
      when ap.status = v_next_status then ap.joined_at
      else now()
    end,
    updated_at = now();

  update public.profiles p
  set activities_joined_count = (
    select count(*)::integer
    from public.activity_participants ap
    where ap.profile_id = v_user_id
      and ap.status = 'joined'
  )
  where p.id = v_user_id;

  perform public.recalculate_profile_trust(v_user_id);

  return query
  select
    p_activity_id,
    snapshot.is_joined,
    snapshot.participants,
    snapshot.participants_count,
    snapshot.available_spots,
    coalesce((
      select ap.status::text
      from public.activity_participants ap
      where ap.activity_id = p_activity_id
        and ap.profile_id = v_user_id
    ), 'cancelled') as participation_status
  from public.activity_participation_snapshot(p_activity_id) snapshot;
end;
$$;

grant execute on function public.set_activity_participation(uuid, boolean)
to authenticated;

drop function if exists public.list_joined_activities_for_user(uuid, integer);

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
  available_spots integer,
  group_type text,
  min_reputation_level text,
  requires_identity_verified boolean,
  is_private_location boolean,
  target_age_bands text[],
  target_genders text[],
  participation_status text,
  can_send_chat boolean
)
language sql
stable
security definer
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
    ap.status = 'joined' as is_joined,
    coalesce(participation.available_spots, 0) as available_spots,
    a.group_type,
    a.min_reputation_level,
    a.requires_identity_verified,
    a.is_private_location,
    a.target_age_bands,
    a.target_genders,
    ap.status::text as participation_status,
    public.can_send_activity_chat(a.id, target_user.id) as can_send_chat
  from target_user
  join public.activity_participants ap
    on ap.profile_id = target_user.id
   and ap.status in ('joined', 'cancelled')
  join public.activities a on a.id = ap.activity_id
  join public.activity_categories c on c.id = a.category_id
  left join lateral public.activity_participation_snapshot(a.id) participation on true
  where target_user.id = auth.uid()
    and a.status = 'published'
    and (
      a.starts_at >= now()
      or exists (
        select 1
        from public.activity_chat_messages m
        where m.activity_id = a.id
      )
    )
  order by
    case when ap.status = 'joined' then 0 else 1 end,
    a.starts_at asc,
    ap.joined_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 200);
$$;

grant execute on function public.list_joined_activities_for_user(uuid, integer)
to authenticated;

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
    'last_message_type', v_last.message_type,
    'unread_count', coalesce(v_unread_count, 0),
    'can_send_chat', public.can_send_activity_chat(p_activity_id, p_user_id)
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
      'client_message_id', new.client_message_id,
      'message_type', new.message_type
    ),
    'message_created',
    'activity-chat:' || new.activity_id::text,
    true
  );
  return new;
end;
$$;

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
