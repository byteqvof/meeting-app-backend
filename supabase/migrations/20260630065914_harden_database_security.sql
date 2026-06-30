-- Harden public function execution, RLS policies, FK indexes, and avatar storage
-- without changing app-facing Edge Function APIs.

-- Stop new public-schema functions from being executable by PUBLIC by default.
alter default privileges in schema public revoke execute on functions from public;

-- Explicit search_path on public functions prevents role/search_path hijacking.
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
      'alter function %I.%I(%s) set search_path = public, extensions, pg_temp',
      function_record.schema_name,
      function_record.function_name,
      function_record.identity_arguments
    );
  end loop;
end $$;

-- Remove broad execution grants. Re-grant only explicit app/backend surfaces below.
revoke execute on all functions in schema public from public;
revoke execute on all functions in schema public from anon;
revoke execute on all functions in schema public from authenticated;
revoke execute on all functions in schema public from service_role;

-- The service role is trusted backend/admin infrastructure.
grant execute on all functions in schema public to service_role;

-- Authenticated users may execute only the RPCs and RLS helper functions used by
-- user-authenticated Edge Functions and policies. Some admin helpers exist on
-- the live project before their migrations were committed, so grant defensively.
do $$
declare
  function_signature text;
begin
  foreach function_signature in array array[
    'public.activity_chat_id_from_realtime_topic(text)',
    'public.activity_chat_summary_json(uuid, uuid)',
    'public.can_access_activity_chat(uuid, uuid)',
    'public.can_access_completed_activity(uuid, uuid)',
    'public.can_send_activity_chat(uuid, uuid)',
    'public.complete_activity(uuid)',
    'public.get_activity_detail(uuid)',
    'public.has_user_block(uuid, uuid)',
    'public.is_admin_member(uuid)',
    'public.is_moderator(uuid)',
    'public.list_activities_for_user(uuid, activity_status, integer)',
    'public.list_activity_chat_messages(uuid, integer, timestamp with time zone, timestamp with time zone, uuid)',
    'public.list_completed_activities_for_user(uuid, integer)',
    'public.list_joined_activities_for_user(uuid, integer)',
    'public.list_moderation_reports(text, integer)',
    'public.list_profile_friendships(text)',
    'public.mark_activity_attendance(uuid, uuid, text)',
    'public.mark_activity_chat_read(uuid, uuid)',
    'public.profile_friendship_status(uuid, uuid)',
    'public.profile_json(uuid)',
    'public.search_activities_nearby(double precision, double precision, double precision, uuid[], timestamp with time zone, timestamp with time zone, text[], text[], boolean, boolean, integer, integer, text, integer)',
    'public.send_activity_chat_message(uuid, text, uuid)',
    'public.set_activity_participation(uuid, boolean)',
    'public.set_profile_friendship(uuid, text)',
    'public.set_user_block(uuid, boolean)',
    'public.submit_activity_feedback(uuid, uuid, integer, text)',
    'public.submit_content_report(text, uuid, text, text)',
    'public.sync_current_user_trust()'
  ]
  loop
    if to_regprocedure(function_signature) is not null then
      execute format('grant execute on function %s to authenticated', function_signature);
    end if;
  end loop;
end $$;

