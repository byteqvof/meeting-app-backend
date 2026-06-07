import { withSupabase } from "npm:@supabase/server";
import { errorResponse, jsonResponse, readJsonBody } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";
import {
  optionalInteger,
  optionalString,
  requiredString,
  requiredUuid,
} from "../_shared/validation.ts";

interface ResolveModerationRequest {
  report_id?: string;
  status?: string;
  action_type?: string | null;
  reason?: string | null;
}

function statusForModerationError(message: string): number {
  if (message.includes("MODERATION_FORBIDDEN")) {
    return 403;
  }
  if (message.includes("MODERATION_REPORT_NOT_FOUND")) {
    return 404;
  }
  if (message.includes("MODERATION_")) {
    return 400;
  }
  return 500;
}

function messageForModerationError(message: string): string {
  if (message.includes("MODERATION_FORBIDDEN")) {
    return "Moderator access required";
  }
  if (message.includes("MODERATION_REPORT_NOT_FOUND")) {
    return "Report not found";
  }
  if (message.includes("MODERATION_STATUS_INVALID")) {
    return "Moderation status is invalid";
  }
  return "Could not process moderation action";
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("moderation-actions", req);
    const responseHeaders = { "x-request-id": logger.requestId };
    const url = new URL(req.url);

    logger.info("request_received", {
      method: req.method,
      auth_mode: ctx.authMode,
      user_id: ctx.userClaims?.id,
    });

    if (!ctx.userClaims?.id) {
      return errorResponse(
        "Missing authenticated user",
        401,
        undefined,
        responseHeaders,
      );
    }

    try {
      if (req.method === "GET") {
        const status = optionalString(
          url.searchParams.get("status"),
          "status",
          30,
        );
        const limit =
          optionalInteger(
            url.searchParams.get("limit") ?? "100",
            "limit",
            1,
            200,
          ) ?? 100;

        const { data, error } = await ctx.supabase.rpc(
          "list_moderation_reports",
          {
            p_status: status,
            p_limit: limit,
          },
        );

        if (error) {
          const message = error.message ?? "";
          const responseStatus = statusForModerationError(message);
          logger.error("list_rpc_failed", { error, status: responseStatus });
          return errorResponse(
            messageForModerationError(message),
            responseStatus,
            error,
            responseHeaders,
          );
        }

        return jsonResponse(
          { reports: data ?? [], filters: { status, limit } },
          { headers: responseHeaders },
        );
      }

      if (req.method === "POST" || req.method === "PATCH") {
        const input = await readJsonBody<ResolveModerationRequest>(req);
        const reportId = requiredUuid(input.report_id, "report_id");
        const status = requiredString(input.status, "status", 3, 30);
        const actionType = optionalString(input.action_type, "action_type", 50);
        const reason = optionalString(input.reason, "reason", 500) ?? "";

        const { data, error } = await ctx.supabase
          .rpc("resolve_moderation_report", {
            p_report_id: reportId,
            p_status: status,
            p_action_type: actionType,
            p_reason: reason,
          })
          .single();

        if (error) {
          const message = error.message ?? "";
          const responseStatus = statusForModerationError(message);
          logger.error("resolve_rpc_failed", { error, status: responseStatus });
          return errorResponse(
            messageForModerationError(message),
            responseStatus,
            error,
            responseHeaders,
          );
        }

        return jsonResponse({ moderation: data }, { headers: responseHeaders });
      }

      return errorResponse(
        "Method not allowed",
        405,
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
