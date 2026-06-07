import { withSupabase } from "npm:@supabase/server";
import type {
  ActivityChatMessage,
  ActivityChatMessagesResponse,
  SendActivityChatMessageRequest,
  SendActivityChatMessageResponse,
} from "../_shared/activity-model.ts";
import { errorResponse, jsonResponse, readJsonBody } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";
import {
  optionalInteger,
  optionalIsoDate,
  optionalUuid,
  requiredString,
  requiredUuid,
} from "../_shared/validation.ts";

function statusForChatError(message: string): number {
  if (message.includes("ACTIVITY_NOT_FOUND")) {
    return 404;
  }

  if (
    message.includes("ACTIVITY_CHAT_FORBIDDEN") ||
    message.includes("AUTH_REQUIRED")
  ) {
    return 403;
  }

  if (message.includes("CHAT_MESSAGE_INVALID")) {
    return 400;
  }

  return 500;
}

function messageForChatError(message: string): string {
  if (message.includes("ACTIVITY_NOT_FOUND")) {
    return "Activity not found";
  }

  if (message.includes("ACTIVITY_CHAT_FORBIDDEN")) {
    return "Join this activity before opening the chat";
  }

  if (message.includes("CHAT_MESSAGE_INVALID")) {
    return "Message must be between 1 and 800 characters";
  }

  return "Could not update activity chat";
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("activity-chat", req);
    const responseHeaders = { "x-request-id": logger.requestId };
    const url = new URL(req.url);

    logger.info("request_received", {
      method: req.method,
      path: url.pathname,
      auth_mode: ctx.authMode,
      user_id: ctx.userClaims?.id,
    });

    if (req.method !== "GET" && req.method !== "POST") {
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
      if (req.method === "GET") {
        const activityId = requiredUuid(
          url.searchParams.get("activity_id") ??
            url.searchParams.get("activityId"),
          "activity_id",
        );
        const limit =
          optionalInteger(
            url.searchParams.get("limit") ?? "50",
            "limit",
            1,
            100,
          ) ?? 50;
        const before = optionalIsoDate(
          url.searchParams.get("before"),
          "before",
        );
        const afterCreatedAt = optionalIsoDate(
          url.searchParams.get("after_created_at") ??
            url.searchParams.get("afterCreatedAt"),
          "after_created_at",
        );
        const afterId = optionalUuid(
          url.searchParams.get("after_id") ?? url.searchParams.get("afterId"),
          "after_id",
        );

        logger.info("request_validated", {
          activity_id: activityId,
          limit,
          before,
          after_created_at: afterCreatedAt,
          after_id: afterId,
        });

        const { data, error } = await ctx.supabase.rpc(
          "list_activity_chat_messages",
          {
            p_activity_id: activityId,
            p_limit: limit,
            p_before: before,
            p_after_created_at: afterCreatedAt,
            p_after_id: afterId,
          },
        );

        if (error) {
          const message = error.message ?? "";
          const status = statusForChatError(message);
          logger.error("list_rpc_failed", { error, status });
          return errorResponse(
            messageForChatError(message),
            status,
            error,
            responseHeaders,
          );
        }

        const response: ActivityChatMessagesResponse = {
          messages: (data ?? []) as ActivityChatMessage[],
          filters: {
            activity_id: activityId,
            limit,
            before,
            after_created_at: afterCreatedAt,
            after_id: afterId,
          },
        };

        logger.info("response_sent", {
          status: 200,
          activity_id: activityId,
          message_count: response.messages.length,
        });

        return jsonResponse(response, { headers: responseHeaders });
      }

      const input = await readJsonBody<SendActivityChatMessageRequest>(req);
      const activityId = requiredUuid(input.activity_id, "activity_id");
      const body = requiredString(input.body, "body", 1, 800);
      const clientMessageId = optionalUuid(
        input.client_message_id,
        "client_message_id",
      );

      logger.info("request_validated", {
        activity_id: activityId,
        body_length: body.length,
        client_message_id: clientMessageId,
      });

      const { data, error } = await ctx.supabase
        .rpc("send_activity_chat_message", {
          p_activity_id: activityId,
          p_body: body,
          p_client_message_id: clientMessageId,
        })
        .single();

      if (error) {
        const message = error.message ?? "";
        const status = statusForChatError(message);
        logger.error("send_rpc_failed", { error, status });
        return errorResponse(
          messageForChatError(message),
          status,
          error,
          responseHeaders,
        );
      }

      const response: SendActivityChatMessageResponse = {
        message: data as ActivityChatMessage,
      };

      logger.info("response_sent", {
        status: 200,
        activity_id: response.message.activity_id,
        message_id: response.message.id,
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
