import { withSupabase } from 'npm:@supabase/server'
import type {
  NearbyActivitiesRequest,
  NearbyActivity,
  NearbyActivitiesResponse,
} from '../_shared/activity-model.ts'
import { errorResponse, jsonResponse, readJsonBody } from '../_shared/http.ts'
import {
  createRequestLogger,
  errorFields,
  roundCoordinate,
} from '../_shared/logger.ts'
import {
  optionalInteger,
  optionalUuid,
  requiredNumber,
} from '../_shared/validation.ts'

function requestFromUrl(req: Request): NearbyActivitiesRequest {
  const url = new URL(req.url)

  return {
    latitude: requiredNumber(
      url.searchParams.get('latitude') ?? url.searchParams.get('lat'),
      'latitude',
      -90,
      90,
    ),
    longitude: requiredNumber(
      url.searchParams.get('longitude') ?? url.searchParams.get('lng'),
      'longitude',
      -180,
      180,
    ),
    radius_km: requiredNumber(
      url.searchParams.get('radius_km') ??
        url.searchParams.get('radiusKm') ??
        '10',
      'radius_km',
      0.1,
      100,
    ),
    category_id: optionalUuid(
      url.searchParams.get('category_id') ?? url.searchParams.get('categoryId'),
      'category_id',
    ),
    limit:
      optionalInteger(url.searchParams.get('limit') ?? '50', 'limit', 1, 100) ??
        50,
  }
}

function normalizeRequest(
  input: NearbyActivitiesRequest,
): NearbyActivitiesRequest {
  return {
    latitude: requiredNumber(input.latitude, 'latitude', -90, 90),
    longitude: requiredNumber(input.longitude, 'longitude', -180, 180),
    radius_km: requiredNumber(input.radius_km ?? 10, 'radius_km', 0.1, 100),
    category_id: optionalUuid(input.category_id, 'category_id'),
    limit: optionalInteger(input.limit ?? 50, 'limit', 1, 100) ?? 50,
  }
}

export default {
  fetch: withSupabase({ auth: 'user' }, async (req, ctx) => {
    const logger = createRequestLogger('activities-nearby', req)
    const responseHeaders = { 'x-request-id': logger.requestId }

    logger.info('request_received', {
      method: req.method,
      path: new URL(req.url).pathname,
      auth_mode: ctx.authMode,
      user_id: ctx.userClaims?.id,
    })

    if (req.method !== 'GET' && req.method !== 'POST') {
      logger.warn('method_not_allowed', { method: req.method })
      return errorResponse('Method not allowed', 405, undefined, responseHeaders)
    }

    try {
      const request =
        req.method === 'GET'
          ? requestFromUrl(req)
          : normalizeRequest(await readJsonBody<NearbyActivitiesRequest>(req))

      logger.info('request_validated', {
        latitude: roundCoordinate(request.latitude),
        longitude: roundCoordinate(request.longitude),
        radius_km: request.radius_km,
        category_id: request.category_id,
        limit: request.limit,
      })

      const { data, error } = await ctx.supabase.rpc(
        'search_activities_nearby',
        {
          p_latitude: request.latitude,
          p_longitude: request.longitude,
          p_radius_km: request.radius_km,
          p_category_id: request.category_id,
          p_limit: request.limit,
        },
      )

      if (error) {
        logger.error('rpc_failed', { error })
        return errorResponse(
          'Could not fetch nearby activities',
          500,
          error,
          responseHeaders,
        )
      }

      logger.info('rpc_succeeded', {
        activity_count: data?.length ?? 0,
      })

      const response: NearbyActivitiesResponse = {
        activities: (data ?? []) as NearbyActivity[],
        filters: {
          latitude: request.latitude,
          longitude: request.longitude,
          radius_km: request.radius_km ?? 10,
          category_id: request.category_id ?? null,
          limit: request.limit ?? 50,
        },
      }

      logger.info('response_sent', {
        status: 200,
        activity_count: response.activities.length,
      })

      return jsonResponse(response, { headers: responseHeaders })
    } catch (error) {
      logger.warn('request_failed', errorFields(error))
      return errorResponse(
        error instanceof Error ? error.message : 'Invalid request',
        400,
        undefined,
        responseHeaders,
      )
    }
  }),
}
