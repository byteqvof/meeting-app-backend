import type { Profile } from './profile-model.ts'

export type ActivityStatus = 'draft' | 'published' | 'cancelled' | 'archived'

export interface ActivityCategory {
  id: string
  slug: string
  title: string
  description: string | null
  background_color: string
  foreground_color: string
  icon_key: string
}

export interface Activity {
  id: string
  category_id: string
  organizer_id: string
  title: string
  description: string
  latitude: number
  longitude: number
  address_line: string | null
  city: string | null
  country_code: string
  starts_at: string
  ends_at: string | null
  max_participants: number | null
  price_cents: number
  currency: string
  image_url: string | null
  status: ActivityStatus
  metadata: Record<string, unknown>
  created_at: string
  updated_at: string
}

export interface ActivityWithProfiles extends Activity {
  category: ActivityCategory
  host: Profile | null
  participants: Profile[]
  participants_count: number
}

export interface NearbyActivity extends ActivityWithProfiles {
  distance_km: number
}

export interface UserActivity extends ActivityWithProfiles {
  distance_km: number | null
}

export interface NearbyActivitiesRequest {
  latitude: number
  longitude: number
  radius_km?: number
  category_id?: string | null
  limit?: number
}

export interface CreateActivityRequest {
  category_id: string
  title: string
  description: string
  latitude: number
  longitude: number
  address_line?: string | null
  city?: string | null
  country_code?: string
  starts_at: string
  ends_at?: string | null
  max_participants?: number | null
  price_cents?: number
  currency?: string
  image_url?: string | null
  metadata?: Record<string, unknown>
}

export interface NearbyActivitiesResponse {
  activities: NearbyActivity[]
  filters: {
    latitude: number
    longitude: number
    radius_km: number
    category_id: string | null
    limit: number
  }
}

export interface UserActivitiesResponse {
  activities: UserActivity[]
  filters: {
    user_id: string
    is_own_profile: boolean
    status: ActivityStatus | null
    limit: number
  }
}

export interface CreateActivityResponse {
  activity: Activity & {
    category: ActivityCategory
  }
}
