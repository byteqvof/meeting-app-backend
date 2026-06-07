import { withSupabase } from "npm:@supabase/server";
import type {
  ActivityStatus,
  UserActivitiesResponse,
  UserActivity,
} from "../_shared/activity-model.ts";
import { errorResponse, jsonResponse } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";
import { optionalInteger, optionalUuid } from "../_shared/validation.ts";

const ACTIVITY_STATUSES = new Set<ActivityStatus>([
  "draft",
  "published",
  "cancelled",
  "archived",
  "completed",
]);

function optionalActivityStatus(value: unknown): ActivityStatus | null {
  if (value === undefined || value === null || value === "") {
    return null;
  }

  if (
    typeof value !== "string" ||
    !ACTIVITY_STATUSES.has(value as ActivityStatus)
  ) {
    throw new Error(
      "status must be draft, published, cancelled, archived, or completed",
    );
  }

  return value as ActivityStatus;
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("activities-for-user", req);
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
      const requestedUserId =
        optionalUuid(
          url.searchParams.get("user_id") ?? url.searchParams.get("userId"),
          "user_id",
        ) ?? authenticatedUserId;
      const isOwnProfile = requestedUserId === authenticatedUserId;
      const status = optionalActivityStatus(url.searchParams.get("status"));
      const limit =
        optionalInteger(
          url.searchParams.get("limit") ?? "100",
          "limit",
          1,
          200,
        ) ?? 100;

      logger.info("request_validated", {
        requested_user_id: requestedUserId,
        is_own_profile: isOwnProfile,
        status,
        limit,
      });

      const { data, error } = await ctx.supabase.rpc(
        "list_activities_for_user",
        {
          p_user_id: requestedUserId,
          p_status: status,
          p_limit: limit,
        },
      );

      if (error) {
        logger.error("rpc_failed", { error });
        return errorResponse(
          "Could not fetch activities for user",
          500,
          error,
          responseHeaders,
        );
      }

      const response: UserActivitiesResponse = {
        activities: (data ?? []) as UserActivity[],
        filters: {
          user_id: requestedUserId,
          is_own_profile: isOwnProfile,
          status,
          limit,
        },
      };

      logger.info("response_sent", {
        status: 200,
        requested_user_id: requestedUserId,
        is_own_profile: isOwnProfile,
        activity_count: response.activities.length,
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
