# Workspace Instructions

Use the local skill at `skills/supabase-server/SKILL.md` whenever planning or writing server-side code that uses `@supabase/server`, its adapters, or its core auth/client helpers.

Trigger this skill before modifying code that:

- imports `@supabase/server`, `@supabase/server/core`, or `@supabase/server/adapters/hono`
- calls `withSupabase`, `createSupabaseContext`, `createAdminClient`, `createContextClient`, `verifyAuth`, `verifyCredentials`, or `extractCredentials`
- configures an `auth:` mode
- lives under `supabase/functions/` and authenticates inbound requests
- migrates legacy Supabase server patterns such as `Deno.serve`, manual `createClient(...)`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `allow:`, legacy `'always'` / `'public'` auth values, or `authType`

When the skill applies, read `skills/supabase-server/SKILL.md` before drafting code and follow it as the source of truth.