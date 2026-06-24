import { withSupabase } from "npm:@supabase/server";
import { errorResponse, jsonResponse } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";
import { optionalInteger, requiredNumber, requiredString } from "../_shared/validation.ts";

const PDOK_BASE_URL = "https://api.pdok.nl/bzk/locatieserver/search/v3_1";
const ALLOWED_TYPES = new Set(["adres", "weg", "postcode", "woonplaats"]);
const DEFAULT_LIMIT = 8;
const MAX_LIMIT = 10;
const PDOK_TIMEOUT_MS = 4500;

type RequestLogger = ReturnType<typeof createRequestLogger>;

interface PdokSuggestDoc {
  id?: unknown;
  weergavenaam?: unknown;
  type?: unknown;
  score?: unknown;
}

interface PdokLookupDoc extends PdokSuggestDoc {
  woonplaatsnaam?: unknown;
  gemeentenaam?: unknown;
  postcode?: unknown;
  straatnaam?: unknown;
  huisnummer?: unknown;
  huisletter?: unknown;
  huisnummertoevoeging?: unknown;
  centroide_ll?: unknown;
}

interface MeetingLocationSuggestion {
  id: string;
  label: string;
  address_line: string;
  city: string;
  postcode: string | null;
  type: string;
  latitude: number;
  longitude: number;
  source: "pdok";
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("locations-search", req);
    const responseHeaders = { "x-request-id": logger.requestId };

    logger.info("request_received", {
      method: req.method,
      path: new URL(req.url).pathname,
      auth_mode: ctx.authMode,
      user_id: ctx.userClaims?.id,
    });

    if (req.method !== "GET") {
      logger.warn("method_not_allowed", { method: req.method });
      return errorResponse(
        "Method not allowed",
        405,
        { request_id: logger.requestId },
        responseHeaders,
      );
    }

    if (!ctx.userClaims?.id) {
      logger.warn("missing_authenticated_user");
      return errorResponse(
        "Missing authenticated user",
        401,
        { request_id: logger.requestId },
        responseHeaders,
      );
    }

    try {
      const url = new URL(req.url);
      const query = requiredString(url.searchParams.get("q"), "q", 3, 120);
      const limit = Math.min(
        optionalInteger(url.searchParams.get("limit"), "limit", 1, MAX_LIMIT) ??
          DEFAULT_LIMIT,
        MAX_LIMIT,
      );
      const latitude = optionalNumberParam(url, "lat", -90, 90);
      const longitude = optionalNumberParam(url, "lon", -180, 180);

      logger.info("request_validated", {
        query_length: query.length,
        limit,
        has_bias: latitude !== null && longitude !== null,
      });

      const docs = await fetchPdokSuggestions({
        query,
        limit,
        latitude,
        longitude,
        logger,
      });
      const suggestions = await lookupPdokSuggestions(docs, limit, logger);

      logger.info("request_completed", {
        raw_count: docs.length,
        suggestion_count: suggestions.length,
      });
      return jsonResponse(
        { suggestions, request_id: logger.requestId },
        { headers: responseHeaders },
      );
    } catch (error) {
      if (error instanceof Error && error.message.includes("PDOK")) {
        logger.warn("pdok_request_failed", errorFields(error));
        return errorResponse(
          "Adres zoeken is tijdelijk niet beschikbaar.",
          502,
          { request_id: logger.requestId },
          responseHeaders,
        );
      }

      logger.warn("request_failed", errorFields(error));
      return errorResponse(
        error instanceof Error ? error.message : "Invalid request",
        400,
        { request_id: logger.requestId },
        responseHeaders,
      );
    }
  }),
};

function optionalNumberParam(
  url: URL,
  key: string,
  min: number,
  max: number,
): number | null {
  const value = url.searchParams.get(key);
  if (value === null || value.trim() === "") {
    return null;
  }
  return requiredNumber(value, key, min, max);
}

async function fetchPdokSuggestions({
  query,
  limit,
  latitude,
  longitude,
  logger,
}: {
  query: string;
  limit: number;
  latitude: number | null;
  longitude: number | null;
  logger: RequestLogger;
}): Promise<PdokSuggestDoc[]> {
  const url = new URL(`${PDOK_BASE_URL}/suggest`);
  url.searchParams.set("q", query);
  url.searchParams.set("rows", limit.toString());
  url.searchParams.set("fl", "id,weergavenaam,type,score");
  url.searchParams.set("fq", "type:(adres OR weg OR postcode OR woonplaats)");
  if (latitude !== null && longitude !== null) {
    url.searchParams.set("lat", latitude.toString());
    url.searchParams.set("lon", longitude.toString());
  }

  const payload = await fetchJson(url, logger, "suggest");
  const rawDocs = asArray(asRecord(payload.response).docs)
    .map((doc) => asRecord(doc));
  const allowedDocs = rawDocs.filter((doc) =>
    ALLOWED_TYPES.has(stringValue(doc.type))
  );
  const uniqueDocs = uniqueById(allowedDocs).slice(0, limit);

  logger.info("pdok_suggest_completed", {
    raw_count: rawDocs.length,
    allowed_count: allowedDocs.length,
    unique_count: uniqueDocs.length,
    limit,
    has_bias: latitude !== null && longitude !== null,
  });

  return uniqueDocs;
}

