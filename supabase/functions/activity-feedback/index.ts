import { withSupabase } from "npm:@supabase/server";
import type {
  ActivityFeedback,
  ActivityFeedbackRequest,
  ActivityFeedbackResponse,
} from "../_shared/activity-model.ts";
import { errorResponse, jsonResponse, readJsonBody } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";
import {
  optionalInteger,
  optionalString,
  requiredUuid,
} from "../_shared/validation.ts";

function statusForFeedbackError(message: string): number {
  if (message.includes("ACTIVITY_NOT_FOUND")) {
    return 404;
  }

  if (
    message.includes("ACTIVITY_FEEDBACK_FORBIDDEN") ||
    message.includes("AUTH_REQUIRED")
  ) {
    return 403;
  }

  if (
    message.includes("ACTIVITY_FEEDBACK_SELF") ||
    message.includes("ACTIVITY_FEEDBACK_TARGET_INVALID") ||
    message.includes("ACTIVITY_FEEDBACK_RATING_INVALID")
  ) {
    return 409;
  }

  return 500;
}

function messageForFeedbackError(message: string): string {
  if (message.includes("ACTIVITY_NOT_FOUND")) {
    return "Activity not found";
  }

  if (message.includes("ACTIVITY_FEEDBACK_FORBIDDEN")) {
    return "Feedback is only available after completed activities";
  }

  if (message.includes("ACTIVITY_FEEDBACK_SELF")) {
    return "You cannot leave feedback for yourself";
  }

  if (message.includes("ACTIVITY_FEEDBACK_TARGET_INVALID")) {
    return "Feedback target is not part of this activity";
  }

  if (message.includes("ACTIVITY_FEEDBACK_RATING_INVALID")) {
    return "Rating must be between 1 and 5";
  }

  return "Could not save feedback";
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("activity-feedback", req);
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
      const input = await readJsonBody<ActivityFeedbackRequest>(req);
      const activityId = requiredUuid(input.activity_id, "activity_id");
      const targetProfileId = requiredUuid(
        input.target_profile_id,
        "target_profile_id",
      );
      const rating = optionalInteger(input.rating, "rating", 1, 5);
      if (rating === null) {
        throw new Error("rating is required");
      }
      const comment = optionalString(input.comment, "comment", 500) ?? "";

      logger.info("request_validated", {
        activity_id: activityId,
        target_profile_id: targetProfileId,
        rating,
      });

      const { data, error } = await ctx.supabase
        .rpc("submit_activity_feedback", {
          p_activity_id: activityId,
          p_target_profile_id: targetProfileId,
          p_rating: rating,
          p_comment: comment,
        })
        .single();

      if (error) {
        const message = error.message ?? "";
        const status = statusForFeedbackError(message);
        logger.error("rpc_failed", { error, status });
        return errorResponse(
          messageForFeedbackError(message),
          status,
          error,
          responseHeaders,
        );
      }

      const response: ActivityFeedbackResponse = {
        feedback: data as ActivityFeedback,
      };

      logger.info("response_sent", {
        status: 200,
        activity_id: response.feedback.activity_id,
        target_profile_id: response.feedback.target_profile_id,
        rating: response.feedback.rating,
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
