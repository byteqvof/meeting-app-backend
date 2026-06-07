grant select, insert, update on table public.profile_trust to service_role;

notify pgrst, 'reload schema';
