import { withSupabase } from "npm:@supabase/server";
import type {
  ActivityCompletionRequest,
  ActivityCompletionResponse,
  ActivityCompletionUpdate,
} from "../_shared/activity-model.ts";
import { errorResponse, jsonResponse, readJsonBody } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";
import { requiredUuid } from "../_shared/validation.ts";

function statusForCompletionError(message: string): number {
  if (message.includes("ACTIVITY_NOT_FOUND")) {
    return 404;
  }

  if (
    message.includes("ACTIVITY_COMPLETION_FORBIDDEN") ||
    message.includes("AUTH_REQUIRED")
  ) {
    return 403;
  }

  if (
    message.includes("ACTIVITY_NOT_STARTED") ||
    message.includes("ACTIVITY_NOT_COMPLETABLE")
  ) {
    return 409;
  }

  return 500;
}

function messageForCompletionError(message: string): string {
  if (message.includes("ACTIVITY_NOT_FOUND")) {
    return "Activity not found";
  }

  if (message.includes("ACTIVITY_COMPLETION_FORBIDDEN")) {
    return "Only the organizer can complete this activity";
  }

  if (message.includes("ACTIVITY_NOT_STARTED")) {
    return "Activity has not started yet";
  }

  if (message.includes("ACTIVITY_NOT_COMPLETABLE")) {
    return "Activity cannot be completed";
  }

  return "Could not complete activity";
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("activities-complete", req);
    const responseHeaders = { "x-request-id": logger.requestId };

    logger.info("request_received", {
      method: req.method,
      path: new URL(req.url).pathname,
      auth_mode: ctx.authMode,
      user_id: ctx.userClaims?.id,
    });

    if (req.method !== "POST") {
      logger.warn("method_not_allowed", { method: req.method });
      return errorResponse(
        "Method not allowed",
        405,
        undefined,
        responseHeaders,
      );
    }

    if (!ctx.userClaims?.id) {
      logger.warn("missing_authenticated_user");
      return errorResponse(
        "Missing authenticated user",
        401,
        undefined,
        responseHeaders,
      );
    }

    try {
      const input = await readJsonBody<ActivityCompletionRequest>(req);
      const activityId = requiredUuid(input.activity_id, "activity_id");

      logger.info("request_validated", { activity_id: activityId });

      const { data, error } = await ctx.supabase
        .rpc("complete_activity", {
          p_activity_id: activityId,
        })
        .single();

      if (error) {
        const message = error.message ?? "";
        const status = statusForCompletionError(message);
        logger.error("rpc_failed", { error, status });
        return errorResponse(
          messageForCompletionError(message),
          status,
          error,
          responseHeaders,
        );
      }

      const response: ActivityCompletionResponse = {
        completion: data as ActivityCompletionUpdate,
      };

      logger.info("response_sent", {
        status: 200,
        activity_id: response.completion.activity_id,
        activity_status: response.completion.status,
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
