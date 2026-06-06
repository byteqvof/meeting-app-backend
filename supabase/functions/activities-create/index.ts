import { withSupabase } from "npm:@supabase/server";
import type {
  Activity,
  ActivityCategory,
  CreateActivityRequest,
  CreateActivityResponse,
} from "../_shared/activity-model.ts";
import { errorResponse, jsonResponse, readJsonBody } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";
import {
  optionalCountryCode,
  optionalCurrency,
  optionalInteger,
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

function optionalBoolean(
  value: unknown,
  field: string,
  fallback = false,
): boolean {
  if (value === undefined || value === null || value === "") {
    return fallback;
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
  fallback: T,
): T {
  if (value === undefined || value === null || value === "") {
    return fallback;
  }

  if (typeof value !== "string") {
    throw new Error(`${field} must be a string`);
  }

  const normalized = value.trim() as T;
  if (!allowed.includes(normalized)) {
    throw new Error(`${field} is invalid`);
  }

  return normalized;
}

function optionalStringArray(
  value: unknown,
  field: string,
  allowed: Set<string>,
): string[] {
  if (value === undefined || value === null || value === "") {
    return [];
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

function normalizeCreateRequest(input: CreateActivityRequest) {
  const startsAt = requiredIsoDate(input.starts_at, "starts_at");
  const endsAt = optionalIsoDate(input.ends_at, "ends_at");

  if (endsAt && new Date(endsAt).getTime() <= new Date(startsAt).getTime()) {
    throw new Error("ends_at must be after starts_at");
  }

  return {
    category_id: requiredUuid(input.category_id, "category_id"),
    title: requiredString(input.title, "title", 3, 120),
    description: requiredString(input.description, "description", 10, 4000),
    latitude: requiredNumber(input.latitude, "latitude", -90, 90),
    longitude: requiredNumber(input.longitude, "longitude", -180, 180),
    address_line: optionalString(input.address_line, "address_line", 240),
    city: optionalString(input.city, "city", 120),
    country_code: optionalCountryCode(input.country_code),
    starts_at: startsAt,
    ends_at: endsAt,
    max_participants: optionalInteger(
      input.max_participants,
      "max_participants",
      1,
      10000,
    ),
    price_cents: optionalMoneyCents(input.price_cents, "price_cents"),
    currency: optionalCurrency(input.currency),
    image_url: optionalUrl(input.image_url, "image_url"),
    group_type: optionalEnum(
      input.group_type,
      "group_type",
      ["open", "approval", "closed"] as const,
      "open",
    ),
    min_reputation_level: optionalEnum(
      input.min_reputation_level,
      "min_reputation_level",
      [
        "new_member",
        "active_member",
        "known_member",
        "top_participant",
      ] as const,
      "new_member",
    ),
    requires_identity_verified: optionalBoolean(
      input.requires_identity_verified,
      "requires_identity_verified",
    ),
    is_private_location: optionalBoolean(
      input.is_private_location,
      "is_private_location",
    ),
    target_age_bands: optionalStringArray(
      input.target_age_bands,
      "target_age_bands",
      ACTIVITY_TARGET_AGE_BANDS,
    ),
    target_genders: optionalStringArray(
      input.target_genders,
      "target_genders",
      ACTIVITY_TARGET_GENDERS,
    ),
    metadata: optionalMetadata(input.metadata),
  };
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("activities-create", req);
    const responseHeaders = { "x-request-id": logger.requestId };

    logger.info("request_received", {
      method: req.method,
      path: new URL(req.url).pathname,
      auth_mode: ctx.authMode,
      user_id: ctx.userClaims?.id,
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
      const payload = normalizeCreateRequest(
        await readJsonBody<CreateActivityRequest>(req),
      );

      logger.info("request_validated", {
        category_id: payload.category_id,
        city: payload.city,
        country_code: payload.country_code,
        starts_at: payload.starts_at,
        has_end_time: payload.ends_at !== null,
        has_image: payload.image_url !== null,
        max_participants: payload.max_participants,
        price_cents: payload.price_cents,
        currency: payload.currency,
        target_age_band_count: payload.target_age_bands.length,
        target_gender_count: payload.target_genders.length,
      });

      const { data, error } = await ctx.supabase
        .from("activities")
        .insert({
          ...payload,
          organizer_id: ctx.userClaims.id,
          status: "published",
        })
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

      if (error) {
        logger.error("insert_failed", { error });
        return errorResponse(
          "Could not create activity",
          500,
          error,
          responseHeaders,
        );
      }

      logger.info("insert_succeeded", {
        activity_id: data.id,
        category_id: data.category_id,
        organizer_id: data.organizer_id,
      });

      const response: CreateActivityResponse = {
        activity: data as Activity & { category: ActivityCategory },
      };

      logger.info("response_sent", {
        status: 201,
        activity_id: response.activity.id,
      });

      return jsonResponse(response, { status: 201, headers: responseHeaders });
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
