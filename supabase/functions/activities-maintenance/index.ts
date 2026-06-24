import { withSupabase } from "npm:@supabase/server";
import { errorResponse, jsonResponse, readJsonBody } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";
import { optionalInteger } from "../_shared/validation.ts";

interface MaintenanceRequest {
  completion_grace_days?: number;
  chat_retention_days?: number;
}

interface CompletedActivityRow {
  activity_id: string;
  status: string;
  completed_at: string;
}

interface PurgedChatRow {
  activity_id: string;
  deleted_messages: number;
  purged_at: string;
}

export default {
  fetch: withSupabase({ auth: "secret" }, async (req, ctx) => {
    const logger = createRequestLogger("activities-maintenance", req);
    const responseHeaders = { "x-request-id": logger.requestId };

    logger.info("request_received", {
      method: req.method,
      path: new URL(req.url).pathname,
      auth_mode: ctx.authMode,
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

    try {
      const input: MaintenanceRequest = await readJsonBody<MaintenanceRequest>(
        req,
      ).catch(() => ({} as MaintenanceRequest));
      const completionGraceDays = optionalInteger(
        input.completion_grace_days ?? 1,
        "completion_grace_days",
        0,
        30,
      ) ?? 1;
      const chatRetentionDays = optionalInteger(
        input.chat_retention_days ?? 7,
        "chat_retention_days",
        0,
        365,
      ) ?? 7;

      logger.info("request_validated", {
        completion_grace_days: completionGraceDays,
        chat_retention_days: chatRetentionDays,
      });

      const { data: completedRows, error: completedError } =
        await ctx.supabaseAdmin.rpc("complete_expired_activities", {
          p_grace_interval: `${completionGraceDays} days`,
        });

      if (completedError) {
        logger.error("complete_expired_failed", { error: completedError });
        return errorResponse(
          "Could not complete expired activities",
          500,
          completedError,
          responseHeaders,
        );
      }

      const { data: purgedRows, error: purgedError } =
        await ctx.supabaseAdmin.rpc("purge_expired_activity_chats", {
          p_retention_interval: `${chatRetentionDays} days`,
        });

      if (purgedError) {
        logger.error("purge_chats_failed", { error: purgedError });
        return errorResponse(
          "Could not purge expired activity chats",
          500,
          purgedError,
          responseHeaders,
        );
      }

      const completed = (completedRows ?? []) as CompletedActivityRow[];
      const purgedChats = (purgedRows ?? []) as PurgedChatRow[];
      const deletedMessages = purgedChats.reduce(
        (sum, row) => sum + Number(row.deleted_messages ?? 0),
        0,
      );

      logger.info("response_sent", {
        status: 200,
        completed_count: completed.length,
        purged_activity_count: purgedChats.length,
        deleted_messages: deletedMessages,
      });

      return jsonResponse(
        {
          completed_count: completed.length,
          purged_activity_count: purgedChats.length,
          deleted_messages: deletedMessages,
          completed,
          purged_chats: purgedChats,
        },
        { headers: responseHeaders },
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
