do $$
begin
  alter type public.activity_participant_status add value if not exists 'pending';
exception
  when duplicate_object then null;
end $$;
