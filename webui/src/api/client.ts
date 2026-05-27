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

/**
 * Server response shape when a mutating endpoint refuses to run because
 * one or more players are currently connected. The route returns HTTP 409
 * and the client is expected to confirm with the operator before retrying
 * with `?force=true`.
 */
export interface PlayersOnlineConflict {
  ok: false
  conflict: 'players_online'
  playersOnline: number
  playerNames: string[]
  players: Array<{ id: string; name: string; status: string }>
  message: string
}

/**
 * Wraps a mutation that accepts an optional `force` flag. The first attempt
 * runs without `force`; if the server returns 409 with the players-online
 * conflict body, the user is prompted, and on confirmation the call is
 * retried with `force=true`. If the user declines, an ApiError(409) is
 * thrown so the caller's existing error handling reports it the same way
 * as any other failed save.
 */
export async function withOnlinePlayerGuard<T>(
  fn: (force: boolean) => Promise<T>,
): Promise<T> {
  try {
    return await fn(false)
  } catch (e) {
    if (e instanceof ApiError && e.status === 409) {
      const body = e.body as Partial<PlayersOnlineConflict> | undefined
      if (body && body.conflict === 'players_online') {
        const names = body.playerNames ?? []
        const count = body.playersOnline ?? names.length
        const list = names.length > 0
          ? names.slice(0, 8).join(', ') + (names.length > 8 ? `, +${names.length - 8} more` : '')
          : `${count} player(s)`
        const ok = window.confirm(
          `${count} player${count === 1 ? '' : 's'} currently online:\n  ${list}\n\n`
          + `Saving while players are connected can corrupt their characters `
          + `(the game may overwrite your changes when they next save, and an actor `
          + `loading mid-edit has caused a full inventory/recipe wipe in the past).\n\n`
          + `Save anyway?`,
        )
        if (!ok) {
          throw new ApiError(409, 'Save cancelled — players online.', body)
        }
        return await fn(true)
      }
    }
    throw e
  }
}
