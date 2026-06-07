import { withSupabase } from "npm:@supabase/server";
import type {
  NearbyActivitiesRequest,
  NearbyActivity,
  NearbyActivitiesResponse,
} from "../_shared/activity-model.ts";
import { errorResponse, jsonResponse, readJsonBody } from "../_shared/http.ts";
import {
  createRequestLogger,
  errorFields,
  roundCoordinate,
} from "../_shared/logger.ts";
import {
  optionalInteger,
  optionalIsoDate,
  requiredUuid,
  requiredNumber,
} from "../_shared/validation.ts";

const TARGET_AGE_BANDS = new Set([
  "18_24",
  "25_34",
  "35_44",
  "45_54",
  "55_64",
  "65_plus",
]);
const TARGET_GENDERS = new Set([
  "woman",
  "man",
  "non_binary",
  "prefer_not_to_say",
]);
const ACTIVITY_SORTS = new Set(["distance", "start_time", "participants"]);

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

function parseArrayValue(value: unknown, field: string): unknown[] {
  if (value === undefined || value === null || value === "") {
    return [];
  }

  if (Array.isArray(value)) {
    return value;
  }

  if (typeof value === "string") {
    const trimmed = value.trim();
    if (trimmed === "") {
      return [];
    }

    if (trimmed.startsWith("[")) {
      const parsed = JSON.parse(trimmed);
      if (!Array.isArray(parsed)) {
        throw new Error(`${field} must be an array`);
      }
      return parsed;
    }

    return trimmed.split(",").map((item) => item.trim()).filter(Boolean);
  }

  throw new Error(`${field} must be an array`);
}

function urlArray(url: URL, ...keys: string[]): string[] {
  return keys.flatMap((key) => url.searchParams.getAll(key)).flatMap((value) =>
    parseArrayValue(value, keys[0]) as string[]
  );
}

function optionalUuidArray(value: unknown, field: string): string[] {
  return [
    ...new Set(
      parseArrayValue(value, field).map((item) => requiredUuid(item, field)),
    ),
  ];
}

function optionalAllowedStringArray(
  value: unknown,
  field: string,
  allowed: Set<string>,
): string[] {
  return [
    ...new Set(
      parseArrayValue(value, field).map((item) => {
        if (typeof item !== "string") {
          throw new Error(`${field} must contain strings`);
        }

        const normalized = item.trim();
        if (!allowed.has(normalized)) {
          throw new Error(`${field} contains an invalid value`);
        }

        return normalized;
      }),
    ),
  ];
}

function optionalSort(
  value: unknown,
): NearbyActivitiesRequest["sort"] {
  if (value === undefined || value === null || value === "") {
    return "distance";
  }

  if (typeof value !== "string" || !ACTIVITY_SORTS.has(value.trim())) {
    throw new Error("sort must be distance, start_time, or participants");
  }

  return value.trim() as NearbyActivitiesRequest["sort"];
}

function requestFromUrl(req: Request): NearbyActivitiesRequest {
  const url = new URL(req.url);
  const categoryIds = urlArray(
    url,
    "category_ids",
    "category_ids[]",
    "categoryIds",
    "categoryIds[]",
  );
  const legacyCategoryId = url.searchParams.get("category_id") ??
    url.searchParams.get("categoryId");

  return {
    latitude: requiredNumber(
      url.searchParams.get("latitude") ?? url.searchParams.get("lat"),
      "latitude",
      -90,
      90,
    ),
    longitude: requiredNumber(
      url.searchParams.get("longitude") ?? url.searchParams.get("lng"),
      "longitude",
      -180,
      180,
    ),
    radius_km: requiredNumber(
      url.searchParams.get("radius_km") ??
        url.searchParams.get("radiusKm") ??
        "10",
      "radius_km",
      0.1,
      100,
    ),
    category_id: legacyCategoryId,
    category_ids: categoryIds,
    date_from: url.searchParams.get("date_from") ??
      url.searchParams.get("dateFrom"),
    date_to: url.searchParams.get("date_to") ?? url.searchParams.get("dateTo"),
    target_age_bands: urlArray(
      url,
      "target_age_bands",
      "target_age_bands[]",
      "targetAgeBands",
      "targetAgeBands[]",
    ),
    target_genders: urlArray(
      url,
      "target_genders",
      "target_genders[]",
      "targetGenders",
      "targetGenders[]",
    ),
    requires_identity_verified: optionalBoolean(
      url.searchParams.get("requires_identity_verified") ??
        url.searchParams.get("requiresIdentityVerified"),
      "requires_identity_verified",
    ),
    available_only: optionalBoolean(
      url.searchParams.get("available_only") ??
        url.searchParams.get("availableOnly"),
      "available_only",
    ),
    min_participants: optionalInteger(
      url.searchParams.get("min_participants") ??
        url.searchParams.get("minParticipants"),
      "min_participants",
      0,
      10000,
    ),
    max_participants: optionalInteger(
      url.searchParams.get("max_participants") ??
        url.searchParams.get("maxParticipants"),
      "max_participants",
      0,
      10000,
    ),
    sort: optionalSort(url.searchParams.get("sort")),
    limit:
      optionalInteger(url.searchParams.get("limit") ?? "50", "limit", 1, 100) ??
      50,
  };
}

