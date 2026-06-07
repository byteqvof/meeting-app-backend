import type { Profile } from "./profile-model.ts";

export type ActivityStatus =
  | "draft"
  | "published"
  | "cancelled"
  | "archived"
  | "completed";

export interface ActivityCategory {
  id: string;
  slug: string;
  title: string;
  description: string | null;
  background_color: string;
  foreground_color: string;
  icon_key: string;
}

export interface Activity {
  id: string;
  category_id: string;
  organizer_id: string;
  title: string;
  description: string;
  latitude: number;
  longitude: number;
  address_line: string | null;
  city: string | null;
  country_code: string;
  starts_at: string;
  ends_at: string | null;
  max_participants: number | null;
  price_cents: number;
  currency: string;
  image_url: string | null;
  status: ActivityStatus;
  group_type: "open" | "approval" | "closed";
  min_reputation_level:
    | "new_member"
    | "active_member"
    | "known_member"
    | "top_participant";
  requires_identity_verified: boolean;
  is_private_location: boolean;
  target_age_bands: string[];
  target_genders: string[];
  metadata: Record<string, unknown>;
  created_at: string;
  updated_at: string;
}

export interface ActivityWithProfiles extends Activity {
  category: ActivityCategory;
  host: Profile | null;
  participants: Profile[];
  participants_count: number;
  is_joined: boolean;
  available_spots: number;
}

export interface NearbyActivity extends ActivityWithProfiles {
  distance_km: number;
}

export interface UserActivity extends ActivityWithProfiles {
  distance_km: number | null;
  chat_summary?: ActivityChatSummary | null;
}

export interface NearbyActivitiesRequest {
  latitude: number;
  longitude: number;
  radius_km?: number;
  category_id?: string | null;
  category_ids?: string[];
  date_from?: string | null;
  date_to?: string | null;
  target_age_bands?: string[];
  target_genders?: string[];
  requires_identity_verified?: boolean;
  available_only?: boolean;
  min_participants?: number | null;
  max_participants?: number | null;
  sort?: "distance" | "start_time" | "participants";
  limit?: number;
}

export interface CreateActivityRequest {
  category_id: string;
  title: string;
  description: string;
  latitude: number;
  longitude: number;
  address_line?: string | null;
  city?: string | null;
  country_code?: string;
  starts_at: string;
  ends_at?: string | null;
  max_participants?: number | null;
  price_cents?: number;
  currency?: string;
  image_url?: string | null;
  group_type?: "open" | "approval" | "closed";
  min_reputation_level?:
    | "new_member"
    | "active_member"
    | "known_member"
    | "top_participant";
  requires_identity_verified?: boolean;
  is_private_location?: boolean;
  target_age_bands?: string[];
  target_genders?: string[];
  metadata?: Record<string, unknown>;
}

export interface ActivityParticipationRequest {
  activity_id: string;
  action?: "join" | "leave";
  join?: boolean;
}

export interface ActivityParticipationUpdate {
  activity_id: string;
  is_joined: boolean;
  participation_status?: "joined" | "pending" | "cancelled";
  participants: Profile[];
  participants_count: number;
  available_spots: number;
}

export interface ActivityChatMessage {
  id: string;
  activity_id: string;
  sender_id: string;
  body: string;
  created_at: string;
  sender: Profile | null;
  client_message_id: string | null;
}

export interface ActivityChatSummary {
  last_message_id: string | null;
  last_message: string | null;
  last_message_at: string | null;
  last_sender_id: string | null;
  last_sender: Profile | null;
  unread_count: number;
}

export interface SendActivityChatMessageRequest {
  activity_id: string;
  body: string;
  client_message_id?: string | null;
}

export interface MarkActivityChatReadRequest {
  activity_id: string;
  message_id?: string | null;
}

export interface ActivityCompletionRequest {
  activity_id: string;
}

export interface ActivityCompletionUpdate {
  activity_id: string;
  status: ActivityStatus;
}

export interface ActivityFeedback {
  id: string;
  activity_id: string;
  reviewer_id: string;
  target_profile_id: string;
  rating: number;
  comment: string;
  created_at: string;
  target: Profile | null;
}

export interface ActivityFeedbackRequest {
  activity_id: string;
  target_profile_id: string;
  rating: number;
  comment?: string | null;
}

export interface NearbyActivitiesResponse {
  activities: NearbyActivity[];
  filters: {
    latitude: number;
    longitude: number;
    radius_km: number;
    category_id: string | null;
    category_ids: string[];
    date_from: string | null;
    date_to: string | null;
    target_age_bands: string[];
    target_genders: string[];
    requires_identity_verified: boolean;
    available_only: boolean;
    min_participants: number | null;
    max_participants: number | null;
    sort: "distance" | "start_time" | "participants";
    limit: number;
  };
}

export interface UserActivitiesResponse {
  activities: UserActivity[];
  filters: {
    user_id: string;
    is_own_profile: boolean;
    status: ActivityStatus | null;
    limit: number;
  };
}

export interface ActivityAgendaResponse {
  hosted: UserActivity[];
  joined: UserActivity[];
  completed: UserActivity[];
  filters: {
    user_id: string;
    limit: number;
  };
}

export interface ActivityChatMessagesResponse {
  messages: ActivityChatMessage[];
  filters: {
    activity_id: string;
    limit: number;
    before: string | null;
    after_created_at: string | null;
    after_id: string | null;
  };
}

export interface SendActivityChatMessageResponse {
  message: ActivityChatMessage;
}

export interface MarkActivityChatReadResponse {
  summary: ActivityChatSummary;
}

export interface ActivityCompletionResponse {
  completion: ActivityCompletionUpdate;
}

export interface ActivityFeedbackResponse {
  feedback: ActivityFeedback;
}

export interface ActivityDetailResponse {
  activity: UserActivity | null;
}

export interface CreateActivityResponse {
  activity: Activity & {
    category: ActivityCategory;
  };
}

export interface ActivityParticipationResponse {
  participation: ActivityParticipationUpdate;
}
