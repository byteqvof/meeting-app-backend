import { withSupabase } from "npm:@supabase/server";
import { errorResponse, jsonResponse, readJsonBody } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";
import { requiredString, requiredUuid } from "../_shared/validation.ts";

interface ActivityAttendanceRequest {
  activity_id?: string;
  profile_id?: string;
  status?: string;
}

function statusForAttendanceError(message: string): number {
  if (message.includes("AUTH_REQUIRED")) {
    return 401;
  }
  if (message.includes("ATTENDANCE_FORBIDDEN")) {
    return 403;
  }
  if (message.includes("ATTENDANCE_TARGET_INVALID")) {
    return 404;
  }
  if (message.includes("ATTENDANCE_STATUS_INVALID")) {
    return 400;
  }
  return 500;
}

function messageForAttendanceError(message: string): string {
  if (message.includes("ATTENDANCE_FORBIDDEN")) {
    return "Only the host can mark attendance after completion";
  }
  if (message.includes("ATTENDANCE_TARGET_INVALID")) {
    return "Attendance target not found";
  }
  if (message.includes("ATTENDANCE_STATUS_INVALID")) {
    return "Attendance status is invalid";
  }
  return "Could not mark attendance";
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("activity-attendance", req);
    const responseHeaders = { "x-request-id": logger.requestId };

    logger.info("request_received", {
      method: req.method,
      auth_mode: ctx.authMode,
      user_id: ctx.userClaims?.id,
    });

    if (req.method !== "POST") {
      return errorResponse(
        "Method not allowed",
        405,
        undefined,
        responseHeaders,
      );
    }

    if (!ctx.userClaims?.id) {
      return errorResponse(
        "Missing authenticated user",
        401,
        undefined,
        responseHeaders,
      );
    }

    try {
      const input = await readJsonBody<ActivityAttendanceRequest>(req);
      const activityId = requiredUuid(input.activity_id, "activity_id");
      const profileId = requiredUuid(input.profile_id, "profile_id");
      const status = requiredString(input.status, "status", 6, 7);

      const { data, error } = await ctx.supabase
        .rpc("mark_activity_attendance", {
          p_activity_id: activityId,
          p_profile_id: profileId,
          p_status: status,
        })
        .single();

      if (error) {
        const message = error.message ?? "";
        const responseStatus = statusForAttendanceError(message);
        logger.error("attendance_rpc_failed", {
          error,
          status: responseStatus,
        });
        return errorResponse(
          messageForAttendanceError(message),
          responseStatus,
          error,
          responseHeaders,
        );
      }

      return jsonResponse(
        { attendance: data },
        { status: 200, headers: responseHeaders },
      );
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
