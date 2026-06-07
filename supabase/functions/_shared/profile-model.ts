export interface ProfileInterest {
  id: string;
  label: string;
  icon_key: string;
  foreground_color: string;
  background_color: string;
}

export type IdentityVerificationStatus =
  | "unverified"
  | "pending"
  | "verified"
  | "rejected"
  | "expired";

export type IdentityVerificationMethod =
  | "idin"
  | "itsme"
  | "eudi_wallet"
  | "veriff"
  | "sumsub"
  | "onfido"
  | "manual";

export type ReputationLevel =
  | "new_member"
  | "active_member"
  | "known_member"
  | "top_participant";

export type ProfileAgeBand =
  | "18_24"
  | "25_34"
  | "35_44"
  | "45_54"
  | "55_64"
  | "65_plus";

export type ProfileGender =
  | "woman"
  | "man"
  | "non_binary"
  | "prefer_not_to_say";

export interface ProfileTrust {
  phone_verified: boolean;
  phone_verified_at: string | null;
  identity_status: IdentityVerificationStatus;
  identity_method: IdentityVerificationMethod | null;
  identity_completed_at: string | null;
  age_verified: boolean;
  reputation_level: ReputationLevel;
  reputation_score: number;
}

export interface Profile {
  id: string;
  display_name: string;
  initials: string;
  city_name: string | null;
  member_since: string;
  avatar_url: string | null;
  attendance_score: number;
  activities_joined_count: number;
  activities_hosted_count: number;
  rating: number;
  is_verified: boolean;
  is_premium: boolean;
  age_band: ProfileAgeBand | null;
  gender: ProfileGender | null;
  trust: ProfileTrust;
  interests: ProfileInterest[];
}

export interface ProfileResponse {
  profile: Profile | null;
  onboarding_required: boolean;
}

export interface AccountTrustResponse {
  trust: ProfileTrust;
}

export interface ProfileMutationRequest {
  display_name?: string;
  initials?: string;
  city_name?: string | null;
  avatar_url?: string | null;
  remove_avatar?: boolean;
  age_band?: ProfileAgeBand | null;
  gender?: ProfileGender | null;
  category_ids?: string[];
}

export interface ProfileDeleteResponse {
  deleted: boolean;
}
