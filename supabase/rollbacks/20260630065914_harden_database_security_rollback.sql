-- Rollback for 20260630065914_harden_database_security.sql.
-- This restores the previous permissive function grants and policy shapes.
-- Use only as an emergency rollback if the hardening migration breaks prod.

alter default privileges in schema public grant execute on functions to public;

grant execute on all functions in schema public to public;
grant execute on all functions in schema public to anon;
grant execute on all functions in schema public to authenticated;
grant execute on all functions in schema public to service_role;

do $$
declare
  function_record record;
begin
  for function_record in
    select
      n.nspname as schema_name,
      p.proname as function_name,
      pg_get_function_identity_arguments(p.oid) as identity_arguments
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
  loop
    execute format(
      'alter function %I.%I(%s) set search_path = public',
      function_record.schema_name,
      function_record.function_name,
      function_record.identity_arguments
    );
  end loop;
end $$;

drop policy if exists "Authenticated users can read published activities" on public.activities;
create policy "Authenticated users can read published activities"
on public.activities
for select
to authenticated
using (
  status = 'published'::activity_status
  or organizer_id = auth.uid()
);

drop policy if exists "Users can create their own activities" on public.activities;
create policy "Users can create their own activities"
on public.activities
for insert
to authenticated
with check (organizer_id = auth.uid());

drop policy if exists "Users can update their own activities" on public.activities;
create policy "Users can update their own activities"
on public.activities
for update
to authenticated
using (organizer_id = auth.uid())
with check (organizer_id = auth.uid());

drop policy if exists "Users can delete their own activities" on public.activities;
create policy "Users can delete their own activities"
on public.activities
for delete
to authenticated
using (organizer_id = auth.uid());

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
    where a.id = activity_attendance.activity_id
      and a.organizer_id = auth.uid()
  )
);

drop policy if exists "Chat members can read activity messages" on public.activity_chat_messages;
create policy "Chat members can read activity messages"
on public.activity_chat_messages
for select
to authenticated
using (public.can_access_activity_chat(activity_id, auth.uid()));

drop policy if exists "Chat members can send activity messages" on public.activity_chat_messages;
create policy "Chat members can send activity messages"
on public.activity_chat_messages
for insert
to authenticated
with check (
  sender_id = auth.uid()
  and message_type = 'user'
  and public.can_send_activity_chat(activity_id, auth.uid())
);

drop policy if exists "Users can read their own chat reads" on public.activity_chat_reads;
create policy "Users can read their own chat reads"
on public.activity_chat_reads
for select
to authenticated
using (profile_id = auth.uid());

drop policy if exists "Users can create their own chat reads" on public.activity_chat_reads;
create policy "Users can create their own chat reads"
on public.activity_chat_reads
for insert
to authenticated
with check (
  profile_id = auth.uid()
  and public.can_access_activity_chat(activity_id, auth.uid())
);

drop policy if exists "Users can update their own chat reads" on public.activity_chat_reads;
create policy "Users can update their own chat reads"
on public.activity_chat_reads
for update
to authenticated
using (profile_id = auth.uid())
with check (
  profile_id = auth.uid()
  and public.can_access_activity_chat(activity_id, auth.uid())
);

drop policy if exists "Activity members can read feedback" on public.activity_feedback;
create policy "Activity members can read feedback"
on public.activity_feedback
for select
to authenticated
using (public.can_access_completed_activity(activity_id, auth.uid()));

drop policy if exists "Activity members can create feedback" on public.activity_feedback;
create policy "Activity members can create feedback"
on public.activity_feedback
for insert
to authenticated
with check (
  reviewer_id = auth.uid()
  and public.can_access_completed_activity(activity_id, auth.uid())
);

drop policy if exists "Reviewers can update their feedback" on public.activity_feedback;
create policy "Reviewers can update their feedback"
on public.activity_feedback
for update
to authenticated
using (reviewer_id = auth.uid())
with check (
  reviewer_id = auth.uid()
  and public.can_access_completed_activity(activity_id, auth.uid())
);

drop policy if exists "Users can join activities as themselves" on public.activity_participants;
create policy "Users can join activities as themselves"
on public.activity_participants
for insert
to authenticated
with check (profile_id = auth.uid());

drop policy if exists "Users can update their own activity participation" on public.activity_participants;
create policy "Users can update their own activity participation"
on public.activity_participants
for update
to authenticated
using (profile_id = auth.uid())
with check (profile_id = auth.uid());

