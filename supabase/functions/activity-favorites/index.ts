import { withSupabase } from "npm:@supabase/server";
import { errorResponse, jsonResponse, readJsonBody } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";
import { requiredUuid } from "../_shared/validation.ts";

interface ActivityFavoriteRequest {
  activity_id?: string;
  is_favorited?: boolean;
}

function statusForFavoriteError(message: string): number {
  if (message.includes("AUTH_REQUIRED")) {
    return 401;
  }
  if (message.includes("ACTIVITY_NOT_FOUND")) {
    return 404;
  }
  return 500;
}

function messageForFavoriteError(message: string): string {
  if (message.includes("AUTH_REQUIRED")) {
    return "Missing authenticated user";
  }
  if (message.includes("ACTIVITY_NOT_FOUND")) {
    return "Activity not found";
  }
  return "Could not update activity favorite";
}

function requiredBoolean(value: unknown, field: string): boolean {
  if (typeof value === "boolean") {
    return value;
  }
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    if (normalized === "true" || normalized === "1") {
      return true;
    }
    if (normalized === "false" || normalized === "0") {
      return false;
    }
  }
  throw new Error(`${field} must be a boolean`);
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("activity-favorites", req);
    const responseHeaders = { "x-request-id": logger.requestId };
    const userId = ctx.userClaims?.id;
    const url = new URL(req.url);

    logger.info("request_received", {
      method: req.method,
      path: url.pathname,
      auth_mode: ctx.authMode,
      user_id: userId,
    });

    if (req.method !== "GET" && req.method !== "POST") {
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
      if (req.method === "GET") {
        const activityId = requiredUuid(
          url.searchParams.get("activity_id") ?? url.searchParams.get("id"),
          "activity_id",
        );

        const { data, error } = await ctx.supabase.rpc(
          "get_activity_favorite_status",
          { p_activity_id: activityId },
        );

        if (error) {
          const message = error.message ?? "";
          const status = statusForFavoriteError(message);
          logger.error("favorite_status_rpc_failed", { error, status });
          return errorResponse(
            messageForFavoriteError(message),
            status,
            error,
            responseHeaders,
          );
        }

        return jsonResponse(
          { activity_id: activityId, is_favorited: Boolean(data) },
          { headers: responseHeaders },
        );
      }

      const input = await readJsonBody<ActivityFavoriteRequest>(req);
      const activityId = requiredUuid(input.activity_id, "activity_id");
      const isFavorited = requiredBoolean(
        input.is_favorited,
        "is_favorited",
      );

      const { data, error } = await ctx.supabase
        .rpc("set_activity_favorite", {
          p_activity_id: activityId,
          p_is_favorited: isFavorited,
        })
        .single();

      if (error) {
        const message = error.message ?? "";
        const status = statusForFavoriteError(message);
        logger.error("favorite_update_rpc_failed", { error, status });
        return errorResponse(
          messageForFavoriteError(message),
          status,
          error,
          responseHeaders,
        );
      }

      const favorite = data as { activity_id: string; is_favorited: boolean };
      logger.info("favorite_updated", {
        activity_id: favorite.activity_id,
        is_favorited: favorite.is_favorited,
      });

      return jsonResponse(favorite, { headers: responseHeaders });
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
