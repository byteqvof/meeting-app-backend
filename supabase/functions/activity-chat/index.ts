import { withSupabase } from "npm:@supabase/server";
import type {
  ActivityChatMessage,
  ActivityChatMessagesResponse,
  ActivityChatSummary,
  MarkActivityChatReadRequest,
  MarkActivityChatReadResponse,
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
  if (message.includes("CHAT_MESSAGE_NOT_FOUND")) {
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
  if (message.includes("CHAT_MESSAGE_NOT_FOUND")) {
    return "Chat message not found";
  }

  if (message.includes("ACTIVITY_CHAT_FORBIDDEN")) {
    return "Join this activity before opening the chat";
  }

  if (message.includes("CHAT_MESSAGE_INVALID")) {
    return "Message must be between 1 and 800 characters";
  }

  return "Could not update activity chat";
}

interface FcmServiceAccount {
  client_email: string;
  private_key: string;
  token_uri?: string;
}

interface FcmConfig {
  projectId: string;
  serviceAccount: FcmServiceAccount;
}

interface PushTokenRow {
  token: string;
  platform?: string | null;
}

interface ActivityRow {
  title?: string | null;
}

interface PushRecipientRow {
  profile_id: string;
}

interface FcmSendErrorPayload {
  error?: {
    status?: string;
    details?: Array<{
      "@type"?: string;
      errorCode?: string;
    }>;
  };
}

interface FcmSendResult {
  ok: boolean;
  status: number;
  errorCode: string | null;
  disabledToken: boolean;
}

interface PushTarget {
  token: string;
  platform: string | null;
}

function base64Url(input: ArrayBuffer | string): string {
  const bytes = typeof input === "string"
    ? new TextEncoder().encode(input)
    : new Uint8Array(input);
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const base64 = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes.buffer;
}

async function createFcmAccessToken(
  serviceAccount: FcmServiceAccount,
): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claim = {
    iss: serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: serviceAccount.token_uri ?? "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${base64Url(JSON.stringify(header))}.${
    base64Url(JSON.stringify(claim))
  }`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(serviceAccount.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const assertion = `${unsigned}.${base64Url(signature)}`;

  const tokenResponse = await fetch(
    serviceAccount.token_uri ?? "https://oauth2.googleapis.com/token",
    {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion,
      }),
    },
  );

  if (!tokenResponse.ok) {
    throw new Error(`FCM access token failed: ${tokenResponse.status}`);
  }

  const payload = await tokenResponse.json() as { access_token?: string };
  if (!payload.access_token) {
    throw new Error("FCM access token missing");
  }
  return payload.access_token;
}

function fcmConfig({
  logger,
  activityId,
  messageId,
}: {
  logger: ReturnType<typeof createRequestLogger>;
  activityId: string;
  messageId: string;
}): FcmConfig | null {
  const projectId = Deno.env.get("FCM_PROJECT_ID")?.trim();
  const serviceAccountJson = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON")?.trim();
  if (!projectId || !serviceAccountJson) {
    logger.info("push_fcm_config_missing", {
      activity_id: activityId,
      message_id: messageId,
      has_project_id: Boolean(projectId),
      has_service_account_json: Boolean(serviceAccountJson),
    });
    return null;
  }

  let serviceAccount: FcmServiceAccount;
  try {
    serviceAccount = JSON.parse(serviceAccountJson) as FcmServiceAccount;
  } catch (error) {
    logger.warn("push_fcm_config_invalid_json", {
      activity_id: activityId,
      message_id: messageId,
      ...errorFields(error),
    });
    return null;
  }

  if (!serviceAccount.client_email || !serviceAccount.private_key) {
    logger.warn("push_fcm_config_missing_service_account_fields", {
      activity_id: activityId,
      message_id: messageId,
      has_client_email: Boolean(serviceAccount.client_email),
      has_private_key: Boolean(serviceAccount.private_key),
    });
    return null;
  }

  return {
    projectId,
    serviceAccount,
  };
}

function notificationBody(message: ActivityChatMessage): string {
  const senderName = message.sender?.display_name?.trim() || "Iemand";
  const preview = (message.body ?? "").toString().replace(/\s+/g, " ").trim();
  if (preview.length === 0) {
    return `${senderName}: nieuw bericht`;
  }
  return `${senderName}: ${preview}`;
}

function fcmMessageForTarget({
  target,
  activityTitle,
  body,
  message,
}: {
  target: PushTarget;
  activityTitle: string;
  body: string;
  message: ActivityChatMessage;
}): Record<string, unknown> {
  const data = {
    type: "activity_chat",
    activity_id: message.activity_id,
    message_id: message.id,
    chat_title: activityTitle,
    chat_body: body,
    group_key: `activity_chat:${message.activity_id}`,
  };

  if (target.platform === "android") {
    return {
      token: target.token,
      data,
      android: {
        priority: "HIGH",
      },
    };
  }

  return {
    token: target.token,
    notification: {
      title: activityTitle,
      body,
    },
    data,
    android: {
      priority: "HIGH",
      notification: {
        channel_id: "activity_chat",
        click_action: "FLUTTER_NOTIFICATION_CLICK",
      },
    },
    apns: {
      headers: {
        "apns-priority": "10",
      },
      payload: {
        aps: {
          sound: "default",
          "thread-id": message.activity_id,
        },
      },
    },
  };
}

async function fcmSendErrorCode(response: Response): Promise<string | null> {
  try {
    const payload = await response.json() as FcmSendErrorPayload;
    const fcmError = payload.error?.details?.find((detail) =>
      detail["@type"]?.includes("google.firebase.fcm.v1.FcmError")
    );
    return fcmError?.errorCode ?? null;
  } catch (_error) {
    return null;
  }
}

function shouldDisablePushToken(errorCode: string | null): boolean {
  return errorCode === "UNREGISTERED" || errorCode === "INVALID_ARGUMENT";
}

async function disablePushTokenBestEffort({
  supabaseAdmin,
  token,
  logger,
}: {
  supabaseAdmin: any;
  token: string;
  logger: ReturnType<typeof createRequestLogger>;
}): Promise<void> {
  try {
    const { error } = await supabaseAdmin
      .from("device_push_tokens")
      .update({ enabled: false, last_seen_at: new Date().toISOString() })
      .eq("token", token);

    if (error) {
      throw error;
    }
    logger.info("push_token_disabled_after_fcm_reject");
  } catch (error) {
    logger.warn(
      "push_token_disable_after_fcm_reject_failed",
      errorFields(error),
    );
  }
}

async function sendChatPushBestEffort({
  supabaseAdmin,
  message,
  logger,
}: {
  supabaseAdmin: any;
  message: ActivityChatMessage;
  logger: ReturnType<typeof createRequestLogger>;
}): Promise<void> {
  try {
    logger.info("push_pipeline_started", {
      activity_id: message.activity_id,
      message_id: message.id,
      sender_id: message.sender_id,
    });

    const config = fcmConfig({
      logger,
      activityId: message.activity_id,
      messageId: message.id,
    });
    if (config === null) {
      logger.info("push_skipped_missing_fcm_config", {
        activity_id: message.activity_id,
        message_id: message.id,
      });
      return;
    }

    logger.info("push_fcm_config_ready", {
      activity_id: message.activity_id,
      message_id: message.id,
      project_id: config.projectId,
    });

    const { data: activity, error: activityError } = await supabaseAdmin
      .from("activities")
      .select("title")
      .eq("id", message.activity_id)
      .single();

    if (activityError) {
      throw activityError;
    }

    logger.info("push_activity_loaded", {
      activity_id: message.activity_id,
      message_id: message.id,
      has_title: Boolean((activity as ActivityRow | null)?.title),
    });

    const { data: recipients, error: recipientsError } = await supabaseAdmin
      .rpc("activity_chat_push_recipient_ids", {
        p_activity_id: message.activity_id,
        p_sender_id: message.sender_id,
      });

    if (recipientsError) {
      throw recipientsError;
    }

    const recipientIds = new Set<string>(
      ((recipients ?? []) as PushRecipientRow[])
        .map((recipient) => recipient.profile_id?.toString() ?? "")
        .filter((profileId) => profileId.length > 0),
    );
    logger.info("push_recipients_resolved", {
      activity_id: message.activity_id,
      message_id: message.id,
      recipient_count: recipientIds.size,
    });
    if (recipientIds.size === 0) {
      logger.info("push_skipped_no_recipients", {
        activity_id: message.activity_id,
        message_id: message.id,
      });
      return;
    }

    const { data: tokenRows, error: tokenError } = await supabaseAdmin
      .from("device_push_tokens")
      .select("token,platform")
      .eq("enabled", true)
      .in("profile_id", [...recipientIds]);

    if (tokenError) {
      throw tokenError;
    }

    const pushTargetsByToken = new Map<string, PushTarget>();
    for (const row of (tokenRows ?? []) as PushTokenRow[]) {
      const token = row.token?.toString() ?? "";
      if (token.length === 0 || pushTargetsByToken.has(token)) {
        continue;
      }
      pushTargetsByToken.set(token, {
        token,
        platform: row.platform?.toString().trim().toLowerCase() || null,
      });
    }
    const pushTargets = [...pushTargetsByToken.values()];
    logger.info("push_tokens_resolved", {
      activity_id: message.activity_id,
      message_id: message.id,
      recipient_count: recipientIds.size,
      token_count: pushTargets.length,
      android_token_count: pushTargets.filter((target) =>
        target.platform === "android"
      ).length,
      ios_token_count: pushTargets.filter((target) => target.platform === "ios")
        .length,
    });
    if (pushTargets.length === 0) {
      logger.info("push_skipped_no_tokens", {
        activity_id: message.activity_id,
        message_id: message.id,
        recipient_count: recipientIds.size,
      });
      return;
    }

    logger.info("push_fcm_access_token_request_started", {
      activity_id: message.activity_id,
      message_id: message.id,
    });
    const accessToken = await createFcmAccessToken(config.serviceAccount);
    logger.info("push_fcm_access_token_created", {
      activity_id: message.activity_id,
      message_id: message.id,
    });
    const endpoint =
      `https://fcm.googleapis.com/v1/projects/${config.projectId}/messages:send`;
    const activityTitle = ((activity as ActivityRow | null)?.title ?? "")
      .trim() || "Nieuwe chat";
    const body = notificationBody(message);

    const sendResults = await Promise.all(pushTargets.map(async (target) => {
      const response = await fetch(endpoint, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          message: fcmMessageForTarget({ target, activityTitle, body, message }),
        }),
      });

      if (!response.ok) {
        const errorCode = await fcmSendErrorCode(response);
        logger.warn("push_send_failed", {
          status: response.status,
          error_code: errorCode,
          activity_id: message.activity_id,
          message_id: message.id,
          platform: target.platform,
        });
        if (shouldDisablePushToken(errorCode)) {
          await disablePushTokenBestEffort({
            supabaseAdmin,
            token: target.token,
            logger,
          });
          return {
            ok: false,
            status: response.status,
            errorCode,
            disabledToken: true,
          } satisfies FcmSendResult;
        }
        return {
          ok: false,
          status: response.status,
          errorCode,
          disabledToken: false,
        } satisfies FcmSendResult;
      }

      return {
        ok: true,
        status: response.status,
        errorCode: null,
        disabledToken: false,
      } satisfies FcmSendResult;
    }));

    const statusCounts = sendResults.reduce<Record<string, number>>(
      (counts, result) => {
        const key = result.errorCode ?? result.status.toString();
        counts[key] = (counts[key] ?? 0) + 1;
        return counts;
      },
      {},
    );
    const successCount = sendResults.filter((result) => result.ok).length;
    const disabledTokenCount = sendResults.filter((result) =>
      result.disabledToken
    ).length;

    logger.info("push_send_attempted", {
      activity_id: message.activity_id,
      message_id: message.id,
      token_count: pushTargets.length,
      success_count: successCount,
      failure_count: sendResults.length - successCount,
      disabled_token_count: disabledTokenCount,
      status_counts: statusCounts,
    });
  } catch (error) {
    logger.warn("push_best_effort_failed", errorFields(error));
  }
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

    if (
      req.method !== "GET" &&
      req.method !== "POST" &&
      req.method !== "PATCH"
    ) {
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

      if (req.method === "PATCH") {
        const input = await readJsonBody<MarkActivityChatReadRequest>(req);
        const activityId = requiredUuid(input.activity_id, "activity_id");
        const messageId = optionalUuid(input.message_id, "message_id");

        logger.info("mark_read_request_validated", {
          activity_id: activityId,
          message_id: messageId,
        });

        const { data, error } = await ctx.supabase
          .rpc("mark_activity_chat_read", {
            p_activity_id: activityId,
            p_message_id: messageId,
          })
          .single();

        if (error) {
          const message = error.message ?? "";
          const status = statusForChatError(message);
          logger.error("mark_read_rpc_failed", { error, status });
          return errorResponse(
            messageForChatError(message),
            status,
            error,
            responseHeaders,
          );
        }

        const response: MarkActivityChatReadResponse = {
          summary: data as ActivityChatSummary,
        };

        logger.info("mark_read_response_sent", {
          status: 200,
          activity_id: activityId,
          unread_count: response.summary.unread_count,
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
        was_inserted: response.message.was_inserted,
      });

      if (response.message.was_inserted !== false) {
        await sendChatPushBestEffort({
          supabaseAdmin: ctx.supabaseAdmin,
          message: response.message,
          logger,
        });
      } else {
        logger.info("push_skipped_duplicate_client_message", {
          activity_id: response.message.activity_id,
          message_id: response.message.id,
        });
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