-- FK indexes reported by the Supabase performance advisor. Optional admin/config
-- tables are guarded so local/fresh databases without them still migrate.
do $$
begin
  if to_regclass('public.activities') is not null then
    create index if not exists activities_created_by_admin_id_idx
      on public.activities(created_by_admin_id);
  end if;

  if to_regclass('public.activity_attendance') is not null then
    create index if not exists activity_attendance_marked_by_idx
      on public.activity_attendance(marked_by);
  end if;

  if to_regclass('public.activity_chat_reads') is not null then
    create index if not exists activity_chat_reads_last_read_message_id_idx
      on public.activity_chat_reads(last_read_message_id);
  end if;

  if to_regclass('public.activity_feedback') is not null then
    create index if not exists activity_feedback_reviewer_id_idx
      on public.activity_feedback(reviewer_id);
  end if;

  if to_regclass('public.admin_members') is not null then
    create index if not exists admin_members_created_by_idx
      on public.admin_members(created_by);
  end if;

  if to_regclass('public.admin_notes') is not null then
    create index if not exists admin_notes_admin_id_idx
      on public.admin_notes(admin_id);
  end if;

  if to_regclass('public.app_config') is not null then
    create index if not exists app_config_updated_by_admin_id_idx
      on public.app_config(updated_by_admin_id);
  end if;

  if to_regclass('public.content_reports') is not null then
    create index if not exists content_reports_assigned_to_idx
      on public.content_reports(assigned_to);
  end if;

  if to_regclass('public.feature_flags') is not null then
    create index if not exists feature_flags_updated_by_admin_id_idx
      on public.feature_flags(updated_by_admin_id);
  end if;

  if to_regclass('public.identity_verifications') is not null then
    create index if not exists identity_verifications_reviewed_by_idx
      on public.identity_verifications(reviewed_by);
  end if;

  if to_regclass('public.moderation_actions') is not null then
    create index if not exists moderation_actions_moderator_id_idx
      on public.moderation_actions(moderator_id);

    create index if not exists moderation_actions_report_id_idx
      on public.moderation_actions(report_id);
  end if;

  if to_regclass('public.push_notification_deliveries') is not null then
    create index if not exists push_notification_deliveries_profile_id_idx
      on public.push_notification_deliveries(profile_id);

    create index if not exists push_notification_deliveries_token_id_idx
      on public.push_notification_deliveries(token_id);
  end if;

  if to_regclass('public.push_notifications') is not null then
    create index if not exists push_notifications_created_by_admin_id_idx
      on public.push_notifications(created_by_admin_id);
  end if;
end $$;

-- RLS policies rewritten so auth.uid() is evaluated once per statement.
drop policy if exists "Authenticated users can read published activities" on public.activities;
create policy "Authenticated users can read published activities"
on public.activities
for select
to authenticated
using (
  status = 'published'::activity_status
  or organizer_id = (select auth.uid())
);

drop policy if exists "Users can create their own activities" on public.activities;
create policy "Users can create their own activities"
on public.activities
for insert
to authenticated
with check (organizer_id = (select auth.uid()));

drop policy if exists "Users can update their own activities" on public.activities;
create policy "Users can update their own activities"
on public.activities
for update
to authenticated
using (organizer_id = (select auth.uid()))
with check (organizer_id = (select auth.uid()));

drop policy if exists "Users can delete their own activities" on public.activities;
create policy "Users can delete their own activities"
on public.activities
for delete
to authenticated
using (organizer_id = (select auth.uid()));

drop policy if exists "Activity members can read attendance" on public.activity_attendance;
create policy "Activity members can read attendance"
on public.activity_attendance
for select
to authenticated
using (
  profile_id = (select auth.uid())
  or exists (
    select 1
    from public.activities a
    where a.id = activity_attendance.activity_id
      and a.organizer_id = (select auth.uid())
  )
);

drop policy if exists "Chat members can read activity messages" on public.activity_chat_messages;
create policy "Chat members can read activity messages"
on public.activity_chat_messages
for select
to authenticated
using (public.can_access_activity_chat(activity_id, (select auth.uid())));

drop policy if exists "Chat members can send activity messages" on public.activity_chat_messages;
create policy "Chat members can send activity messages"
on public.activity_chat_messages
for insert
to authenticated
with check (
  sender_id = (select auth.uid())
  and message_type = 'user'
  and public.can_send_activity_chat(activity_id, (select auth.uid()))
);

drop policy if exists "Users can read their own chat reads" on public.activity_chat_reads;
create policy "Users can read their own chat reads"
on public.activity_chat_reads
for select
to authenticated
using (profile_id = (select auth.uid()));

