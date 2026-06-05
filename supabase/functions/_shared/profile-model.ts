export interface ProfileInterest {
  id: string
  label: string
  icon_key: string
  foreground_color: string
  background_color: string
}

export interface Profile {
  id: string
  display_name: string
  initials: string
  city_name: string | null
  member_since: string
  avatar_url: string | null
  attendance_score: number
  activities_joined_count: number
  activities_hosted_count: number
  rating: number
  is_verified: boolean
  is_premium: boolean
  interests: ProfileInterest[]
}

export interface ProfileResponse {
  profile: Profile | null
  onboarding_required: boolean
}

export interface ProfileMutationRequest {
  display_name?: string
  initials?: string
  city_name?: string | null
  avatar_url?: string | null
  remove_avatar?: boolean
  category_ids?: string[]
}

export interface ProfileDeleteResponse {
  deleted: boolean
}