function normalizeRequest(
  input: NearbyActivitiesRequest,
): NearbyActivitiesRequest {
  const legacyCategoryIds = input.category_id
    ? [requiredUuid(input.category_id, "category_id")]
    : [];
  const categoryIds = [
    ...legacyCategoryIds,
    ...optionalUuidArray(input.category_ids, "category_ids"),
  ];
  const minParticipants = optionalInteger(
    input.min_participants,
    "min_participants",
    0,
    10000,
  );
  const maxParticipants = optionalInteger(
    input.max_participants,
    "max_participants",
    0,
    10000,
  );

  if (
    minParticipants !== null &&
    maxParticipants !== null &&
    minParticipants > maxParticipants
  ) {
    throw new Error("min_participants must be lower than max_participants");
  }

  const dateFrom = optionalIsoDate(input.date_from, "date_from");
  const dateTo = optionalIsoDate(input.date_to, "date_to");
  if (
    dateFrom !== null &&
    dateTo !== null &&
    new Date(dateFrom).getTime() > new Date(dateTo).getTime()
  ) {
    throw new Error("date_from must be before date_to");
  }

  return {
    latitude: requiredNumber(input.latitude, "latitude", -90, 90),
    longitude: requiredNumber(input.longitude, "longitude", -180, 180),
    radius_km: requiredNumber(input.radius_km ?? 10, "radius_km", 0.1, 100),
    category_id: categoryIds[0] ?? null,
    category_ids: [...new Set(categoryIds)],
    date_from: dateFrom,
    date_to: dateTo,
    target_age_bands: optionalAllowedStringArray(
      input.target_age_bands,
      "target_age_bands",
      TARGET_AGE_BANDS,
    ),
    target_genders: optionalAllowedStringArray(
      input.target_genders,
      "target_genders",
      TARGET_GENDERS,
    ),
    requires_identity_verified: optionalBoolean(
      input.requires_identity_verified,
      "requires_identity_verified",
    ),
    available_only: optionalBoolean(input.available_only, "available_only"),
    min_participants: minParticipants,
    max_participants: maxParticipants,
    sort: optionalSort(input.sort),
    limit: optionalInteger(input.limit ?? 50, "limit", 1, 100) ?? 50,
  };
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("activities-nearby", req);
    const responseHeaders = { "x-request-id": logger.requestId };

    logger.info("request_received", {
      method: req.method,
      path: new URL(req.url).pathname,
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

    try {
      const request =
        req.method === "GET"
          ? normalizeRequest(requestFromUrl(req))
          : normalizeRequest(await readJsonBody<NearbyActivitiesRequest>(req));

      logger.info("request_validated", {
        latitude: roundCoordinate(request.latitude),
        longitude: roundCoordinate(request.longitude),
        radius_km: request.radius_km,
        category_count: request.category_ids?.length ?? 0,
        date_from: request.date_from,
        date_to: request.date_to,
        target_age_band_count: request.target_age_bands?.length ?? 0,
        target_gender_count: request.target_genders?.length ?? 0,
        requires_identity_verified: request.requires_identity_verified,
        available_only: request.available_only,
        min_participants: request.min_participants,
        max_participants: request.max_participants,
        sort: request.sort,
        limit: request.limit,
      });

      const { data, error } = await ctx.supabase.rpc(
        "search_activities_nearby",
        {
          p_latitude: request.latitude,
          p_longitude: request.longitude,
          p_radius_km: request.radius_km,
          p_category_ids: request.category_ids,
          p_date_from: request.date_from,
          p_date_to: request.date_to,
          p_target_age_bands: request.target_age_bands,
          p_target_genders: request.target_genders,
          p_requires_identity_verified: request.requires_identity_verified,
          p_available_only: request.available_only,
          p_min_participants: request.min_participants,
          p_max_participants: request.max_participants,
          p_sort: request.sort,
          p_limit: request.limit,
        },
      );

      if (error) {
        logger.error("rpc_failed", { error });
        return errorResponse(
          "Could not fetch nearby activities",
          500,
          error,
          responseHeaders,
        );
      }

      logger.info("rpc_succeeded", {
        activity_count: data?.length ?? 0,
      });

      const response: NearbyActivitiesResponse = {
        activities: (data ?? []) as NearbyActivity[],
        filters: {
          latitude: request.latitude,
          longitude: request.longitude,
          radius_km: request.radius_km ?? 10,
          category_id: request.category_id ?? null,
          category_ids: request.category_ids ?? [],
          date_from: request.date_from ?? null,
          date_to: request.date_to ?? null,
          target_age_bands: request.target_age_bands ?? [],
          target_genders: request.target_genders ?? [],
          requires_identity_verified:
            request.requires_identity_verified ?? false,
          available_only: request.available_only ?? false,
          min_participants: request.min_participants ?? null,
          max_participants: request.max_participants ?? null,
          sort: request.sort ?? "distance",
          limit: request.limit ?? 50,
        },
      };

      logger.info("response_sent", {
        status: 200,
        activity_count: response.activities.length,
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