drop policy if exists "Users can create their own chat reads" on public.activity_chat_reads;
create policy "Users can create their own chat reads"
on public.activity_chat_reads
for insert
to authenticated
with check (
  profile_id = (select auth.uid())
  and public.can_access_activity_chat(activity_id, (select auth.uid()))
);

drop policy if exists "Users can update their own chat reads" on public.activity_chat_reads;
create policy "Users can update their own chat reads"
on public.activity_chat_reads
for update
to authenticated
using (profile_id = (select auth.uid()))
with check (
  profile_id = (select auth.uid())
  and public.can_access_activity_chat(activity_id, (select auth.uid()))
);

drop policy if exists "Activity members can read feedback" on public.activity_feedback;
create policy "Activity members can read feedback"
on public.activity_feedback
for select
to authenticated
using (public.can_access_completed_activity(activity_id, (select auth.uid())));

drop policy if exists "Activity members can create feedback" on public.activity_feedback;
create policy "Activity members can create feedback"
on public.activity_feedback
for insert
to authenticated
with check (
  reviewer_id = (select auth.uid())
  and public.can_access_completed_activity(activity_id, (select auth.uid()))
);

drop policy if exists "Reviewers can update their feedback" on public.activity_feedback;
create policy "Reviewers can update their feedback"
on public.activity_feedback
for update
to authenticated
using (reviewer_id = (select auth.uid()))
with check (
  reviewer_id = (select auth.uid())
  and public.can_access_completed_activity(activity_id, (select auth.uid()))
);

drop policy if exists "Users can join activities as themselves" on public.activity_participants;
create policy "Users can join activities as themselves"
on public.activity_participants
for insert
to authenticated
with check (profile_id = (select auth.uid()));

drop policy if exists "Users can update their own activity participation" on public.activity_participants;
create policy "Users can update their own activity participation"
on public.activity_participants
for update
to authenticated
using (profile_id = (select auth.uid()))
with check (profile_id = (select auth.uid()));

drop policy if exists "Users can delete their own activity participation" on public.activity_participants;
create policy "Users can delete their own activity participation"
on public.activity_participants
for delete
to authenticated
using (profile_id = (select auth.uid()));

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
      using (public.is_admin_member((select auth.uid())));
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
      using (public.is_admin_member((select auth.uid())));
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
        or public.is_admin_member((select auth.uid()))
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
      using (public.is_admin_member((select auth.uid())));
    $policy$;
  end if;
end $$;

drop policy if exists "Moderators can read reports" on public.content_reports;
drop policy if exists "Users can read their own reports" on public.content_reports;
create policy "Authenticated users can read visible reports"
on public.content_reports
for select
to authenticated
using (
  reporter_id = (select auth.uid())
  or public.is_moderator((select auth.uid()))
);

drop policy if exists "Users can create their own reports" on public.content_reports;
create policy "Users can create their own reports"
on public.content_reports
for insert
to authenticated
with check (reporter_id = (select auth.uid()));

drop policy if exists "Users can manage their own push tokens" on public.device_push_tokens;
create policy "Users can manage their own push tokens"
on public.device_push_tokens
for all
to authenticated
using (profile_id = (select auth.uid()))
with check (profile_id = (select auth.uid()));

drop policy if exists "Users can read their own identity verifications" on public.identity_verifications;
create policy "Users can read their own identity verifications"
on public.identity_verifications
for select
to authenticated
using (profile_id = (select auth.uid()));

drop policy if exists "Moderators can read moderation actions" on public.moderation_actions;
create policy "Moderators can read moderation actions"
on public.moderation_actions
for select
to authenticated
using (public.is_moderator((select auth.uid())));

do $$
begin
  if to_regclass('public.notification_preferences') is not null then
    execute $policy$
      drop policy if exists "Users can read own notification preferences" on public.notification_preferences;
      create policy "Users can read own notification preferences"
      on public.notification_preferences
      for select
      to authenticated
      using (profile_id = (select auth.uid()));

      drop policy if exists "Users can update own notification preferences" on public.notification_preferences;
      create policy "Users can update own notification preferences"
      on public.notification_preferences
      for update
      to authenticated
      using (profile_id = (select auth.uid()))
      with check (profile_id = (select auth.uid()));
    $policy$;
  end if;
