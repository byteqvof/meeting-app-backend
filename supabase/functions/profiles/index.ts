import { withSupabase } from "npm:@supabase/server";
import type {
  Profile,
  ProfileAgeBand,
  ProfileDeleteResponse,
  ProfileGender,
  ProfileInterest,
  ProfileMutationRequest,
  ProfileResponse,
  ProfileTrust,
} from "../_shared/profile-model.ts";
import { errorResponse, jsonResponse, readJsonBody } from "../_shared/http.ts";
import { createRequestLogger, errorFields } from "../_shared/logger.ts";
import {
  optionalString,
  optionalUrl,
  optionalUuid,
  requiredString,
  requiredUuid,
} from "../_shared/validation.ts";

interface ProfileRow {
  id: string;
  display_name: string;
  initials: string;
  city_name: string | null;
  member_since: string;
  avatar_url: string | null;
  attendance_score: number;
  activities_joined_count: number;
  activities_hosted_count: number;
  rating: number | string;
  is_verified: boolean;
  is_premium: boolean;
  age_band: ProfileAgeBand | null;
  gender: ProfileGender | null;
  trust?: Partial<ProfileTrust> | null;
  interests?: Array<
    | {
        category?: CategoryInterest | null;
      }
    | CategoryInterest
  >;
}

interface CategoryInterest {
  id: string;
  label?: string;
  title: string;
  icon_key: string;
  foreground_color: string;
  background_color: string;
}

interface ProfileMutationPayload {
  display_name?: string;
  initials?: string;
  city_name?: string | null;
  avatar_url?: string | null;
  age_band?: string | null;
  gender?: string | null;
  category_ids?: string[];
}

interface ProfileMutationInput {
  payload: ProfileMutationRequest;
  avatarFile: File | null;
}

interface StorageClient {
  storage: {
    from: (bucket: string) => any;
  };
}

interface UploadedAvatar {
  path: string;
  publicUrl: string;
}

const AVATAR_BUCKET = "profile-avatars";
const AVATAR_MAX_BYTES = 5 * 1024 * 1024;
const AVATAR_MIME_EXTENSIONS = new Map<string, string>([
  ["image/jpeg", "jpg"],
  ["image/png", "png"],
  ["image/webp", "webp"],
  ["image/gif", "gif"],
]);
const PROFILE_AGE_BANDS = new Set([
  "18_24",
  "25_34",
  "35_44",
  "45_54",
  "55_64",
  "65_plus",
]);
const PROFILE_GENDERS = new Set([
  "woman",
  "man",
  "non_binary",
  "prefer_not_to_say",
]);

function errorCode(error: unknown): string | null {
  if (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    typeof error.code === "string"
  ) {
    return error.code;
  }

  return null;
}

function isMultipartRequest(req: Request): boolean {
  return (
    req.headers.get("content-type")?.includes("multipart/form-data") ?? false
  );
}

function formString(formData: FormData, key: string): string | undefined {
  const value = formData.get(key);

  if (typeof value !== "string") {
    return undefined;
  }

  return value;
}

