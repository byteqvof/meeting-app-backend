import { withSupabase } from "npm:@supabase/server";
import type {
  AccountTrustResponse,
  ProfileTrust,
} from "../_shared/profile-model.ts";
import { errorResponse, jsonResponse, readJsonBody } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";

interface TrustRow {
  phone_verified: boolean;
  phone_verified_at: string | null;
  identity_status: ProfileTrust["identity_status"];
  identity_method: ProfileTrust["identity_method"];
  identity_completed_at: string | null;
  age_verified: boolean;
  reputation_level: ProfileTrust["reputation_level"];
  reputation_score: number | string;
}

interface AccountTrustRequest {
  action?: string;
  verified_at?: string;
}

function mapTrust(row: TrustRow): ProfileTrust {
  return {
    phone_verified: row.phone_verified === true,
    phone_verified_at: row.phone_verified_at,
    identity_status: row.identity_status ?? "unverified",
    identity_method: row.identity_method ?? null,
    identity_completed_at: row.identity_completed_at,
    age_verified: row.age_verified === true,
    reputation_level: row.reputation_level ?? "new_member",
    reputation_score: Number(row.reputation_score ?? 0),
  };
}

function devPhoneVerificationAllowed(): boolean {
  return (
    Deno.env.get("TOCH_ALLOW_DEV_PHONE_VERIFICATION")?.trim().toLowerCase() ===
      "true"
  );
}

function verifiedAtFromInput(input: AccountTrustRequest): string {
  if (!input.verified_at) {
    return new Date().toISOString();
  }

  const parsed = new Date(input.verified_at);
  if (Number.isNaN(parsed.getTime())) {
    throw new Error("verified_at is invalid");
  }

  return parsed.toISOString();
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("account-trust", req);
    const responseHeaders = { "x-request-id": logger.requestId };
    const userId = ctx.userClaims?.id;

    logger.info("request_received", {
      method: req.method,
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

    if (req.method === "POST") {
      try {
        const input = await readJsonBody<AccountTrustRequest>(req);
        if (input.action === "dev_verify_phone") {
          if (!devPhoneVerificationAllowed()) {
            logger.warn("dev_phone_verification_disabled");
            return errorResponse(
              "Development phone verification is disabled",
              403,
              undefined,
              responseHeaders,
            );
          }

          const verifiedAt = verifiedAtFromInput(input);
          const { data, error } = await ctx.supabaseAdmin
            .from("profile_trust")
            .upsert(
              {
                profile_id: userId,
                phone_verified: true,
                phone_verified_at: verifiedAt,
              },
              { onConflict: "profile_id" },
            )
            .select(
              `
                phone_verified,
                phone_verified_at,
                identity_status,
                identity_method,
                identity_completed_at,
                age_verified,
                reputation_level,
                reputation_score
              `,
            )
            .single();

          if (error || data === null) {
            logger.error("dev_phone_verification_failed", { error });
            return errorResponse(
              "Could not sync development phone verification",
              500,
              error,
              responseHeaders,
            );
          }

          const response: AccountTrustResponse = {
            trust: mapTrust(data as TrustRow),
          };

          logger.info("dev_phone_verification_succeeded", {
            phone_verified: response.trust.phone_verified,
          });

          return jsonResponse(response, { headers: responseHeaders });
        }
      } catch (error) {
        logger.warn("request_failed", errorFields(error));
        return errorResponse(
          error instanceof Error ? error.message : "Invalid request",
          400,
          undefined,
          responseHeaders,
        );
      }
    }

    const { data, error } = await ctx.supabase
      .rpc("sync_current_user_trust")
      .single();

    if (error || data === null) {
      logger.error("trust_sync_failed", { error });
      return errorResponse(
        "Could not sync account trust",
        500,
        error,
        responseHeaders,
      );
    }

    const response: AccountTrustResponse = {
      trust: mapTrust(data as TrustRow),
    };

    logger.info("trust_sync_succeeded", {
      phone_verified: response.trust.phone_verified,
      identity_status: response.trust.identity_status,
      reputation_level: response.trust.reputation_level,
    });

    return jsonResponse(response, { headers: responseHeaders });
  }),
};
