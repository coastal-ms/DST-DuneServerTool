// Live connectivity tracker for the local DST backend.
//
// The backend's auth token is a per-launch GUID that ROTATES on every restart,
// and the HTTP listener briefly drops while the tool restarts or self-updates.
// The WebView2 app survives this because it re-navigates to the fresh URL (with
// the new token); a detached browser tab does not, so it ends up stranded with
// "Failed to fetch" panels and a token the server no longer accepts.
//
// This tiny store lets the API client report fetch outcomes so <ReconnectOverlay>
// can detect the drop, wait for the server to come back, and reload — at which
// point the backend re-injects the current token (window.__duneRemoteToken) and
// the session recovers automatically.

export type ConnState = 'connected' | 'recovering'

let state: ConnState = 'connected'
const listeners = new Set<() => void>()

function emit(): void {
  for (const l of listeners) l()
}

function set(next: ConnState): void {
  if (next === state) return
  state = next
  emit()
}

/** A fetch() rejected (network-level failure) — the listener is unreachable. */
export function reportNetworkError(): void {
  set('recovering')
}

/**
 * The backend returned an HTTP response. Any status code means the listener is
 * up. A 401 when we DID send a token means the per-launch token rotated (the
 * server restarted), so we recover the same way as a hard drop: reload to pick
 * up the freshly-injected token.
 */
export function reportResponse(status: number, sentToken: boolean): void {
  if (status === 401 && sentToken) {
    set('recovering')
    return
  }
  set('connected')
}

export function getConnState(): ConnState {
  return state
}

export function subscribeConn(cb: () => void): () => void {
  listeners.add(cb)
  return () => { listeners.delete(cb) }
}
