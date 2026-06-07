import { withSupabase } from "npm:@supabase/server";
import type {
  Activity,
  ActivityCategory,
  CreateActivityResponse,
} from "../_shared/activity-model.ts";
import { errorResponse, jsonResponse, readJsonBody } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";
import {
  optionalCountryCode,
  optionalCurrency,
  optionalIsoDate,
  optionalMetadata,
  optionalMoneyCents,
  optionalString,
  optionalUrl,
  requiredIsoDate,
  requiredNumber,
  requiredString,
  requiredUuid,
} from "../_shared/validation.ts";

const ACTIVITY_TARGET_AGE_BANDS = new Set([
  "18_24",
  "25_34",
  "35_44",
  "45_54",
  "55_64",
  "65_plus",
]);
const ACTIVITY_TARGET_GENDERS = new Set([
  "woman",
  "man",
  "non_binary",
  "prefer_not_to_say",
]);

interface UpdateActivityRequest {
  activity_id?: string;
  category_id?: string;
  title?: string;
  description?: string;
  latitude?: number;
  longitude?: number;
  address_line?: string | null;
  city?: string | null;
  country_code?: string;
  starts_at?: string;
  ends_at?: string | null;
  max_participants?: number | null;
  price_cents?: number;
  currency?: string;
  image_url?: string | null;
  group_type?: string;
  min_reputation_level?: string;
  requires_identity_verified?: boolean;
  is_private_location?: boolean;
  target_age_bands?: string[];
  target_genders?: string[];
  metadata?: Record<string, unknown>;
}

function optionalBoolean(value: unknown, field: string): boolean | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value === "boolean") {
    return value;
  }
  throw new Error(`${field} must be a boolean`);
}

function optionalEnum<T extends string>(
  value: unknown,
  field: string,
  allowed: readonly T[],
): T | undefined {
  if (value === undefined || value === null || value === "") {
    return undefined;
  }
  if (typeof value !== "string" || !allowed.includes(value as T)) {
    throw new Error(`${field} has an invalid value`);
  }
  return value as T;
}

function optionalStringArray(
  value: unknown,
  field: string,
  allowed: Set<string>,
): string[] | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (!Array.isArray(value)) {
    throw new Error(`${field} must be an array`);
  }
  const normalized = value.map((item) => {
    if (typeof item !== "string") {
      throw new Error(`${field} must contain strings`);
    }
    const trimmed = item.trim();
    if (!allowed.has(trimmed)) {
      throw new Error(`${field} contains an invalid value`);
    }
    return trimmed;
  });
  return [...new Set(normalized)];
}

function optionalInteger(
  value: unknown,
  field: string,
  min: number,
  max: number,
): number | null | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (value === null || value === "") {
    return null;
  }
  const numberValue = Number(value);
  if (
    !Number.isInteger(numberValue) ||
    numberValue < min ||
    numberValue > max
  ) {
    throw new Error(`${field} must be an integer between ${min} and ${max}`);
  }
  return numberValue;
}

function normalizeUpdatePayload(input: UpdateActivityRequest) {
  const payload: Record<string, unknown> = {};

  if (input.category_id !== undefined) {
    payload.category_id = requiredUuid(input.category_id, "category_id");
  }
  if (input.title !== undefined) {
    payload.title = requiredString(input.title, "title", 3, 120);
  }
  if (input.description !== undefined) {
    payload.description = requiredString(
      input.description,
      "description",
      10,
      4000,
    );
  }

  const touchesLocation =
    input.latitude !== undefined ||
    input.longitude !== undefined ||
    input.address_line !== undefined ||
    input.city !== undefined;
  if (touchesLocation) {
    payload.latitude = requiredNumber(input.latitude, "latitude", -90, 90);
    payload.longitude = requiredNumber(input.longitude, "longitude", -180, 180);
    payload.address_line = requiredString(
      input.address_line,
      "address_line",
      3,
      240,
    );
    payload.city = optionalString(input.city, "city", 120);
  }

  if (input.country_code !== undefined) {
    payload.country_code = optionalCountryCode(input.country_code);
  }
  if (input.starts_at !== undefined) {
    payload.starts_at = requiredIsoDate(input.starts_at, "starts_at");
  }
  if (input.ends_at !== undefined) {
    payload.ends_at = optionalIsoDate(input.ends_at, "ends_at");
  }
  if (input.max_participants !== undefined) {
    payload.max_participants = optionalInteger(
      input.max_participants,
      "max_participants",
      1,
      10000,
    );
  }
  if (input.price_cents !== undefined) {
    payload.price_cents = optionalMoneyCents(
      input.price_cents,
      "price_cents",
    );
  }
  if (input.currency !== undefined) {
    payload.currency = optionalCurrency(input.currency);
  }
  if (input.image_url !== undefined) {
    payload.image_url = optionalUrl(input.image_url, "image_url");
  }
  if (input.group_type !== undefined) {
    payload.group_type = optionalEnum(
      input.group_type,
      "group_type",
      ["open", "approval", "closed"] as const,
    );
  }
  if (input.min_reputation_level !== undefined) {
    payload.min_reputation_level = optionalEnum(
      input.min_reputation_level,
      "min_reputation_level",
      [
        "new_member",
        "active_member",
        "known_member",
        "top_participant",
      ] as const,
    );
  }
  if (input.requires_identity_verified !== undefined) {
    payload.requires_identity_verified = optionalBoolean(
      input.requires_identity_verified,
      "requires_identity_verified",
    );
  }
  if (input.is_private_location !== undefined) {
    payload.is_private_location = optionalBoolean(
      input.is_private_location,
      "is_private_location",
    );
  }
  if (input.target_age_bands !== undefined) {
    payload.target_age_bands = optionalStringArray(
      input.target_age_bands,
      "target_age_bands",
      ACTIVITY_TARGET_AGE_BANDS,
    );
  }
  if (input.target_genders !== undefined) {
    payload.target_genders = optionalStringArray(
      input.target_genders,
      "target_genders",
      ACTIVITY_TARGET_GENDERS,
    );
  }
  if (input.metadata !== undefined) {
    payload.metadata = optionalMetadata(input.metadata);
  }

  if (Object.keys(payload).length === 0) {
    throw new Error("No activity fields supplied");
  }

  return payload;
}