function optionalBoolean(value: unknown): boolean | undefined {
  if (value === undefined || value === null || value === "") {
    return undefined;
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

  throw new Error("remove_avatar must be a boolean");
}

function optionalEnumValue(
  value: unknown,
  field: string,
  allowed: Set<string>,
): string | null {
  if (value === undefined || value === null || value === "") {
    return null;
  }

  if (typeof value !== "string") {
    throw new Error(`${field} must be a string`);
  }

  const normalized = value.trim();
  if (!allowed.has(normalized)) {
    throw new Error(`${field} is invalid`);
  }

  return normalized;
}

function categoryIdsFromFormData(formData: FormData): string[] | undefined {
  const rawValues = [
    ...formData.getAll("category_ids"),
    ...formData.getAll("category_ids[]"),
  ].filter((value): value is string => typeof value === "string");

  if (rawValues.length === 0) {
    return undefined;
  }

  if (rawValues.length === 1) {
    const rawValue = rawValues[0].trim();

    if (rawValue === "") {
      return [];
    }

    if (rawValue.startsWith("[")) {
      const parsed = JSON.parse(rawValue);

      if (!Array.isArray(parsed)) {
        throw new Error("category_ids must be an array");
      }

      return parsed;
    }
  }

  return rawValues;
}

async function readProfileMutationInput(
  req: Request,
): Promise<ProfileMutationInput> {
  if (!isMultipartRequest(req)) {
    return {
      payload: await readJsonBody<ProfileMutationRequest>(req),
      avatarFile: null,
    };
  }

  const formData = await req.formData();
  const avatarEntry = formData.get("avatar") ?? formData.get("avatar_file");
  const avatarFile = avatarEntry instanceof File ? avatarEntry : null;

  return {
    payload: {
      display_name: formString(formData, "display_name"),
      initials: formString(formData, "initials"),
      city_name: formString(formData, "city_name"),
      avatar_url: formString(formData, "avatar_url"),
      remove_avatar: optionalBoolean(formString(formData, "remove_avatar")),
      age_band: formString(formData, "age_band") as ProfileMutationRequest["age_band"],
      gender: formString(formData, "gender") as ProfileMutationRequest["gender"],
      category_ids: categoryIdsFromFormData(formData),
    },
    avatarFile,
  };
}

function validateAvatarFile(file: File): string {
  if (file.size === 0) {
    throw new Error("avatar must not be empty");
  }

  if (file.size > AVATAR_MAX_BYTES) {
    throw new Error("avatar must be at most 5 MB");
  }

  const contentType = file.type.toLowerCase();
  const extension = AVATAR_MIME_EXTENSIONS.get(contentType);

  if (!extension) {
    throw new Error("avatar must be a jpeg, png, webp, or gif image");
  }

  return extension;
}

async function uploadAvatar(
  supabaseAdmin: StorageClient,
  profileId: string,
  file: File,
): Promise<{ avatar: UploadedAvatar | null; error: unknown | null }> {
  const extension = validateAvatarFile(file);
  const path = `${profileId}/avatar-${Date.now()}-${crypto.randomUUID()}.${extension}`;
  const { error } = await supabaseAdmin.storage
    .from(AVATAR_BUCKET)
    .upload(path, file, {
      cacheControl: "3600",
      contentType: file.type,
      upsert: false,
    });

  if (error) {
    return { avatar: null, error };
  }

  return {
    avatar: {
      path,
      publicUrl: publicAvatarUrl(path),
    },
    error: null,
  };
}

function publicAvatarUrl(path: string): string {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");

  if (!supabaseUrl) {
    throw new Error("SUPABASE_URL is not configured");
  }

  const encodedPath = path.split("/").map(encodeURIComponent).join("/");

  return `${supabaseUrl.replace(
    /\/$/,
    "",
  )}/storage/v1/object/public/${AVATAR_BUCKET}/${encodedPath}`;
}

function avatarPathFromPublicUrl(avatarUrl: string | null): string | null {
  if (!avatarUrl) {
    return null;
  }

  try {
    const url = new URL(avatarUrl);
    const marker = `/storage/v1/object/public/${AVATAR_BUCKET}/`;
    const markerIndex = url.pathname.indexOf(marker);

    if (markerIndex === -1) {
      return null;
    }

    return decodeURIComponent(url.pathname.slice(markerIndex + marker.length));
  } catch {
    return null;
  }
}

async function removeAvatarByPath(
  supabaseAdmin: StorageClient,
  path: string | null,
): Promise<unknown | null> {
  if (!path) {
    return null;
  }

  const { error } = await supabaseAdmin.storage
    .from(AVATAR_BUCKET)
    .remove([path]);

  return error ?? null;
}

const PROFILE_SELECT = `
  id,
  display_name,
  initials,
  city_name,
  member_since,
  avatar_url,
  attendance_score,
  activities_joined_count,
  activities_hosted_count,
  rating,
  is_verified,
  is_premium,
  age_band,
  gender,
  interests:profile_category_links (
    category:activity_categories (
      id,
      title,
      icon_key,
      foreground_color,
      background_color
    )
  )
`;

function mapProfile(row: ProfileRow): Profile {
  const trust = mapTrust(row.trust);

  return {
    id: row.id,
    display_name: row.display_name,
    initials: row.initials,
    city_name: row.city_name,
    member_since: row.member_since,
    avatar_url: row.avatar_url,
    attendance_score: row.attendance_score,
    activities_joined_count: row.activities_joined_count,
    activities_hosted_count: row.activities_hosted_count,
    rating: Number(row.rating),
    is_verified: trust.identity_status === "verified",
    is_premium: row.is_premium,
    age_band: row.age_band,
    gender: row.gender,
    trust,
    interests: mapInterests(row.interests),
  };
}

function mapTrust(
  input: Partial<ProfileTrust> | null | undefined,
): ProfileTrust {
  return {
    phone_verified: input?.phone_verified === true,
    phone_verified_at: input?.phone_verified_at ?? null,
    identity_status: input?.identity_status ?? "unverified",
    identity_method: input?.identity_method ?? null,
    identity_completed_at: input?.identity_completed_at ?? null,
    age_verified: input?.age_verified === true,
    reputation_level: input?.reputation_level ?? "new_member",
    reputation_score: Number(input?.reputation_score ?? 0),
  };
}

function mapInterests(interests: ProfileRow["interests"]): ProfileInterest[] {
  return (interests ?? [])
    .map((item) => {
      if ("category" in item) {
        return item.category ?? null;
      }

      return item;
    })
    .filter((category): category is CategoryInterest => category !== null)
    .map((category) => ({
      id: category.id,
      label: category.title ?? category.label ?? "",
      icon_key: category.icon_key,
      foreground_color: category.foreground_color,
      background_color: category.background_color,
    }));
}

function normalizeCategoryIds(
  input: ProfileMutationRequest,
): string[] | undefined {
  const rawCategories = input.category_ids;

  if (rawCategories === undefined) {
    return undefined;
  }

  if (!Array.isArray(rawCategories)) {
    throw new Error("category_ids must be an array");
  }

  const ids = rawCategories.map((categoryId) => {
    if (typeof categoryId !== "string") {
      throw new Error("category_ids must contain UUID strings");
    }

    return categoryId;
  });

  return [...new Set(ids.map((id) => requiredUuid(id, "category_id")))];
}

function normalizeCreatePayload(
  input: ProfileMutationRequest,
): ProfileMutationPayload {
  return {
    display_name: requiredString(input.display_name, "display_name", 2, 120),
    initials: requiredString(input.initials, "initials", 1, 8).toUpperCase(),
    city_name: optionalString(input.city_name, "city_name", 120),
    avatar_url: input.remove_avatar
      ? null
      : optionalUrl(input.avatar_url, "avatar_url"),
    age_band: optionalEnumValue(input.age_band, "age_band", PROFILE_AGE_BANDS),
    gender: optionalEnumValue(input.gender, "gender", PROFILE_GENDERS),
    category_ids: normalizeCategoryIds(input),
  };
}

function normalizeUpdatePayload(
  input: ProfileMutationRequest,
): ProfileMutationPayload {
  const payload: ProfileMutationPayload = {};

  if (input.display_name !== undefined) {
    payload.display_name = requiredString(
      input.display_name,
      "display_name",
      2,
      120,
    );
  }

  if (input.initials !== undefined) {
    payload.initials = requiredString(
      input.initials,
      "initials",
      1,
      8,
    ).toUpperCase();
  }

  if (input.city_name !== undefined) {
    payload.city_name = optionalString(input.city_name, "city_name", 120);
  }

  if (input.avatar_url !== undefined) {
    payload.avatar_url = optionalUrl(input.avatar_url, "avatar_url");
  }

  if (input.remove_avatar === true) {
    payload.avatar_url = null;
  }

  if (input.age_band !== undefined) {
    payload.age_band = optionalEnumValue(
      input.age_band,
      "age_band",
      PROFILE_AGE_BANDS,
    );
  }

  if (input.gender !== undefined) {
    payload.gender = optionalEnumValue(input.gender, "gender", PROFILE_GENDERS);
  }

  const categoryIds = normalizeCategoryIds(input);
  if (categoryIds !== undefined) {
    payload.category_ids = categoryIds;
  }

  return payload;
}

async function replaceCategories(
  supabase: { from: (table: string) => any },
  profileId: string,
  categoryIds: string[] | undefined,
): Promise<{ error: unknown | null }> {
  if (categoryIds === undefined) {
    return { error: null };
  }

  const { error: deleteError } = await supabase
    .from("profile_category_links")
    .delete()
    .eq("profile_id", profileId);

  if (deleteError) {
    return { error: deleteError };
  }

  if (categoryIds.length === 0) {
    return { error: null };
  }

  const { error: insertError } = await supabase
    .from("profile_category_links")
    .insert(
      categoryIds.map((categoryId) => ({
        profile_id: profileId,
        category_id: categoryId,
      })),
    );

  return { error: insertError ?? null };
}

async function fetchProfile(
  supabase: { from: (table: string) => any },
  profileId: string,
): Promise<{ profile: Profile | null; error: unknown | null }> {
  const rpcClient = supabase as unknown as {
    rpc: (fn: string, args: Record<string, unknown>) => any;
  };

  const { data, error } = await rpcClient.rpc("profile_json", {
    p_profile_id: profileId,
  });

  if (error) {
    return { profile: null, error };
  }

  return {
    profile: data ? mapProfile(data as ProfileRow) : null,
    error: null,
  };
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const logger = createRequestLogger("profiles", req);
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
        const profileId =
          optionalUuid(url.searchParams.get("id"), "id") ?? userId;

        const { profile, error } = await fetchProfile(ctx.supabase, profileId);

        if (error) {
          logger.error("profile_fetch_failed", {
            profile_id: profileId,
            error,
          });
          return errorResponse(
            "Could not fetch profile",
            500,
            error,
            responseHeaders,
          );
        }

        const response: ProfileResponse = {
          profile,
          onboarding_required: profileId === userId && profile === null,
        };

        if (response.onboarding_required) {
          logger.info("profile_missing_onboarding_required", {
            profile_id: profileId,
          });

          return jsonResponse(response, { headers: responseHeaders });
        }

        logger.info("profile_fetch_succeeded", {
          profile_id: profileId,
          found: profile !== null,
          onboarding_required: response.onboarding_required,
        });

        return jsonResponse(response, { headers: responseHeaders });
      }

      if (req.method === "POST") {
        const input = await readProfileMutationInput(req);
        const payload = normalizeCreatePayload(input.payload);
        let uploadedAvatarPath: string | null = null;

        if (input.avatarFile) {
          const { avatar, error } = await uploadAvatar(
            ctx.supabaseAdmin,
            userId,
            input.avatarFile,
          );

          if (error || avatar === null) {
            logger.error("avatar_upload_failed", { error });
            return errorResponse(
              "Could not upload profile avatar",
              500,
              error,
              responseHeaders,
            );
          }

          uploadedAvatarPath = avatar.path;
          payload.avatar_url = avatar.publicUrl;

          logger.info("avatar_uploaded", {
            profile_id: userId,
            avatar_path: avatar.path,
            avatar_size: input.avatarFile.size,
            avatar_type: input.avatarFile.type,
          });
        }

        const { category_ids: categoryIds, ...profilePayload } = payload;

        const { error: insertError } = await ctx.supabase
          .from("profiles")
          .insert({
            id: userId,
            ...profilePayload,
          });

        if (insertError) {
          const avatarCleanupError = await removeAvatarByPath(
            ctx.supabaseAdmin,
            uploadedAvatarPath,
          );

          if (avatarCleanupError) {
            logger.warn("avatar_cleanup_after_insert_failed", {
              error: avatarCleanupError,
            });
          }

          logger.error("profile_insert_failed", { error: insertError });
          const status = errorCode(insertError) === "23505" ? 409 : 500;

          return errorResponse(
            status === 409
              ? "Profile already exists"
              : "Could not create profile",
            status,
            insertError,
            responseHeaders,
          );
        }

        const { error: categoriesError } = await replaceCategories(
          ctx.supabase,
          userId,
          categoryIds,
        );

        if (categoriesError) {
          logger.error("profile_categories_replace_failed", {
            error: categoriesError,
          });
          return errorResponse(
            "Could not save profile categories",
            500,
            categoriesError,
            responseHeaders,
          );
        }

        const { profile, error } = await fetchProfile(ctx.supabase, userId);

        if (error || profile === null) {
          logger.error("profile_fetch_after_insert_failed", { error });
          return errorResponse(
            "Could not fetch profile",
            500,
            error,
            responseHeaders,
          );
        }

        logger.info("profile_created", {
          profile_id: profile.id,
          category_count: profile.interests.length,
        });

        return jsonResponse(
          { profile, onboarding_required: false },
          {
            status: 201,
            headers: responseHeaders,
          },
        );
      }

      if (req.method === "PATCH" || req.method === "PUT") {
        const { profile: existingProfile, error: existingProfileError } =
          await fetchProfile(ctx.supabase, userId);

        if (existingProfileError) {
          logger.error("profile_fetch_before_update_failed", {
            error: existingProfileError,
          });
          return errorResponse(
            "Could not fetch profile",
            500,
            existingProfileError,
            responseHeaders,
          );
        }

        if (existingProfile === null) {
          logger.warn("profile_update_missing_profile", { profile_id: userId });
          return errorResponse(
            "Profile does not exist",
            404,
            undefined,
            responseHeaders,
          );
        }

        const input = await readProfileMutationInput(req);
        const payload = normalizeUpdatePayload(input.payload);
        let uploadedAvatarPath: string | null = null;
        const oldAvatarPath = avatarPathFromPublicUrl(
          existingProfile.avatar_url,
        );

        if (input.avatarFile) {
          const { avatar, error } = await uploadAvatar(
            ctx.supabaseAdmin,
            userId,
            input.avatarFile,
          );

          if (error || avatar === null) {
            logger.error("avatar_upload_failed", { error });
            return errorResponse(
              "Could not upload profile avatar",
              500,
              error,
              responseHeaders,
            );
          }

          uploadedAvatarPath = avatar.path;
          payload.avatar_url = avatar.publicUrl;

          logger.info("avatar_uploaded", {
            profile_id: userId,
            avatar_path: avatar.path,
            avatar_size: input.avatarFile.size,
            avatar_type: input.avatarFile.type,
          });
        }

        const { category_ids: categoryIds, ...profilePayload } = payload;

        if (Object.keys(profilePayload).length > 0) {
          const { error: updateError } = await ctx.supabase
            .from("profiles")
            .update(profilePayload)
            .eq("id", userId);

          if (updateError) {
            const avatarCleanupError = await removeAvatarByPath(
              ctx.supabaseAdmin,
              uploadedAvatarPath,
            );

            if (avatarCleanupError) {
              logger.warn("avatar_cleanup_after_update_failed", {
                error: avatarCleanupError,
              });
            }

            logger.error("profile_update_failed", { error: updateError });
            return errorResponse(
              "Could not update profile",
              500,
              updateError,
              responseHeaders,
            );
          }
        }

        if (payload.avatar_url !== undefined) {
          const newAvatarPath = avatarPathFromPublicUrl(payload.avatar_url);
          const shouldRemoveOldAvatar =
            oldAvatarPath !== null && oldAvatarPath !== newAvatarPath;

          if (shouldRemoveOldAvatar) {
            const avatarCleanupError = await removeAvatarByPath(
              ctx.supabaseAdmin,
              oldAvatarPath,
            );

            if (avatarCleanupError) {
              logger.warn("old_avatar_cleanup_failed", {
                error: avatarCleanupError,
              });
            } else {
              logger.info("old_avatar_cleaned_up", {
                profile_id: userId,
                avatar_path: oldAvatarPath,
              });
            }
          }
        }

        const { error: categoriesError } = await replaceCategories(
          ctx.supabase,
          userId,
          categoryIds,
        );

        if (categoriesError) {
          logger.error("profile_categories_replace_failed", {
            error: categoriesError,
          });
          return errorResponse(
            "Could not save profile categories",
            500,
            categoriesError,
            responseHeaders,
          );
        }

        const { profile, error } = await fetchProfile(ctx.supabase, userId);

        if (error || profile === null) {
          logger.error("profile_fetch_after_update_failed", { error });
          return errorResponse(
            "Could not fetch profile",
            500,
            error,
            responseHeaders,
          );
        }

        logger.info("profile_updated", {
          profile_id: profile.id,
          category_count: profile.interests.length,
        });

        return jsonResponse(
          { profile, onboarding_required: false },
          { headers: responseHeaders },
        );
      }

      if (req.method === "DELETE") {
        const { profile: existingProfile, error: existingProfileError } =
          await fetchProfile(ctx.supabase, userId);

        if (existingProfileError) {
          logger.error("profile_fetch_before_delete_failed", {
            error: existingProfileError,
          });
          return errorResponse(
            "Could not fetch profile",
            500,
            existingProfileError,
            responseHeaders,
          );
        }

        const { error } = await ctx.supabaseAdmin.auth.admin.deleteUser(userId);

        if (error) {
          logger.error("auth_user_delete_failed", { error });
          return errorResponse(
            "Could not delete account",
            500,
            error,
            responseHeaders,
          );
        }

        const avatarCleanupError = await removeAvatarByPath(
          ctx.supabaseAdmin,
          avatarPathFromPublicUrl(existingProfile?.avatar_url ?? null),
        );

        if (avatarCleanupError) {
          logger.warn("avatar_cleanup_after_delete_failed", {
            error: avatarCleanupError,
          });
        }

        const response: ProfileDeleteResponse = { deleted: true };

        logger.info("profile_deleted", { profile_id: userId });

        return jsonResponse(response, { headers: responseHeaders });
      }

      logger.warn("method_not_allowed", { method: req.method });
      return errorResponse(
        "Method not allowed",
        405,
        undefined,
        responseHeaders,
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