drop policy if exists "Users can delete their own activity participation" on public.activity_participants;
create policy "Users can delete their own activity participation"
on public.activity_participants
for delete
to authenticated
using (profile_id = auth.uid());

do $$
begin
  if to_regclass('public.admin_members') is not null
    and to_regprocedure('public.is_admin_member(uuid)') is not null
  then
    execute $policy$
      drop policy if exists "Admins can read admin members" on public.admin_members;
      create policy "Admins can read admin members"
      on public.admin_members
      for select
      to authenticated
      using (public.is_admin_member(auth.uid()));
    $policy$;
  end if;

  if to_regclass('public.admin_notes') is not null
    and to_regprocedure('public.is_admin_member(uuid)') is not null
  then
    execute $policy$
      drop policy if exists "Admins can read admin notes" on public.admin_notes;
      create policy "Admins can read admin notes"
      on public.admin_notes
      for select
      to authenticated
      using (public.is_admin_member(auth.uid()));
    $policy$;
  end if;

  if to_regclass('public.app_config') is not null
    and to_regprocedure('public.is_admin_member(uuid)') is not null
  then
    execute $policy$
      drop policy if exists "Authenticated users can read public app config" on public.app_config;
      create policy "Authenticated users can read public app config"
      on public.app_config
      for select
      to authenticated
      using (
        is_public
        or public.is_admin_member(auth.uid())
      );
    $policy$;
  end if;

  if to_regclass('public.audit_logs') is not null
    and to_regprocedure('public.is_admin_member(uuid)') is not null
  then
    execute $policy$
      drop policy if exists "Admins can read audit logs" on public.audit_logs;
      create policy "Admins can read audit logs"
      on public.audit_logs
      for select
      to authenticated
      using (public.is_admin_member(auth.uid()));
    $policy$;
  end if;
end $$;

drop policy if exists "Authenticated users can read visible reports" on public.content_reports;
drop policy if exists "Moderators can read reports" on public.content_reports;
create policy "Moderators can read reports"
on public.content_reports
for select
to authenticated
using (public.is_moderator(auth.uid()));

drop policy if exists "Users can read their own reports" on public.content_reports;
create policy "Users can read their own reports"
on public.content_reports
for select
to authenticated
using (reporter_id = auth.uid());

drop policy if exists "Users can create their own reports" on public.content_reports;
create policy "Users can create their own reports"
on public.content_reports
for insert
to authenticated
with check (reporter_id = auth.uid());

drop policy if exists "Users can manage their own push tokens" on public.device_push_tokens;
create policy "Users can manage their own push tokens"
on public.device_push_tokens
for all
to authenticated
using (profile_id = auth.uid())
with check (profile_id = auth.uid());

drop policy if exists "Users can read their own identity verifications" on public.identity_verifications;
create policy "Users can read their own identity verifications"
on public.identity_verifications
for select
to authenticated
using (profile_id = auth.uid());

drop policy if exists "Moderators can read moderation actions" on public.moderation_actions;
create policy "Moderators can read moderation actions"
on public.moderation_actions
for select
to authenticated
using (public.is_moderator(auth.uid()));

do $$
begin
  if to_regclass('public.notification_preferences') is not null then
    execute $policy$
      drop policy if exists "Users can read own notification preferences" on public.notification_preferences;
      create policy "Users can read own notification preferences"
      on public.notification_preferences
      for select
      to authenticated
      using (profile_id = auth.uid());

      drop policy if exists "Users can update own notification preferences" on public.notification_preferences;
      create policy "Users can update own notification preferences"
      on public.notification_preferences
      for update
      to authenticated
      using (profile_id = auth.uid())
      with check (profile_id = auth.uid());
    $policy$;
  end if;
end $$;

drop policy if exists "Users can create their own profile categories" on public.profile_category_links;
create policy "Users can create their own profile categories"
on public.profile_category_links
for insert
to authenticated
with check (profile_id = auth.uid());

drop policy if exists "Users can update their own profile categories" on public.profile_category_links;
create policy "Users can update their own profile categories"
on public.profile_category_links
for update
to authenticated
using (profile_id = auth.uid())
with check (profile_id = auth.uid());

drop policy if exists "Users can delete their own profile categories" on public.profile_category_links;
create policy "Users can delete their own profile categories"
on public.profile_category_links
for delete
to authenticated
using (profile_id = auth.uid());

