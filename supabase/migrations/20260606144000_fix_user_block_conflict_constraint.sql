create or replace function public.set_user_block(
  p_blocked_profile_id uuid,
  p_block boolean default true
)
returns table (
  blocked_profile_id uuid,
  is_blocked boolean
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if p_blocked_profile_id = v_user_id then
    raise exception 'SAFETY_BLOCK_SELF';
  end if;

  if not exists (
    select 1 from public.profiles p where p.id = p_blocked_profile_id
  ) then
    raise exception 'SAFETY_PROFILE_NOT_FOUND';
  end if;

  if coalesce(p_block, true) then
    insert into public.user_blocks (blocker_id, blocked_profile_id)
    values (v_user_id, p_blocked_profile_id)
    on conflict on constraint user_blocks_pkey do nothing;

    return query select p_blocked_profile_id, true;
    return;
  end if;

  delete from public.user_blocks b
  where b.blocker_id = v_user_id
    and b.blocked_profile_id = p_blocked_profile_id;

  return query select p_blocked_profile_id, false;
end;
$$;

grant execute on function public.set_user_block(uuid, boolean)
to authenticated;

notify pgrst, 'reload schema';
