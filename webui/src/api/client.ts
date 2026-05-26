const API_BASE = ''  // same-origin
const TOKEN_KEY = 'dune.token'

function getToken(): string {
  const url = new URL(window.location.href)
  const fromUrl = url.searchParams.get('t')
  if (fromUrl) {
    sessionStorage.setItem(TOKEN_KEY, fromUrl)
    url.searchParams.delete('t')
    window.history.replaceState({}, '', url.toString())
    return fromUrl
  }
  return sessionStorage.getItem(TOKEN_KEY) ?? ''
}

export class ApiError extends Error {
  status: number
  body?: unknown
  constructor(status: number, message: string, body?: unknown) {
    super(message)
    this.status = status
    this.body = body
  }
}

export async function api<T = unknown>(
  path: string,
  init: RequestInit = {},
): Promise<T> {
  const token = getToken()
  const headers = new Headers(init.headers)
  headers.set('Accept', 'application/json')
  if (init.body && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json')
  }
  if (token) headers.set('X-Dune-Token', token)

  const res = await fetch(`${API_BASE}${path}`, { ...init, headers })
  const text = await res.text()
  let body: unknown = undefined
  if (text) {
    try { body = JSON.parse(text) } catch { body = text }
  }
  if (!res.ok) {
    const msg = (typeof body === 'object' && body && 'error' in body)
      ? String((body as { error: unknown }).error)
      : `${res.status} ${res.statusText}`
    throw new ApiError(res.status, msg, body)
  }
  return body as T
}

export function wsUrl(path: string): string {
  const token = getToken()
  const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  const host = window.location.host
  const sep = path.includes('?') ? '&' : '?'
  return `${proto}//${host}${path}${sep}t=${encodeURIComponent(token)}`
}