drop policy if exists "Users can read their friendships" on public.profile_friendships;
create policy "Users can read their friendships"
on public.profile_friendships
for select
to authenticated
using (
  requester_id = auth.uid()
  or addressee_id = auth.uid()
);

drop policy if exists "Users can read their own profile directly" on public.profiles;
create policy "Users can read their own profile directly"
on public.profiles
for select
to authenticated
using (id = auth.uid());

drop policy if exists "Users can create their own profile" on public.profiles;
create policy "Users can create their own profile"
on public.profiles
for insert
to authenticated
with check (id = auth.uid());

drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile"
on public.profiles
for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

drop policy if exists "Users can delete their own profile" on public.profiles;
create policy "Users can delete their own profile"
on public.profiles
for delete
to authenticated
using (id = auth.uid());

do $$
begin
  if to_regclass('public.push_notification_deliveries') is not null
    and to_regprocedure('public.is_admin_member(uuid)') is not null
  then
    execute $policy$
      drop policy if exists "Admins can read push notification deliveries" on public.push_notification_deliveries;
      create policy "Admins can read push notification deliveries"
      on public.push_notification_deliveries
      for select
      to authenticated
      using (public.is_admin_member(auth.uid()));
    $policy$;
  end if;

  if to_regclass('public.push_notifications') is not null
    and to_regprocedure('public.is_admin_member(uuid)') is not null
  then
    execute $policy$
      drop policy if exists "Admins can read push notifications" on public.push_notifications;
      create policy "Admins can read push notifications"
      on public.push_notifications
      for select
      to authenticated
      using (public.is_admin_member(auth.uid()));
    $policy$;
  end if;
end $$;

drop policy if exists "Users can read their own blocks" on public.user_blocks;
create policy "Users can read their own blocks"
on public.user_blocks
for select
to authenticated
using (blocker_id = auth.uid());

drop policy if exists "Users can create their own blocks" on public.user_blocks;
create policy "Users can create their own blocks"
on public.user_blocks
for insert
to authenticated
with check (blocker_id = auth.uid());

drop policy if exists "Users can remove their own blocks" on public.user_blocks;
create policy "Users can remove their own blocks"
on public.user_blocks
for delete
to authenticated
using (blocker_id = auth.uid());

drop policy if exists "Chat members can receive activity chat broadcasts" on realtime.messages;
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

drop policy if exists "Profile avatars are publicly readable" on storage.objects;
create policy "Profile avatars are publicly readable"
on storage.objects
for select
to public
using (bucket_id = 'profile-avatars');

drop policy if exists "Users can upload their own profile avatar" on storage.objects;
create policy "Users can upload their own profile avatar"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'profile-avatars'
  and split_part(name, '/', 1) = auth.uid()::text
);

drop policy if exists "Users can update their own profile avatar" on storage.objects;
create policy "Users can update their own profile avatar"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'profile-avatars'
  and split_part(name, '/', 1) = auth.uid()::text
)
with check (
  bucket_id = 'profile-avatars'
  and split_part(name, '/', 1) = auth.uid()::text
);

drop policy if exists "Users can delete their own profile avatar" on storage.objects;
create policy "Users can delete their own profile avatar"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'profile-avatars'
  and split_part(name, '/', 1) = auth.uid()::text
);

drop index if exists public.activities_created_by_admin_id_idx;
drop index if exists public.activity_attendance_marked_by_idx;
drop index if exists public.activity_chat_reads_last_read_message_id_idx;
drop index if exists public.activity_feedback_reviewer_id_idx;
drop index if exists public.admin_members_created_by_idx;
drop index if exists public.admin_notes_admin_id_idx;
drop index if exists public.app_config_updated_by_admin_id_idx;
drop index if exists public.content_reports_assigned_to_idx;
drop index if exists public.feature_flags_updated_by_admin_id_idx;
drop index if exists public.identity_verifications_reviewed_by_idx;
drop index if exists public.moderation_actions_moderator_id_idx;
drop index if exists public.moderation_actions_report_id_idx;
drop index if exists public.push_notification_deliveries_profile_id_idx;
drop index if exists public.push_notification_deliveries_token_id_idx;
drop index if exists public.push_notifications_created_by_admin_id_idx;

notify pgrst, 'reload schema';
