import { withSupabase } from "npm:@supabase/server";
import { errorResponse, jsonResponse, readJsonBody } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";
import {
  optionalString,
  optionalUuid,
  requiredString,
  requiredUuid,
} from "../_shared/validation.ts";

interface SafetyActionRequest {
  action?: string;
  target_type?: string;
  target_id?: string;
  blocked_profile_id?: string;
  reason_category?: string;
  reason?: string;
  details?: string;
}

function statusForSafetyError(message: string): number {
  if (message.includes("AUTH_REQUIRED")) {
    return 401;
  }
  if (message.includes("NOT_FOUND")) {
    return 404;
  }
  if (message.includes("SAFETY_BLOCK_SELF")) {
    return 409;
  }
  if (message.includes("SAFETY_")) {
    return 400;
  }
  return 500;
}

function messageForSafetyError(message: string): string {
  if (message.includes("SAFETY_BLOCK_SELF")) {
    return "You cannot block yourself";
  }
  if (message.includes("SAFETY_PROFILE_NOT_FOUND")) {
    return "Profile not found";
  }
  if (message.includes("SAFETY_TARGET_NOT_FOUND")) {
    return "Report target not found";
  }
  if (message.includes("SAFETY_REASON_INVALID")) {
    return "Report reason is invalid";
  }
  if (message.includes("SAFETY_DETAILS_INVALID")) {
    return "Report details are too long";
  }
  return "Could not process safety action";
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("safety-actions", req);
    const responseHeaders = { "x-request-id": logger.requestId };
    const userId = ctx.userClaims?.id;

    logger.info("request_received", {
      method: req.method,
      auth_mode: ctx.authMode,
      user_id: userId,
    });

    if (req.method !== "POST") {
      return errorResponse(
        "Method not allowed",
        405,
        undefined,
        responseHeaders,
      );
    }

    if (!userId) {
      return errorResponse(
        "Missing authenticated user",
        401,
        undefined,
        responseHeaders,
      );
    }

    try {
      const input = await readJsonBody<SafetyActionRequest>(req);
      const action = requiredString(input.action, "action", 3, 30);

      if (action === "report") {
        const targetType = requiredString(
          input.target_type,
          "target_type",
          3,
          30,
        );
        const targetId = requiredUuid(input.target_id, "target_id");
        const reason = requiredString(
          input.reason_category ?? input.reason,
          "reason",
          3,
          80,
        );
        const details = optionalString(input.details, "details", 1000) ?? "";

        const { data, error } = await ctx.supabase
          .rpc("submit_content_report", {
            p_target_type: targetType,
            p_target_id: targetId,
            p_reason: reason,
            p_details: details,
          })
          .single();

        if (error) {
          const message = error.message ?? "";
          const status = statusForSafetyError(message);
          logger.error("report_rpc_failed", { error, status });
          return errorResponse(
            messageForSafetyError(message),
            status,
            error,
            responseHeaders,
          );
        }

        logger.info("report_created", {
          target_type: targetType,
          target_id: targetId,
        });
        return jsonResponse(
          { report: data },
          { status: 201, headers: responseHeaders },
        );
      }

      if (action === "block" || action === "unblock") {
        const blockedProfileId = requiredUuid(
          input.blocked_profile_id ?? input.target_id,
          "blocked_profile_id",
        );

        const { data, error } = await ctx.supabase
          .rpc("set_user_block", {
            p_blocked_profile_id: blockedProfileId,
            p_block: action === "block",
          })
          .single();

        if (error) {
          const message = error.message ?? "";
          const status = statusForSafetyError(message);
          logger.error("block_rpc_failed", { error, status });
          return errorResponse(
            messageForSafetyError(message),
            status,
            error,
            responseHeaders,
          );
        }

        logger.info("block_updated", {
          blocked_profile_id: blockedProfileId,
          is_blocked: action === "block",
        });
        return jsonResponse({ block: data }, { headers: responseHeaders });
      }

      optionalUuid(input.target_id, "target_id");
      return errorResponse(
        "Unknown safety action",
        400,
        undefined,
        responseHeaders,
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
