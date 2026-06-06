create table if not exists public.profile_trust (
  profile_id uuid primary key references auth.users(id) on delete cascade,
  phone_verified boolean not null default false,
  phone_verified_at timestamptz,
  identity_status text not null default 'unverified' check (
    identity_status in ('unverified', 'pending', 'verified', 'rejected', 'expired')
  ),
  identity_method text check (
    identity_method is null
    or identity_method in ('idin', 'itsme', 'eudi_wallet', 'veriff', 'sumsub', 'onfido', 'manual')
  ),
  identity_completed_at timestamptz,
  age_verified boolean not null default false,
  reputation_level text not null default 'new_member' check (
    reputation_level in ('new_member', 'active_member', 'known_member', 'top_participant')
  ),
  reputation_score integer not null default 0 check (reputation_score between 0 and 100),
  last_calculated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists profile_trust_phone_verified_idx
  on public.profile_trust (phone_verified);

create index if not exists profile_trust_identity_status_idx
  on public.profile_trust (identity_status);

drop trigger if exists profile_trust_set_updated_at on public.profile_trust;
create trigger profile_trust_set_updated_at
before update on public.profile_trust
for each row execute function public.set_updated_at();

alter table public.profile_trust enable row level security;
grant select on table public.profile_trust to authenticated;

drop policy if exists "Authenticated users can read profile trust" on public.profile_trust;
create policy "Authenticated users can read profile trust"
on public.profile_trust
for select
to authenticated
using (true);

drop policy if exists "Users can update their own phone trust" on public.profile_trust;

insert into public.profile_trust (profile_id)
select p.id
from public.profiles p
left join public.profile_trust t on t.profile_id = p.id
where t.profile_id is null;

create or replace function public.ensure_profile_trust()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profile_trust (profile_id)
  values (new.id)
  on conflict (profile_id) do nothing;
  return new;
end;
$$;

drop trigger if exists profiles_ensure_profile_trust on public.profiles;
create trigger profiles_ensure_profile_trust
after insert on public.profiles
for each row execute function public.ensure_profile_trust();

create table if not exists public.identity_verifications (
  id uuid primary key default extensions.gen_random_uuid(),
  profile_id uuid not null references auth.users(id) on delete cascade,
  provider text not null check (
    provider in ('idin', 'itsme', 'eudi_wallet', 'veriff', 'sumsub', 'onfido', 'manual')
  ),
  provider_reference text,
  status text not null default 'pending' check (
    status in ('pending', 'verified', 'rejected', 'expired', 'cancelled')
  ),
  name_verified boolean not null default false,
  age_verified boolean not null default false,
  completed_at timestamptz,
  raw_result jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint identity_verifications_provider_reference_unique
    unique (provider, provider_reference)
);

create index if not exists identity_verifications_profile_created_idx
  on public.identity_verifications (profile_id, created_at desc);

drop trigger if exists identity_verifications_set_updated_at on public.identity_verifications;
create trigger identity_verifications_set_updated_at
before update on public.identity_verifications
for each row execute function public.set_updated_at();

alter table public.identity_verifications enable row level security;
grant select on table public.identity_verifications to authenticated;

drop policy if exists "Users can read their own identity verifications"
on public.identity_verifications;
create policy "Users can read their own identity verifications"
on public.identity_verifications
for select
to authenticated
using (profile_id = auth.uid());

create table if not exists public.activity_attendance (
  activity_id uuid not null references public.activities(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  status text not null check (status in ('present', 'absent')),
  marked_by uuid not null references public.profiles(id) on delete cascade,
  marked_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (activity_id, profile_id)
);

create index if not exists activity_attendance_profile_idx
  on public.activity_attendance (profile_id, status);

drop trigger if exists activity_attendance_set_updated_at on public.activity_attendance;
create trigger activity_attendance_set_updated_at
before update on public.activity_attendance
for each row execute function public.set_updated_at();

alter table public.activity_attendance enable row level security;
grant select on table public.activity_attendance to authenticated;

drop policy if exists "Activity members can read attendance" on public.activity_attendance;
create policy "Activity members can read attendance"
on public.activity_attendance
for select
to authenticated
using (
  profile_id = auth.uid()
  or exists (
    select 1
    from public.activities a
    where a.id = activity_id
      and a.organizer_id = auth.uid()
  )
);

create table if not exists public.moderation_actions (
  id uuid primary key default extensions.gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  moderator_id uuid references public.profiles(id) on delete set null,
  report_id uuid references public.content_reports(id) on delete set null,
  action_type text not null check (
    action_type in ('note', 'warning', 'temporary_suspension', 'ban', 'report_dismissed')
  ),
  reason text not null default '' check (char_length(reason) <= 500),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists moderation_actions_profile_created_idx
  on public.moderation_actions (profile_id, created_at desc);

drop trigger if exists moderation_actions_set_updated_at on public.moderation_actions;
create trigger moderation_actions_set_updated_at
before update on public.moderation_actions
for each row execute function public.set_updated_at();

alter table public.moderation_actions enable row level security;
grant select on table public.moderation_actions to authenticated;

create or replace function public.is_moderator(p_user_id uuid default auth.uid())
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce(
    (auth.jwt() -> 'app_metadata' ->> 'role') in ('admin', 'moderator'),
    false
  )
  and p_user_id = auth.uid();
$$;

grant execute on function public.is_moderator(uuid) to authenticated;

drop policy if exists "Moderators can read moderation actions" on public.moderation_actions;
create policy "Moderators can read moderation actions"
on public.moderation_actions
for select
to authenticated
using (public.is_moderator(auth.uid()));

alter table public.content_reports
add column if not exists reason_category text not null default 'other';

alter table public.content_reports
drop constraint if exists content_reports_reason_category_check;

alter table public.content_reports
add constraint content_reports_reason_category_check
check (
  reason_category in (
    'inappropriate_behavior',
    'harassment',
    'fake_account',
    'spam',
    'other'
  )
);

create index if not exists content_reports_status_created_idx
  on public.content_reports (status, created_at desc);

drop policy if exists "Moderators can read reports" on public.content_reports;
create policy "Moderators can read reports"
on public.content_reports
for select
to authenticated
using (public.is_moderator(auth.uid()));

alter table public.activities
add column if not exists group_type text not null default 'open';

alter table public.activities
drop constraint if exists activities_group_type_check;

alter table public.activities
add constraint activities_group_type_check
check (group_type in ('open', 'approval', 'closed'));

alter table public.activities
add column if not exists min_reputation_level text not null default 'new_member';

alter table public.activities
drop constraint if exists activities_min_reputation_level_check;

alter table public.activities
add constraint activities_min_reputation_level_check
check (
  min_reputation_level in ('new_member', 'active_member', 'known_member', 'top_participant')
);

alter table public.activities
add column if not exists requires_identity_verified boolean not null default false;

alter table public.activities
add column if not exists is_private_location boolean not null default false;

create or replace function public.reputation_rank(p_level text)
returns integer
language sql
immutable
as $$
  select case coalesce(p_level, 'new_member')
    when 'top_participant' then 4
    when 'known_member' then 3
    when 'active_member' then 2
    else 1
  end;
$$;

create or replace function public.reputation_level_for_score(p_score integer)
returns text
language sql
immutable
as $$
  select case
    when coalesce(p_score, 0) >= 85 then 'top_participant'
    when coalesce(p_score, 0) >= 60 then 'known_member'
    when coalesce(p_score, 0) >= 30 then 'active_member'
    else 'new_member'
  end;
$$;

create or replace function public.has_user_block(
  p_left_profile_id uuid,
  p_right_profile_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    p_left_profile_id is not null
    and p_right_profile_id is not null
    and exists (
      select 1
      from public.user_blocks b
      where (
          b.blocker_id = p_left_profile_id
          and b.blocked_profile_id = p_right_profile_id
        )
        or (
          b.blocker_id = p_right_profile_id
          and b.blocked_profile_id = p_left_profile_id
        )
    );
$$;

grant execute on function public.has_user_block(uuid, uuid) to authenticated;

create or replace function public.profile_json(p_profile_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_profile_id is null then null::jsonb
    when auth.uid() is not null and public.has_user_block(auth.uid(), p_profile_id) then null::jsonb
    else jsonb_build_object(
      'id', p.id,
      'display_name', p.display_name,
      'initials', p.initials,
      'city_name', p.city_name,
      'member_since', p.member_since,
      'avatar_url', p.avatar_url,
      'attendance_score', p.attendance_score,
      'activities_joined_count', p.activities_joined_count,
      'activities_hosted_count', p.activities_hosted_count,
      'rating', p.rating,
      'is_verified', coalesce(t.identity_status = 'verified', false),
      'is_premium', p.is_premium,
      'trust', jsonb_build_object(
        'phone_verified', coalesce(t.phone_verified, false),
        'phone_verified_at', t.phone_verified_at,
        'identity_status', coalesce(t.identity_status, 'unverified'),
        'identity_method', t.identity_method,
        'identity_completed_at', t.identity_completed_at,
        'age_verified', coalesce(t.age_verified, false),
        'reputation_level', coalesce(t.reputation_level, 'new_member'),
        'reputation_score', coalesce(t.reputation_score, 0)
      ),
      'interests', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'id', c.id,
            'label', c.title,
            'icon_key', c.icon_key,
            'foreground_color', c.foreground_color,
            'background_color', c.background_color
          )
          order by c.sort_order, c.title
        )
        from public.profile_category_links pcl
        join public.activity_categories c on c.id = pcl.category_id
        where pcl.profile_id = p.id
      ), '[]'::jsonb)
    )
  end
  from public.profiles p
  left join public.profile_trust t on t.profile_id = p.id
  where p.id = p_profile_id;
$$;

grant execute on function public.profile_json(uuid) to authenticated;

create or replace function public.sync_current_user_trust()
returns table (
  profile_id uuid,
  phone_verified boolean,
  phone_verified_at timestamptz,
  identity_status text,
  identity_method text,
  identity_completed_at timestamptz,
  age_verified boolean,
  reputation_level text,
  reputation_score integer
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_phone_confirmed_at timestamptz;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select u.phone_confirmed_at
  into v_phone_confirmed_at
  from auth.users u
  where u.id = v_user_id;

  insert into public.profile_trust (
    profile_id,
    phone_verified,
    phone_verified_at
  )
  values (
    v_user_id,
    v_phone_confirmed_at is not null,
    v_phone_confirmed_at
  )
  on conflict (profile_id)
  do update set
    phone_verified = excluded.phone_verified,
    phone_verified_at = excluded.phone_verified_at,
    updated_at = now();

  return query
  select
    t.profile_id,
    t.phone_verified,
    t.phone_verified_at,
    t.identity_status,
    t.identity_method,
    t.identity_completed_at,
    t.age_verified,
    t.reputation_level,
    t.reputation_score
  from public.profile_trust t
  where t.profile_id = v_user_id;
end;
$$;

grant execute on function public.sync_current_user_trust() to authenticated;

create or replace function public.recalculate_profile_trust(p_profile_id uuid)
returns table (
  profile_id uuid,
  reputation_level text,
  reputation_score integer
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_account_days integer := 0;
  v_completed_joined integer := 0;
  v_completed_hosted integer := 0;
  v_present_count integer := 0;
  v_absent_count integer := 0;
  v_avg_rating numeric := 0;
  v_moderation_penalty integer := 0;
  v_score integer := 0;
  v_level text := 'new_member';
begin
  if p_profile_id is null then
    raise exception 'PROFILE_REQUIRED';
  end if;

  select greatest(0, floor(extract(epoch from now() - p.member_since) / 86400)::integer)
  into v_account_days
  from public.profiles p
  where p.id = p_profile_id;

  if not found then
    raise exception 'PROFILE_REQUIRED';
  end if;

  select count(*)::integer
  into v_completed_joined
  from public.activity_participants ap
  join public.activities a on a.id = ap.activity_id
  where ap.profile_id = p_profile_id
    and ap.status = 'joined'
    and a.status = 'completed';

  select count(*)::integer
  into v_completed_hosted
  from public.activities a
  where a.organizer_id = p_profile_id
    and a.status = 'completed';

  select
    count(*) filter (where aa.status = 'present')::integer,
    count(*) filter (where aa.status = 'absent')::integer
  into v_present_count, v_absent_count
  from public.activity_attendance aa
  where aa.profile_id = p_profile_id;

  select coalesce(avg(af.rating), 0)
  into v_avg_rating
  from public.activity_feedback af
  where af.target_profile_id = p_profile_id;

  select (count(*) * 20)::integer
  into v_moderation_penalty
  from public.moderation_actions ma
  where ma.profile_id = p_profile_id
    and ma.action_type in ('warning', 'temporary_suspension', 'ban');

  v_score :=
    least(v_account_days / 14, 20)
    + least(v_completed_joined * 5, 20)
    + least(v_completed_hosted * 7, 20)
    + least(v_present_count * 4, 20)
    + case
        when v_avg_rating >= 4.5 then 20
        when v_avg_rating >= 4 then 15
        when v_avg_rating >= 3 then 8
        else 0
      end
    - least(v_absent_count * 8, 30)
    - least(v_moderation_penalty, 60);

  v_score := least(greatest(v_score, 0), 100);
  v_level := public.reputation_level_for_score(v_score);

  insert into public.profile_trust (
    profile_id,
    reputation_level,
    reputation_score,
    last_calculated_at
  )
  values (
    p_profile_id,
    v_level,
    v_score,
    now()
  )
  on conflict (profile_id)
  do update set
    reputation_level = excluded.reputation_level,
    reputation_score = excluded.reputation_score,
    last_calculated_at = now(),
    updated_at = now();

  return query select p_profile_id, v_level, v_score;
end;
$$;

grant execute on function public.recalculate_profile_trust(uuid) to authenticated;

create or replace function public.mark_activity_attendance(
  p_activity_id uuid,
  p_profile_id uuid,
  p_status text
)
returns table (
  activity_id uuid,
  profile_id uuid,
  status text,
  marked_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_status text := btrim(coalesce(p_status, ''));
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if v_status not in ('present', 'absent') then
    raise exception 'ATTENDANCE_STATUS_INVALID';
  end if;

  if not exists (
    select 1
    from public.activities a
    where a.id = p_activity_id
      and a.organizer_id = v_user_id
      and a.status = 'completed'
  ) then
    raise exception 'ATTENDANCE_FORBIDDEN';
  end if;

  if not exists (
    select 1
    from public.activities a
    where a.id = p_activity_id
      and (
        a.organizer_id = p_profile_id
        or exists (
          select 1
          from public.activity_participants ap
          where ap.activity_id = a.id
            and ap.profile_id = p_profile_id
            and ap.status = 'joined'
        )
      )
  ) then
    raise exception 'ATTENDANCE_TARGET_INVALID';
  end if;

  return query
  with attendance as (
    insert into public.activity_attendance (
      activity_id,
      profile_id,
      status,
      marked_by,
      marked_at
    )
    values (
      p_activity_id,
      p_profile_id,
      v_status,
      v_user_id,
      now()
    )
    on conflict (activity_id, profile_id)
    do update set
      status = excluded.status,
      marked_by = excluded.marked_by,
      marked_at = now(),
      updated_at = now()
    returning *
  ),
  recalculated as (
    select * from public.recalculate_profile_trust(p_profile_id)
  )
  select
    attendance.activity_id,
    attendance.profile_id,
    attendance.status,
    attendance.marked_at
  from attendance;
end;
$$;

grant execute on function public.mark_activity_attendance(uuid, uuid, text)
to authenticated;

create or replace function public.activity_participation_snapshot(
  p_activity_id uuid
)
returns table (
  participants jsonb,
  participants_count integer,
  is_joined boolean,
  available_spots integer
)
language sql
stable
security definer
set search_path = public
as $$
  with activity as (
    select id, max_participants
    from public.activities
    where id = p_activity_id
  ),
  joined_participants as (
    select ap.profile_id, ap.joined_at
    from public.activity_participants ap
    where ap.activity_id = p_activity_id
      and ap.status = 'joined'
      and not public.has_user_block(auth.uid(), ap.profile_id)
  ),
  counts as (
    select count(*)::integer as participants_count
    from public.activity_participants ap
    where ap.activity_id = p_activity_id
      and ap.status = 'joined'
  )
  select
    coalesce((
      select jsonb_agg(public.profile_json(jp.profile_id) order by jp.joined_at)
      from joined_participants jp
      where jp.profile_id <> auth.uid()
        and public.profile_json(jp.profile_id) is not null
    ), '[]'::jsonb) as participants,
    counts.participants_count,
    exists (
      select 1
      from public.activity_participants ap
      where ap.activity_id = p_activity_id
        and ap.profile_id = auth.uid()
        and ap.status = 'joined'
    ) as is_joined,
    case
      when activity.max_participants is null then 0
      else greatest(activity.max_participants - counts.participants_count, 0)
    end::integer as available_spots
  from activity
  cross join counts;
$$;

grant execute on function public.activity_participation_snapshot(uuid)
to authenticated;

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
              and ap.status = 'joined'
          )
        )
    );
$$;

grant execute on function public.can_access_activity_chat(uuid, uuid)
to authenticated;

drop function if exists public.set_activity_participation(uuid, boolean);

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
  v_next_status public.activity_participant_status := 'joined';
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (select 1 from public.profiles where id = v_user_id) then
    raise exception 'PROFILE_REQUIRED';
  end if;

  select *
  into v_trust
  from public.profile_trust t
  where t.profile_id = v_user_id;

  if not coalesce(v_trust.phone_verified, false) then
    raise exception 'PROFILE_PHONE_REQUIRED';
  end if;

  select
    a.id,
    a.organizer_id,
    a.max_participants,
    a.status,
    a.starts_at,
    a.group_type,
    a.min_reputation_level,
    a.requires_identity_verified
  into v_activity
  from public.activities a
  where a.id = p_activity_id
  for update;

  if not found then
    raise exception 'ACTIVITY_NOT_FOUND';
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

  if coalesce(p_join, true) then
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
  else
    update public.activity_participants ap
    set status = 'cancelled',
        updated_at = now()
    where ap.activity_id = p_activity_id
      and ap.profile_id = v_user_id;
  end if;

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

drop function if exists public.search_activities_nearby(
  double precision,
  double precision,
  double precision,
  uuid,
  integer
);

create or replace function public.search_activities_nearby(
  p_latitude double precision,
  p_longitude double precision,
  p_radius_km double precision default 10,
  p_category_id uuid default null,
  p_limit integer default 50
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
  is_private_location boolean
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  with origin as (
    select st_setsrid(st_makepoint(p_longitude, p_latitude), 4326)::geography as point
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
    round((st_distance(a.location, origin.point) / 1000)::numeric, 2)::double precision as distance_km,
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
    coalesce(participation.is_joined, false) as is_joined,
    coalesce(participation.available_spots, 0) as available_spots,
    a.group_type,
    a.min_reputation_level,
    a.requires_identity_verified,
    a.is_private_location
  from public.activities a
  join public.activity_categories c on c.id = a.category_id
  cross join origin
  left join lateral public.activity_participation_snapshot(a.id) participation on true
  where c.is_active
    and a.status = 'published'
    and a.starts_at >= now()
    and a.organizer_id <> auth.uid()
    and not public.has_user_block(auth.uid(), a.organizer_id)
    and (p_category_id is null or a.category_id = p_category_id)
    and st_dwithin(
      a.location,
      origin.point,
      least(greatest(coalesce(p_radius_km, 10), 0.1), 100) * 1000
    )
  order by st_distance(a.location, origin.point), a.starts_at
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
$$;

grant execute on function public.search_activities_nearby(
  double precision,
  double precision,
  double precision,
  uuid,
  integer
) to authenticated;

drop function if exists public.list_activities_for_user(
  uuid,
  public.activity_status,
  integer
);

create or replace function public.list_activities_for_user(
  p_user_id uuid default null,
  p_status public.activity_status default null,
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
  is_private_location boolean
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
    coalesce(participation.is_joined, false) as is_joined,
    coalesce(participation.available_spots, 0) as available_spots,
    a.group_type,
    a.min_reputation_level,
    a.requires_identity_verified,
    a.is_private_location
  from target_user
  join public.activities a on a.organizer_id = target_user.id
  join public.activity_categories c on c.id = a.category_id
  left join lateral public.activity_participation_snapshot(a.id) participation on true
  where (
      target_user.id = auth.uid()
      or (
        a.status = 'published'
        and a.starts_at >= now()
        and not public.has_user_block(auth.uid(), a.organizer_id)
      )
    )
    and (
      p_status is null
      or (
        target_user.id = auth.uid()
        and a.status = p_status
      )
      or (
        target_user.id <> auth.uid()
        and p_status = 'published'
        and a.status = 'published'
      )
    )
  order by a.starts_at desc, a.created_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 200);
$$;

grant execute on function public.list_activities_for_user(
  uuid,
  public.activity_status,
  integer
) to authenticated;

create or replace function public.submit_content_report(
  p_target_type text,
  p_target_id uuid,
  p_reason text,
  p_details text default ''
)
returns table (
  id uuid,
  target_type text,
  target_id uuid,
  status text,
  created_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_target_type text := btrim(coalesce(p_target_type, ''));
  v_reason text := btrim(coalesce(p_reason, ''));
  v_details text := btrim(coalesce(p_details, ''));
  v_reason_category text;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if v_target_type not in ('profile', 'activity', 'chat_message') then
    raise exception 'SAFETY_TARGET_INVALID';
  end if;

  v_reason_category := case
    when v_reason in (
      'inappropriate_behavior',
      'harassment',
      'fake_account',
      'spam',
      'other'
    ) then v_reason
    else 'other'
  end;

  if char_length(v_reason) < 3 or char_length(v_reason) > 80 then
    raise exception 'SAFETY_REASON_INVALID';
  end if;

  if char_length(v_details) > 1000 then
    raise exception 'SAFETY_DETAILS_INVALID';
  end if;

  if v_target_type = 'profile' and not exists (
    select 1 from public.profiles p where p.id = p_target_id
  ) then
    raise exception 'SAFETY_TARGET_NOT_FOUND';
  end if;

  if v_target_type = 'activity' and not exists (
    select 1 from public.activities a where a.id = p_target_id
  ) then
    raise exception 'SAFETY_TARGET_NOT_FOUND';
  end if;

  if v_target_type = 'chat_message' and not exists (
    select 1
    from public.activity_chat_messages m
    where m.id = p_target_id
      and public.can_access_activity_chat(m.activity_id, v_user_id)
  ) then
    raise exception 'SAFETY_TARGET_NOT_FOUND';
  end if;

  return query
  insert into public.content_reports (
    reporter_id,
    target_type,
    target_id,
    reason,
    reason_category,
    details
  )
  values (
    v_user_id,
    v_target_type,
    p_target_id,
    v_reason,
    v_reason_category,
    v_details
  )
  returning
    content_reports.id,
    content_reports.target_type,
    content_reports.target_id,
    content_reports.status,
    content_reports.created_at;
end;
$$;

grant execute on function public.submit_content_report(
  text,
  uuid,
  text,
  text
) to authenticated;

create or replace function public.list_moderation_reports(
  p_status text default 'open',
  p_limit integer default 100
)
returns table (
  id uuid,
  reporter_id uuid,
  target_type text,
  target_id uuid,
  reason text,
  reason_category text,
  details text,
  status text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_status text := nullif(btrim(coalesce(p_status, '')), '');
begin
  if not public.is_moderator(auth.uid()) then
    raise exception 'MODERATION_FORBIDDEN';
  end if;

  return query
  select
    r.id,
    r.reporter_id,
    r.target_type,
    r.target_id,
    r.reason,
    r.reason_category,
    r.details,
    r.status,
    r.created_at,
    r.updated_at
  from public.content_reports r
  where v_status is null or r.status = v_status
  order by r.created_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 200);
end;
$$;

grant execute on function public.list_moderation_reports(text, integer)
to authenticated;

create or replace function public.resolve_moderation_report(
  p_report_id uuid,
  p_status text,
  p_action_type text default null,
  p_reason text default ''
)
returns table (
  report_id uuid,
  status text
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_status text := btrim(coalesce(p_status, ''));
  v_action_type text := nullif(btrim(coalesce(p_action_type, '')), '');
  v_report record;
  v_target_profile_id uuid;
begin
  if not public.is_moderator(v_user_id) then
    raise exception 'MODERATION_FORBIDDEN';
  end if;

  if v_status not in ('open', 'reviewing', 'resolved', 'dismissed') then
    raise exception 'MODERATION_STATUS_INVALID';
  end if;

  select *
  into v_report
  from public.content_reports
  where id = p_report_id
  for update;

  if not found then
    raise exception 'MODERATION_REPORT_NOT_FOUND';
  end if;

  update public.content_reports
  set status = v_status,
      updated_at = now()
  where id = p_report_id;

  if v_action_type is not null then
    v_target_profile_id := case
      when v_report.target_type = 'profile' then v_report.target_id
      when v_report.target_type = 'chat_message' then (
        select m.sender_id
        from public.activity_chat_messages m
        where m.id = v_report.target_id
      )
      when v_report.target_type = 'activity' then (
        select a.organizer_id
        from public.activities a
        where a.id = v_report.target_id
      )
      else null
    end;

    if v_target_profile_id is not null then
      insert into public.moderation_actions (
        profile_id,
        moderator_id,
        report_id,
        action_type,
        reason
      )
      values (
        v_target_profile_id,
        v_user_id,
        p_report_id,
        v_action_type,
        left(coalesce(p_reason, ''), 500)
      );

      perform public.recalculate_profile_trust(v_target_profile_id);
    end if;
  end if;

  return query select p_report_id, v_status;
end;
$$;

grant execute on function public.resolve_moderation_report(uuid, text, text, text)
to authenticated;

notify pgrst, 'reload schema';
