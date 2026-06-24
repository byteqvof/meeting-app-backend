import { withSupabase } from "npm:@supabase/server";
import { errorResponse, jsonResponse, readJsonBody } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";
import { optionalString, optionalUuid, requiredString, requiredUuid } from "../_shared/validation.ts";

interface FriendshipActionRequest {
  action?: string;
  profile_id?: string;
}

function statusForFriendError(message: string): number {
  if (message.includes("AUTH_REQUIRED")) {
    return 401;
  }
  if (message.includes("FRIEND_PROFILE_NOT_FOUND")) {
    return 404;
  }
  if (message.includes("FRIEND_BLOCKED")) {
    return 403;
  }
  if (message.includes("FRIEND_SELF") || message.includes("FRIEND_REQUEST_NOT_FOUND")) {
    return 409;
  }
  if (message.includes("FRIEND_ACTION_INVALID")) {
    return 400;
  }
  return 500;
}

function messageForFriendError(message: string): string {
  if (message.includes("FRIEND_PROFILE_NOT_FOUND")) {
    return "Profile not found";
  }
  if (message.includes("FRIEND_BLOCKED")) {
    return "Friend request is not available for this profile";
  }
  if (message.includes("FRIEND_SELF")) {
    return "You cannot add yourself as a friend";
  }
  if (message.includes("FRIEND_REQUEST_NOT_FOUND")) {
    return "Friend request not found";
  }
  if (message.includes("FRIEND_ACTION_INVALID")) {
    return "Friend action is invalid";
  }
  return "Could not update friends";
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("friends", req);
    const responseHeaders = { "x-request-id": logger.requestId };
    const url = new URL(req.url);
    const userId = ctx.userClaims?.id;

    logger.info("request_received", {
      method: req.method,
      path: url.pathname,
      auth_mode: ctx.authMode,
      user_id: userId,
    });

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
        const profileId = optionalUuid(
          url.searchParams.get("profile_id") ?? url.searchParams.get("profileId"),
          "profile_id",
        );

        if (profileId) {
          const { data, error } = await ctx.supabase.rpc(
            "profile_friendship_status",
            {
              p_profile_id: profileId,
              p_user_id: userId,
            },
          );

          if (error) {
            logger.error("status_rpc_failed", { error });
            return errorResponse(
              "Could not fetch friend status",
              500,
              error,
              responseHeaders,
            );
          }

          return jsonResponse(
            {
              friendship: {
                profile_id: profileId,
                status: String(data ?? "none"),
              },
            },
            { headers: responseHeaders },
          );
        }

        const status = optionalString(
          url.searchParams.get("status"),
          "status",
          30,
        );
        const { data, error } = await ctx.supabase.rpc(
          "list_profile_friendships",
          { p_status: status },
        );

        if (error) {
          logger.error("list_rpc_failed", { error });
          return errorResponse(
            "Could not fetch friends",
            500,
            error,
            responseHeaders,
          );
        }

        return jsonResponse(
          { friendships: data ?? [] },
          { headers: responseHeaders },
        );
      }

      if (req.method !== "POST") {
        return errorResponse(
          "Method not allowed",
          405,
          undefined,
          responseHeaders,
        );
      }

      const input = await readJsonBody<FriendshipActionRequest>(req);
      const action = requiredString(input.action, "action", 3, 30);
      const profileId = requiredUuid(input.profile_id, "profile_id");

      const { data, error } = await ctx.supabase
        .rpc("set_profile_friendship", {
          p_target_profile_id: profileId,
          p_action: action,
        })
        .single();

      if (error) {
        const message = error.message ?? "";
        const status = statusForFriendError(message);
        logger.error("action_rpc_failed", { error, status });
        return errorResponse(
          messageForFriendError(message),
          status,
          error,
          responseHeaders,
        );
      }

      logger.info("friendship_updated", {
        profile_id: profileId,
        action,
      });

      return jsonResponse(
        { friendship: data },
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
