import { withSupabase } from "npm:@supabase/server";
import type {
  ActivityAgendaResponse,
  ActivityChatSummary,
  UserActivity,
} from "../_shared/activity-model.ts";
import { errorResponse, jsonResponse } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";
import { optionalInteger } from "../_shared/validation.ts";

async function withChatSummaries({
  supabase,
  userId,
  activities,
  logger,
}: {
  supabase: { rpc: (fn: string, args: Record<string, unknown>) => any };
  userId: string;
  activities: UserActivity[];
  logger: ReturnType<typeof createRequestLogger>;
}): Promise<UserActivity[]> {
  return await Promise.all(
    activities.map(async (activity) => {
      const { data, error } = await supabase.rpc("activity_chat_summary_json", {
        p_activity_id: activity.id,
        p_user_id: userId,
      });

      if (error) {
        logger.warn("chat_summary_failed", {
          activity_id: activity.id,
          error,
        });
        return activity;
      }

      return {
        ...activity,
        chat_summary: data as ActivityChatSummary,
      };
    }),
  );
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("activities-agenda", req);
    const responseHeaders = { "x-request-id": logger.requestId };
    const url = new URL(req.url);
    const authenticatedUserId = ctx.userClaims?.id;

    logger.info("request_received", {
      method: req.method,
      path: url.pathname,
      auth_mode: ctx.authMode,
      user_id: authenticatedUserId,
    });

    if (req.method !== "GET") {
      logger.warn("method_not_allowed", { method: req.method });
      return errorResponse(
        "Method not allowed",
        405,
        undefined,
        responseHeaders,
      );
    }

    if (!authenticatedUserId) {
      logger.warn("missing_authenticated_user");
      return errorResponse(
        "Missing authenticated user",
        401,
        undefined,
        responseHeaders,
      );
    }

    try {
      const limit =
        optionalInteger(
          url.searchParams.get("limit") ?? "100",
          "limit",
          1,
          200,
        ) ?? 100;

      logger.info("request_validated", {
        user_id: authenticatedUserId,
        limit,
      });

      const { data: hosted, error: hostedError } = await ctx.supabase.rpc(
        "list_activities_for_user",
        {
          p_user_id: authenticatedUserId,
          p_status: "published",
          p_limit: limit,
        },
      );

      if (hostedError) {
        logger.error("hosted_rpc_failed", { error: hostedError });
        return errorResponse(
          "Could not fetch hosted activities",
          500,
          hostedError,
          responseHeaders,
        );
      }

      const { data: joined, error: joinedError } = await ctx.supabase.rpc(
        "list_joined_activities_for_user",
        {
          p_user_id: authenticatedUserId,
          p_limit: limit,
        },
      );

      if (joinedError) {
        logger.error("joined_rpc_failed", { error: joinedError });
        return errorResponse(
          "Could not fetch joined activities",
          500,
          joinedError,
          responseHeaders,
        );
      }

      const { data: completed, error: completedError } = await ctx.supabase.rpc(
        "list_completed_activities_for_user",
        {
          p_user_id: authenticatedUserId,
          p_limit: limit,
        },
      );

      if (completedError) {
        logger.error("completed_rpc_failed", { error: completedError });
        return errorResponse(
          "Could not fetch completed activities",
          500,
          completedError,
          responseHeaders,
        );
      }

      const hostedWithSummaries = await withChatSummaries({
        supabase: ctx.supabase,
        userId: authenticatedUserId,
        activities: (hosted ?? []) as UserActivity[],
        logger,
      });
      const joinedWithSummaries = await withChatSummaries({
        supabase: ctx.supabase,
        userId: authenticatedUserId,
        activities: (joined ?? []) as UserActivity[],
        logger,
      });
      const completedWithSummaries = await withChatSummaries({
        supabase: ctx.supabase,
        userId: authenticatedUserId,
        activities: (completed ?? []) as UserActivity[],
        logger,
      });

      const response: ActivityAgendaResponse = {
        hosted: hostedWithSummaries,
        joined: joinedWithSummaries,
        completed: completedWithSummaries,
        filters: {
          user_id: authenticatedUserId,
          limit,
        },
      };

      logger.info("response_sent", {
        status: 200,
        hosted_count: response.hosted.length,
        joined_count: response.joined.length,
        completed_count: response.completed.length,
      });

      return jsonResponse(response, { headers: responseHeaders });
    } catch (error) {
      logger.warn("request_failed", errorFields(error));
      return errorResponse(
        error instanceof Error ? error.message : "Invalid request",
        400,
        undefined,
        responseHeaders,
      );
    }
  }),
};
