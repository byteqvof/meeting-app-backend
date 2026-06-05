drop function if exists public.list_my_activities(
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
  participants_count integer
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
    coalesce(participant_profiles.participants, '[]'::jsonb) as participants,
    coalesce(participant_profiles.participants_count, 0) as participants_count
  from target_user
  join public.activities a on a.organizer_id = target_user.id
  join public.activity_categories c on c.id = a.category_id
  left join lateral (
    select
      jsonb_agg(public.profile_json(ap.profile_id) order by ap.joined_at) as participants,
      count(*)::integer as participants_count
    from public.activity_participants ap
    where ap.activity_id = a.id
      and ap.status = 'joined'
  ) participant_profiles on true
  where (
      target_user.id = auth.uid()
      or (
        a.status = 'published'
        and a.starts_at >= now()
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

notify pgrst, 'reload schema';
