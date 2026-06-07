import { withSupabase } from "npm:@supabase/server";
import { errorResponse, jsonResponse, readJsonBody } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";
import { optionalString, requiredString } from "../_shared/validation.ts";

interface PushTokenRequest {
  token?: string;
  platform?: string;
  device_id?: string | null;
  app_version?: string | null;
}

function normalizePlatform(value: unknown): "android" | "ios" {
  const platform = requiredString(value, "platform", 3, 16).toLowerCase();
  if (platform !== "android" && platform !== "ios") {
    throw new Error("platform must be android or ios");
  }
  return platform;
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("push-token", req);
    const responseHeaders = { "x-request-id": logger.requestId };
    const userId = ctx.userClaims?.id;

    logger.info("request_received", {
      method: req.method,
      auth_mode: ctx.authMode,
      user_id: userId,
    });

    if (req.method !== "POST" && req.method !== "DELETE") {
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
      const input = await readJsonBody<PushTokenRequest>(req);
      const token = requiredString(input.token, "token", 20, 4096);

      if (req.method === "DELETE") {
        const { error } = await ctx.supabase
          .from("device_push_tokens")
          .update({ enabled: false, last_seen_at: new Date().toISOString() })
          .eq("profile_id", userId)
          .eq("token", token);

        if (error) {
          logger.error("push_token_disable_failed", { error });
          return errorResponse(
            "Could not disable push token",
            500,
            error,
            responseHeaders,
          );
        }

        logger.info("push_token_disabled");
        return jsonResponse({ ok: true }, { headers: responseHeaders });
      }

      const platform = normalizePlatform(input.platform);
      const deviceId = optionalString(input.device_id, "device_id", 180);
      const appVersion = optionalString(input.app_version, "app_version", 80);
      const now = new Date().toISOString();

      const { error } = await ctx.supabase
        .from("device_push_tokens")
        .upsert(
          {
            profile_id: userId,
            token,
            platform,
            device_id: deviceId,
            app_version: appVersion,
            enabled: true,
            last_seen_at: now,
          },
          { onConflict: "token" },
        );

      if (error) {
        logger.error("push_token_upsert_failed", { error });
        return errorResponse(
          "Could not save push token",
          500,
          error,
          responseHeaders,
        );
      }

      logger.info("push_token_saved", { platform });
      return jsonResponse({ ok: true }, { headers: responseHeaders });
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
