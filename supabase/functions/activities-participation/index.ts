import { withSupabase } from "npm:@supabase/server";
import type {
  ActivityParticipationRequest,
  ActivityParticipationResponse,
  ActivityParticipationUpdate,
} from "../_shared/activity-model.ts";
import { errorResponse, jsonResponse, readJsonBody } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";
import { requiredString, requiredUuid } from "../_shared/validation.ts";

function normalizeRequest(
  input: ActivityParticipationRequest,
): ActivityParticipationRequest {
  const activityId = requiredUuid(input.activity_id, "activity_id");
  const action =
    input.action === undefined && typeof input.join === "boolean"
      ? input.join
        ? "join"
        : "leave"
      : requiredString(input.action, "action", 4, 5).toLowerCase();

  if (action !== "join" && action !== "leave") {
    throw new Error("action must be join or leave");
  }

  return {
    activity_id: activityId,
    action,
  };
}

function statusForParticipationError(message: string): number {
  if (message.includes("ACTIVITY_NOT_FOUND")) {
    return 404;
  }

  if (
    message.includes("ACTIVITY_OWNER_CANNOT_JOIN") ||
    message.includes("AUTH_REQUIRED") ||
    message.includes("PROFILE_PHONE_REQUIRED") ||
    message.includes("ACTIVITY_BLOCKED") ||
    message.includes("ACTIVITY_CLOSED") ||
    message.includes("ACTIVITY_IDENTITY_REQUIRED") ||
    message.includes("ACTIVITY_TARGET_MISMATCH") ||
    message.includes("ACTIVITY_REPUTATION_TOO_LOW")
  ) {
    return 403;
  }

  if (
    message.includes("ACTIVITY_FULL") ||
    message.includes("ACTIVITY_UNAVAILABLE") ||
    message.includes("PROFILE_REQUIRED")
  ) {
    return 409;
  }

  return 500;
}

function messageForParticipationError(message: string): string {
  if (message.includes("ACTIVITY_NOT_FOUND")) {
    return "Activity not found";
  }

  if (message.includes("ACTIVITY_OWNER_CANNOT_JOIN")) {
    return "You cannot join your own activity";
  }

  if (message.includes("ACTIVITY_FULL")) {
    return "Activity is full";
  }

  if (message.includes("ACTIVITY_UNAVAILABLE")) {
    return "Activity is no longer available";
  }

  if (message.includes("PROFILE_REQUIRED")) {
    return "Complete your profile before joining activities";
  }

  if (message.includes("PROFILE_PHONE_REQUIRED")) {
    return "Verify your phone number before joining activities";
  }

  if (message.includes("ACTIVITY_BLOCKED")) {
    return "You cannot join this activity";
  }

  if (message.includes("ACTIVITY_CLOSED")) {
    return "This activity is closed";
  }

  if (message.includes("ACTIVITY_IDENTITY_REQUIRED")) {
    return "This activity requires identity verification";
  }

  if (message.includes("ACTIVITY_REPUTATION_TOO_LOW")) {
    return "Your reputation level is too low for this activity";
  }

  if (message.includes("ACTIVITY_TARGET_MISMATCH")) {
    return "This activity is for a specific audience";
  }

  return "Could not update activity participation";
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("activities-participation", req);
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
      const payload = normalizeRequest(
        await readJsonBody<ActivityParticipationRequest>(req),
      );

      logger.info("request_validated", {
        activity_id: payload.activity_id,
        action: payload.action,
      });

      const { data, error } = await ctx.supabase
        .rpc("set_activity_participation", {
          p_activity_id: payload.activity_id,
          p_join: payload.action === "join",
        })
        .single();

      if (error) {
        const message = error.message ?? "";
        const status = statusForParticipationError(message);
        logger.error("rpc_failed", { error, status });
        return errorResponse(
          messageForParticipationError(message),
          status,
          error,
          responseHeaders,
        );
      }

      const participation = data as ActivityParticipationUpdate;
      const response: ActivityParticipationResponse = { participation };

      logger.info("response_sent", {
        status: 200,
        activity_id: participation.activity_id,
        is_joined: participation.is_joined,
        participants_count: participation.participants_count,
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
