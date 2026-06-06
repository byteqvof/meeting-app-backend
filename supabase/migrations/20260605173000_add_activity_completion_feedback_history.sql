create table if not exists public.activity_feedback (
  id uuid primary key default extensions.gen_random_uuid(),
  activity_id uuid not null references public.activities(id) on delete cascade,
  reviewer_id uuid not null references public.profiles(id) on delete cascade,
  target_profile_id uuid not null references public.profiles(id) on delete cascade,
  rating integer not null check (rating between 1 and 5),
  comment text not null default '' check (char_length(comment) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint activity_feedback_not_self check (reviewer_id <> target_profile_id),
  constraint activity_feedback_unique_target
    unique (activity_id, reviewer_id, target_profile_id)
);

create index if not exists activity_feedback_activity_idx
  on public.activity_feedback (activity_id, created_at desc);

create index if not exists activity_feedback_target_idx
  on public.activity_feedback (target_profile_id);

drop trigger if exists activity_feedback_set_updated_at on public.activity_feedback;
create trigger activity_feedback_set_updated_at
before update on public.activity_feedback
for each row execute function public.set_updated_at();

alter table public.activity_feedback enable row level security;

grant select, insert, update on table public.activity_feedback to authenticated;

create or replace function public.can_access_completed_activity(
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
        and a.status = 'completed'
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

grant execute on function public.can_access_completed_activity(uuid, uuid)
to authenticated;

drop policy if exists "Activity members can read feedback"
on public.activity_feedback;

create policy "Activity members can read feedback"
on public.activity_feedback
for select
to authenticated
using (public.can_access_completed_activity(activity_id, auth.uid()));

drop policy if exists "Activity members can create feedback"
on public.activity_feedback;

create policy "Activity members can create feedback"
on public.activity_feedback
for insert
to authenticated
with check (
  reviewer_id = auth.uid()
  and public.can_access_completed_activity(activity_id, auth.uid())
);

drop policy if exists "Reviewers can update their feedback"
on public.activity_feedback;

create policy "Reviewers can update their feedback"
on public.activity_feedback
for update
to authenticated
using (reviewer_id = auth.uid())
with check (
  reviewer_id = auth.uid()
  and public.can_access_completed_activity(activity_id, auth.uid())
);

create or replace function public.complete_activity(
  p_activity_id uuid
)
returns table (
  activity_id uuid,
  status public.activity_status
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_activity record;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select a.id, a.organizer_id, a.status, a.starts_at
  into v_activity
  from public.activities a
  where a.id = p_activity_id
  for update;

  if not found then
    raise exception 'ACTIVITY_NOT_FOUND';
  end if;

  if v_activity.organizer_id <> v_user_id then
    raise exception 'ACTIVITY_COMPLETION_FORBIDDEN';
  end if;

  if v_activity.status = 'completed' then
    return query select p_activity_id, 'completed'::public.activity_status;
    return;
  end if;

  if v_activity.status <> 'published' then
    raise exception 'ACTIVITY_NOT_COMPLETABLE';
  end if;

  if v_activity.starts_at > now() then
    raise exception 'ACTIVITY_NOT_STARTED';
  end if;

  update public.activities a
  set status = 'completed',
      updated_at = now()
  where a.id = p_activity_id;

  return query select p_activity_id, 'completed'::public.activity_status;
end;
$$;

grant execute on function public.complete_activity(uuid) to authenticated;

create or replace function public.submit_activity_feedback(
  p_activity_id uuid,
  p_target_profile_id uuid,
  p_rating integer,
  p_comment text default ''
)
returns table (
  id uuid,
  activity_id uuid,
  reviewer_id uuid,
  target_profile_id uuid,
  rating integer,
  comment text,
  created_at timestamptz,
  target jsonb
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_comment text := left(btrim(coalesce(p_comment, '')), 500);
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not public.can_access_completed_activity(p_activity_id, v_user_id) then
    if not exists (select 1 from public.activities a where a.id = p_activity_id) then
      raise exception 'ACTIVITY_NOT_FOUND';
    end if;
    raise exception 'ACTIVITY_FEEDBACK_FORBIDDEN';
  end if;

  if p_target_profile_id = v_user_id then
    raise exception 'ACTIVITY_FEEDBACK_SELF';
  end if;

  if p_rating < 1 or p_rating > 5 then
    raise exception 'ACTIVITY_FEEDBACK_RATING_INVALID';
  end if;

  if not exists (
    select 1
    from public.activities a
    where a.id = p_activity_id
      and (
        a.organizer_id = p_target_profile_id
        or exists (
          select 1
          from public.activity_participants ap
          where ap.activity_id = a.id
            and ap.profile_id = p_target_profile_id
            and ap.status = 'joined'
        )
      )
  ) then
    raise exception 'ACTIVITY_FEEDBACK_TARGET_INVALID';
  end if;

  return query
  with feedback as (
    insert into public.activity_feedback as af (
      activity_id,
      reviewer_id,
      target_profile_id,
      rating,
      comment
    )
    values (
      p_activity_id,
      v_user_id,
      p_target_profile_id,
      p_rating,
      v_comment
    )
    on conflict on constraint activity_feedback_unique_target
    do update set
      rating = excluded.rating,
      comment = excluded.comment,
      updated_at = now()
    returning af.*
  )
  select
    feedback.id,
    feedback.activity_id,
    feedback.reviewer_id,
    feedback.target_profile_id,
    feedback.rating,
    feedback.comment,
    feedback.created_at,
    public.profile_json(feedback.target_profile_id) as target
  from feedback;
end;
$$;

grant execute on function public.submit_activity_feedback(uuid, uuid, integer, text)
to authenticated;

create or replace function public.list_completed_activities_for_user(
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
    coalesce(participation.is_joined, false) as is_joined,
    coalesce(participation.available_spots, 0) as available_spots
  from target_user
  join public.activities a
    on a.status = 'completed'
   and (
      a.organizer_id = target_user.id
      or exists (
        select 1
        from public.activity_participants ap
        where ap.activity_id = a.id
          and ap.profile_id = target_user.id
          and ap.status = 'joined'
      )
   )
  join public.activity_categories c on c.id = a.category_id
  left join lateral public.activity_participation_snapshot(a.id) participation on true
  where target_user.id = auth.uid()
  order by a.starts_at desc, a.updated_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 200);
$$;

grant execute on function public.list_completed_activities_for_user(uuid, integer)
to authenticated;

do $$
begin
  if exists (
    select 1 from pg_publication where pubname = 'supabase_realtime'
  ) and not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'activity_chat_messages'
  ) then
    alter publication supabase_realtime add table public.activity_chat_messages;
  end if;
exception
  when undefined_object then null;
end $$;

notify pgrst, 'reload schema';
