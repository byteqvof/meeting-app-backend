export function jsonResponse(
  body: unknown,
  init: ResponseInit = {},
): Response {
  const headers = new Headers(init.headers)
  headers.set('Content-Type', 'application/json')

  return new Response(JSON.stringify(body), {
    ...init,
    headers,
  })
}

export function errorResponse(
  message: string,
  status = 400,
  details?: unknown,
  headers?: HeadersInit,
): Response {
  return jsonResponse({ error: { message, details } }, { status, headers })
}

export async function readJsonBody<T>(req: Request): Promise<T> {
  try {
    return await req.json()
  } catch {
    throw new Error('Invalid JSON body')
  }
}