async function lookupPdokSuggestions(
  docs: PdokSuggestDoc[],
  limit: number,
  logger: RequestLogger,
): Promise<MeetingLocationSuggestion[]> {
  const suggestions: MeetingLocationSuggestion[] = [];
  const skipped: Record<string, number> = {};
  let lookupCount = 0;

  for (const doc of docs) {
    const id = stringValue(doc.id);
    if (id === "") {
      increment(skipped, "missing_suggest_id");
      continue;
    }

    lookupCount += 1;
    const lookup = await fetchPdokLookup(id, logger);
    const parsed = suggestionFromPdok(doc, lookup);
    if (parsed.suggestion !== null) {
      suggestions.push(parsed.suggestion);
    } else {
      increment(skipped, parsed.skip_reason ?? "unknown");
    }
    if (suggestions.length >= limit) {
      break;
    }
  }

  logger.info("pdok_lookup_completed", {
    input_count: docs.length,
    lookup_count: lookupCount,
    suggestion_count: suggestions.length,
    skipped_count: Object.values(skipped).reduce(
      (sum, count) => sum + count,
      0,
    ),
    skipped,
  });

  return suggestions;
}

async function fetchPdokLookup(
  id: string,
  logger: RequestLogger,
): Promise<PdokLookupDoc> {
  const url = new URL(`${PDOK_BASE_URL}/lookup`);
  url.searchParams.set("id", id);
  url.searchParams.set(
    "fl",
    [
      "id",
      "weergavenaam",
      "type",
      "woonplaatsnaam",
      "gemeentenaam",
      "postcode",
      "straatnaam",
      "huisnummer",
      "huisletter",
      "huisnummertoevoeging",
      "centroide_ll",
    ].join(","),
  );

  const payload = await fetchJson(url, logger, "lookup");
  const first = asArray(asRecord(payload.response).docs).at(0);
  return asRecord(first) as PdokLookupDoc;
}

function suggestionFromPdok(
  suggest: PdokSuggestDoc,
  lookup: PdokLookupDoc,
): {
  suggestion: MeetingLocationSuggestion | null;
  skip_reason: string | null;
} {
  const id = stringValue(lookup.id) || stringValue(suggest.id);
  const type = stringValue(lookup.type) || stringValue(suggest.type);
  if (id === "" || !ALLOWED_TYPES.has(type)) {
    return {
      suggestion: null,
      skip_reason: "missing_id_or_unsupported_type",
    };
  }

  const coordinates = parsePoint(stringValue(lookup.centroide_ll));
  if (coordinates === null) {
    return { suggestion: null, skip_reason: "missing_coordinates" };
  }

  const label = stringValue(lookup.weergavenaam) ||
    stringValue(suggest.weergavenaam);
  const city = stringValue(lookup.woonplaatsnaam) ||
    stringValue(lookup.gemeentenaam);
  if (label === "" || city === "") {
    return { suggestion: null, skip_reason: "missing_label_or_city" };
  }

  const postcode = nullableString(lookup.postcode);

  return {
    suggestion: {
      id,
      label,
      address_line: label,
      city,
      postcode,
      type,
      latitude: coordinates.latitude,
      longitude: coordinates.longitude,
      source: "pdok",
    },
    skip_reason: null,
  };
}

async function fetchJson(
  url: URL,
  logger: RequestLogger,
  operation: "suggest" | "lookup",
): Promise<Record<string, unknown>> {
  const controller = new AbortController();
  const startedAt = Date.now();
  const timeout = setTimeout(() => controller.abort(), PDOK_TIMEOUT_MS);
  try {
    const response = await fetch(url, {
      signal: controller.signal,
      headers: {
        "Accept": "application/json",
        "User-Agent": "TOCH meeting app locations-search",
      },
    });
    logger.info("pdok_http_response", {
      operation,
      status: response.status,
      ok: response.ok,
      elapsed_ms: Date.now() - startedAt,
    });
    if (!response.ok) {
      throw new Error(`PDOK request failed with status ${response.status}`);
    }
    return asRecord(await response.json());
  } catch (error) {
    logger.warn("pdok_http_error", {
      operation,
      elapsed_ms: Date.now() - startedAt,
      ...errorFields(error),
    });
    if (error instanceof Error && error.message.includes("PDOK")) {
      throw error;
    }
    throw new Error("PDOK request failed", { cause: error });
  } finally {
    clearTimeout(timeout);
  }
}

function parsePoint(value: string): { latitude: number; longitude: number } | null {
  const match = /^POINT\(([-\d.]+)\s+([-\d.]+)\)$/i.exec(value.trim());
  if (match === null) {
    return null;
  }

  const longitude = Number(match[1]);
  const latitude = Number(match[2]);
  if (
    !Number.isFinite(latitude) ||
    !Number.isFinite(longitude) ||
    latitude < -90 ||
    latitude > 90 ||
    longitude < -180 ||
    longitude > 180
  ) {
    return null;
  }

  return { latitude, longitude };
}

function uniqueById(docs: PdokSuggestDoc[]): PdokSuggestDoc[] {
  const seen = new Set<string>();
  const unique: PdokSuggestDoc[] = [];
  for (const doc of docs) {
    const id = stringValue(doc.id);
    if (id === "" || seen.has(id)) {
      continue;
    }
    seen.add(id);
    unique.push(doc);
  }
  return unique;
}

function increment(counts: Record<string, number>, key: string): void {
  counts[key] = (counts[key] ?? 0) + 1;
}

function asRecord(value: unknown): Record<string, unknown> {
  if (typeof value === "object" && value !== null && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  return {};
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function nullableString(value: unknown): string | null {
  const text = stringValue(value);
  return text === "" ? null : text;
}
