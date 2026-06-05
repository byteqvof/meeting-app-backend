drop policy if exists "Authenticated users can read profiles" on public.profiles;
create policy "Users can read their own profile directly"
on public.profiles
for select
to authenticated
using (id = auth.uid());

create or replace function public.profile_json(p_profile_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
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
    'is_verified', p.is_verified,
    'is_premium', p.is_premium,
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
  from public.profiles p
  where p.id = p_profile_id;
$$;

grant execute on function public.profile_json(uuid) to authenticated;

notify pgrst, 'reload schema';
