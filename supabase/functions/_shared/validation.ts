const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

export function requiredString(
  value: unknown,
  field: string,
  minLength: number,
  maxLength: number,
): string {
  if (typeof value !== 'string') {
    throw new Error(`${field} is required`)
  }

  const trimmed = value.trim()
  if (trimmed.length < minLength || trimmed.length > maxLength) {
    throw new Error(
      `${field} must be between ${minLength} and ${maxLength} characters`,
    )
  }

  return trimmed
}

export function optionalString(
  value: unknown,
  field: string,
  maxLength: number,
): string | null {
  if (value === undefined || value === null || value === '') {
    return null
  }

  if (typeof value !== 'string') {
    throw new Error(`${field} must be a string`)
  }

  const trimmed = value.trim()
  if (trimmed.length > maxLength) {
    throw new Error(`${field} must be at most ${maxLength} characters`)
  }

  return trimmed
}

export function requiredUuid(value: unknown, field: string): string {
  if (typeof value !== 'string' || !UUID_PATTERN.test(value)) {
    throw new Error(`${field} must be a valid UUID`)
  }

  return value
}

export function optionalUuid(value: unknown, field: string): string | null {
  if (value === undefined || value === null || value === '') {
    return null
  }

  return requiredUuid(value, field)
}

export function requiredNumber(
  value: unknown,
  field: string,
  min: number,
  max: number,
): number {
  const numberValue =
    typeof value === 'string' && value.trim() !== ''
      ? Number(value)
      : value

  if (
    typeof numberValue !== 'number' ||
    Number.isNaN(numberValue) ||
    !Number.isFinite(numberValue) ||
    numberValue < min ||
    numberValue > max
  ) {
    throw new Error(`${field} must be a number between ${min} and ${max}`)
  }

  return numberValue
}

export function optionalInteger(
  value: unknown,
  field: string,
  min: number,
  max: number,
): number | null {
  if (value === undefined || value === null || value === '') {
    return null
  }

  const numberValue = Number(value)
  if (
    !Number.isInteger(numberValue) ||
    numberValue < min ||
    numberValue > max
  ) {
    throw new Error(`${field} must be an integer between ${min} and ${max}`)
  }

  return numberValue
}

export function optionalMoneyCents(value: unknown, field: string): number {
  if (value === undefined || value === null || value === '') {
    return 0
  }

  const numberValue = Number(value)
  if (!Number.isInteger(numberValue) || numberValue < 0) {
    throw new Error(`${field} must be a positive integer`)
  }

  return numberValue
}

export function optionalCurrency(value: unknown): string {
  if (value === undefined || value === null || value === '') {
    return 'EUR'
  }

  if (typeof value !== 'string' || !/^[A-Za-z]{3}$/.test(value)) {
    throw new Error('currency must be an ISO 4217 code')
  }

  return value.toUpperCase()
}

export function optionalCountryCode(value: unknown): string {
  if (value === undefined || value === null || value === '') {
    return 'NL'
  }

  if (typeof value !== 'string' || !/^[A-Za-z]{2}$/.test(value)) {
    throw new Error('country_code must be an ISO 3166-1 alpha-2 code')
  }

  return value.toUpperCase()
}

export function optionalUrl(value: unknown, field: string): string | null {
  if (value === undefined || value === null || value === '') {
    return null
  }

  if (typeof value !== 'string') {
    throw new Error(`${field} must be a URL`)
  }

  try {
    const url = new URL(value)
    if (url.protocol !== 'http:' && url.protocol !== 'https:') {
      throw new Error()
    }

    return url.toString()
  } catch {
    throw new Error(`${field} must be a valid http(s) URL`)
  }
}

export function requiredIsoDate(value: unknown, field: string): string {
  if (typeof value !== 'string') {
    throw new Error(`${field} is required`)
  }

  const date = new Date(value)
  if (Number.isNaN(date.getTime())) {
    throw new Error(`${field} must be a valid ISO date`)
  }

  return date.toISOString()
}

export function optionalIsoDate(value: unknown, field: string): string | null {
  if (value === undefined || value === null || value === '') {
    return null
  }

  return requiredIsoDate(value, field)
}

export function optionalMetadata(value: unknown): Record<string, unknown> {
  if (value === undefined || value === null) {
    return {}
  }

  if (
    typeof value !== 'object' ||
    Array.isArray(value)
  ) {
    throw new Error('metadata must be an object')
  }

  return value as Record<string, unknown>
}