function ensureEndsAfterStart(
  payload: Record<string, unknown>,
  existingStartsAt: string,
) {
  const startsAt = (payload.starts_at as string | undefined) ?? existingStartsAt;
  const endsAt = payload.ends_at as string | null | undefined;
  if (endsAt && new Date(endsAt).getTime() <= new Date(startsAt).getTime()) {
    throw new Error("ends_at must be after starts_at");
  }
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("activities-update", req);
    const responseHeaders = { "x-request-id": logger.requestId };
    const userId = ctx.userClaims?.id;

    logger.info("request_received", {
      method: req.method,
      auth_mode: ctx.authMode,
      user_id: userId,
    });

    if (req.method !== "PATCH" && req.method !== "POST") {
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
      const input = await readJsonBody<UpdateActivityRequest>(req);
      const activityId = requiredUuid(input.activity_id, "activity_id");
      const payload = normalizeUpdatePayload(input);

      const { data: existing, error: existingError } = await ctx.supabase
        .from("activities")
        .select("id,organizer_id,status,starts_at")
        .eq("id", activityId)
        .maybeSingle();

      if (existingError || existing === null) {
        logger.error("activity_fetch_failed", {
          activity_id: activityId,
          error: existingError,
        });
        return errorResponse(
          "Activity not found",
          existingError ? 500 : 404,
          existingError,
          responseHeaders,
        );
      }

      if (existing.organizer_id !== userId) {
        logger.warn("activity_update_forbidden", { activity_id: activityId });
        return errorResponse(
          "Only the organizer can update this activity",
          403,
          undefined,
          responseHeaders,
        );
      }

      if (existing.status === "completed") {
        return errorResponse(
          "Completed activities cannot be updated",
          409,
          undefined,
          responseHeaders,
        );
      }

      ensureEndsAfterStart(payload, existing.starts_at);

      if (payload.max_participants !== undefined) {
        const { count, error: countError } = await ctx.supabase
          .from("activity_participants")
          .select("profile_id", { count: "exact", head: true })
          .eq("activity_id", activityId)
          .in("status", ["joined", "pending"]);

        if (countError) {
          logger.error("participant_count_failed", { error: countError });
          return errorResponse(
            "Could not validate participant count",
            500,
            countError,
            responseHeaders,
          );
        }

        const maxParticipants = payload.max_participants as number | null;
        if (maxParticipants !== null && maxParticipants < (count ?? 0)) {
          return errorResponse(
            "Capacity cannot be lower than current participants",
            409,
            undefined,
            responseHeaders,
          );
        }
      }

      const { data, error } = await ctx.supabase
        .from("activities")
        .update(payload)
        .eq("id", activityId)
        .select(
          `
          id,
          category_id,
          organizer_id,
          title,
          description,
          latitude,
          longitude,
          address_line,
          city,
          country_code,
          starts_at,
          ends_at,
          max_participants,
          price_cents,
          currency,
          image_url,
          status,
          group_type,
          min_reputation_level,
          requires_identity_verified,
          is_private_location,
          target_age_bands,
          target_genders,
          metadata,
          created_at,
          updated_at,
          category:activity_categories (
            id,
            slug,
            title,
            description,
            background_color,
            foreground_color,
            icon_key
          )
        `,
        )
        .single();

      if (error || data === null) {
        logger.error("activity_update_failed", { activity_id: activityId, error });
        return errorResponse(
          "Could not update activity",
          500,
          error,
          responseHeaders,
        );
      }

      const response: CreateActivityResponse = {
        activity: data as Activity & { category: ActivityCategory },
      };

      logger.info("activity_updated", { activity_id: activityId });
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
