create or replace function public.insert_activity_join_system_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_display_name text;
begin
  if new.status <> 'joined' then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.status = 'joined' then
    return new;
  end if;

  select coalesce(nullif(btrim(p.display_name), ''), 'Iemand')
  into v_display_name
  from public.profiles p
  where p.id = new.profile_id;

  insert into public.activity_chat_messages (
    activity_id,
    sender_id,
    body,
    message_type
  )
  values (
    new.activity_id,
    new.profile_id,
    coalesce(v_display_name, 'Iemand') || ' heeft zich aangemeld',
    'system'
  );

  return new;
end;
$$;

drop trigger if exists activity_participants_join_system_message
on public.activity_participants;

create trigger activity_participants_join_system_message
after insert or update of status on public.activity_participants
for each row
when (new.status = 'joined')
execute function public.insert_activity_join_system_message();

notify pgrst, 'reload schema';