end $$;

drop policy if exists "Users can create their own profile categories" on public.profile_category_links;
create policy "Users can create their own profile categories"
on public.profile_category_links
for insert
to authenticated
with check (profile_id = (select auth.uid()));

drop policy if exists "Users can update their own profile categories" on public.profile_category_links;
create policy "Users can update their own profile categories"
on public.profile_category_links
for update
to authenticated
using (profile_id = (select auth.uid()))
with check (profile_id = (select auth.uid()));

drop policy if exists "Users can delete their own profile categories" on public.profile_category_links;
create policy "Users can delete their own profile categories"
on public.profile_category_links
for delete
to authenticated
using (profile_id = (select auth.uid()));

drop policy if exists "Users can read their friendships" on public.profile_friendships;
create policy "Users can read their friendships"
on public.profile_friendships
for select
to authenticated
using (
  requester_id = (select auth.uid())
  or addressee_id = (select auth.uid())
);

drop policy if exists "Users can read their own profile directly" on public.profiles;
create policy "Users can read their own profile directly"
on public.profiles
for select
to authenticated
using (id = (select auth.uid()));

drop policy if exists "Users can create their own profile" on public.profiles;
create policy "Users can create their own profile"
on public.profiles
for insert
to authenticated
with check (id = (select auth.uid()));

drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile"
on public.profiles
for update
to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

drop policy if exists "Users can delete their own profile" on public.profiles;
create policy "Users can delete their own profile"
on public.profiles
for delete
to authenticated
using (id = (select auth.uid()));

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
      using (public.is_admin_member((select auth.uid())));
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
      using (public.is_admin_member((select auth.uid())));
    $policy$;
  end if;
end $$;

drop policy if exists "Users can read their own blocks" on public.user_blocks;
create policy "Users can read their own blocks"
on public.user_blocks
for select
to authenticated
using (blocker_id = (select auth.uid()));

drop policy if exists "Users can create their own blocks" on public.user_blocks;
create policy "Users can create their own blocks"
on public.user_blocks
for insert
to authenticated
with check (blocker_id = (select auth.uid()));

drop policy if exists "Users can remove their own blocks" on public.user_blocks;
create policy "Users can remove their own blocks"
on public.user_blocks
for delete
to authenticated
using (blocker_id = (select auth.uid()));

drop policy if exists "Chat members can receive activity chat broadcasts" on realtime.messages;
create policy "Chat members can receive activity chat broadcasts"
on realtime.messages
for select
to authenticated
using (
  extension = 'broadcast'
  and public.can_access_activity_chat(
    public.activity_chat_id_from_realtime_topic(realtime.topic()),
    (select auth.uid())
  )
);

-- Public buckets can serve public object URLs without a broad storage.objects
-- SELECT policy that allows object listing.
drop policy if exists "Profile avatars are publicly readable" on storage.objects;

drop policy if exists "Users can upload their own profile avatar" on storage.objects;
create policy "Users can upload their own profile avatar"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'profile-avatars'
  and split_part(name, '/', 1) = (select auth.uid())::text
);

drop policy if exists "Users can update their own profile avatar" on storage.objects;
create policy "Users can update their own profile avatar"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'profile-avatars'
  and split_part(name, '/', 1) = (select auth.uid())::text
)
with check (
  bucket_id = 'profile-avatars'
  and split_part(name, '/', 1) = (select auth.uid())::text
);

drop policy if exists "Users can delete their own profile avatar" on storage.objects;
create policy "Users can delete their own profile avatar"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'profile-avatars'
  and split_part(name, '/', 1) = (select auth.uid())::text
);

notify pgrst, 'reload schema';
