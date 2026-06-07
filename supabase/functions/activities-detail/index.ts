import { withSupabase } from "npm:@supabase/server";
import type {
  ActivityDetailResponse,
  UserActivity,
} from "../_shared/activity-model.ts";
import { errorResponse, jsonResponse } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";
import { requiredUuid } from "../_shared/validation.ts";

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("activities-detail", req);
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
      const activityId = requiredUuid(
        url.searchParams.get("activity_id") ?? url.searchParams.get("id"),
        "activity_id",
      );

      logger.info("request_validated", { activity_id: activityId });

      const { data, error } = await ctx.supabase
        .rpc("get_activity_detail", {
          p_activity_id: activityId,
        })
        .maybeSingle();

      if (error) {
        logger.error("rpc_failed", { activity_id: activityId, error });
        return errorResponse(
          "Could not fetch activity",
          500,
          error,
          responseHeaders,
        );
      }

      const response: ActivityDetailResponse = {
        activity: data ? (data as UserActivity) : null,
      };

      logger.info("response_sent", {
        status: response.activity ? 200 : 404,
        activity_id: activityId,
        found: response.activity !== null,
      });

      if (!response.activity) {
        return errorResponse(
          "Activity not found",
          404,
          undefined,
          responseHeaders,
        );
      }

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
