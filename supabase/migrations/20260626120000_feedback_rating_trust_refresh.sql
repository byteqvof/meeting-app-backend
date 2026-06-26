create or replace function public.refresh_profile_rating_from_feedback(
  p_profile_id uuid
)
returns numeric
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_rating numeric(2, 1) := 0;
begin
  if p_profile_id is null then
    raise exception 'PROFILE_REQUIRED';
  end if;

  select coalesce(round(avg(af.rating)::numeric, 1), 0)::numeric(2, 1)
  into v_rating
  from public.activity_feedback af
  where af.target_profile_id = p_profile_id;

  update public.profiles p
  set rating = v_rating,
      updated_at = now()
  where p.id = p_profile_id;

  return v_rating;
end;
$$;

grant execute on function public.refresh_profile_rating_from_feedback(uuid)
to authenticated, service_role;

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
  v_feedback_id uuid;
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

  with upserted_feedback as (
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
    returning af.id
  )
  select upserted_feedback.id
  into v_feedback_id
  from upserted_feedback;

  perform public.refresh_profile_rating_from_feedback(p_target_profile_id);

  perform public.recalculate_profile_trust(p_target_profile_id);

  return query
  select
    feedback.id,
    feedback.activity_id,
    feedback.reviewer_id,
    feedback.target_profile_id,
    feedback.rating,
    feedback.comment,
    feedback.created_at,
    public.profile_json(feedback.target_profile_id) as target
  from public.activity_feedback feedback
  where feedback.id = v_feedback_id;
end;
$$;

grant execute on function public.submit_activity_feedback(uuid, uuid, integer, text)
to authenticated;

notify pgrst, 'reload schema';
