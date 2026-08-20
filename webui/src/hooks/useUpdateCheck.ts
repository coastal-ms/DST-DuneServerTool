import { useCallback, useSyncExternalStore } from 'react'
import type { UpdateCheck } from '../api/update'
import { checkForUpdate } from '../api/update'

const POLL_MS = 60 * 60 * 1000 // 1 hour
const FOCUS_RECHECK_MS = 5 * 60 * 1000 // don't re-check on focus more than this often

export interface UpdateState {
  data: UpdateCheck | null
  loading: boolean
  error: string | null
  refresh: () => Promise<void>
}

// ---------------------------------------------------------------------------
// Shared, module-level store.
//
// Every consumer of useUpdateCheck() reads from this single source of truth.
// Previously each call kept its own isolated useState, so a forced "Check now"
// on the Settings page updated only that component's copy while the global
// UpdateBanner kept its own stale result and stayed hidden until a full page
// reload or the next background poll. With a shared store, any update found by any
// consumer (or pushed via publishUpdateCheck) surfaces in the banner instantly.
// The background poll runs hourly, with an additional throttled re-check when
// the window regains focus so a machine that was asleep or backgrounded doesn't
// sit on a stale result.
// ---------------------------------------------------------------------------

interface Snapshot {
  data: UpdateCheck | null
  loading: boolean
  error: string | null
}

let snapshot: Snapshot = { data: null, loading: false, error: null }
const listeners = new Set<() => void>()
let inflight = false
let started = false
let pollId: number | null = null
let mountCount = 0
let lastCheckedAt = 0

function emit() {
  for (const l of listeners) l()
}

function setState(patch: Partial<Snapshot>) {
  snapshot = { ...snapshot, ...patch }
  emit()
}

async function run(force = false): Promise<void> {
  if (inflight) return
  inflight = true
  setState({ loading: true, error: null })
  try {
    const res = await checkForUpdate({ force })
    lastCheckedAt = Date.now()
    setState({ data: res })
  } catch (e) {
    setState({ error: e instanceof Error ? e.message : String(e) })
  } finally {
    inflight = false
    setState({ loading: false })
  }
}

// The hourly poll only fires while the window is open and awake; a machine that
// was asleep, or a window left in the background, can otherwise show a stale
// result for up to an hour after a release. Re-check when the user comes back,
// throttled so tabbing in and out doesn't spam the endpoint.
function onWake(): void {
  if (document.visibilityState === 'hidden') return
  if (Date.now() - lastCheckedAt < FOCUS_RECHECK_MS) return
  void run(false)
}

// Lets other components (e.g. the Settings update card, which runs its own
// force-check) feed a fresh result into the shared store so the global banner
// updates immediately — no page reload required.
export function publishUpdateCheck(data: UpdateCheck): void {
  setState({ data })
}

function subscribe(cb: () => void): () => void {
  listeners.add(cb)
  mountCount += 1
  if (!started) {
    started = true
    void run(false)
    pollId = window.setInterval(() => { void run(false) }, POLL_MS)
    window.addEventListener('focus', onWake)
    document.addEventListener('visibilitychange', onWake)
  }
  return () => {
    listeners.delete(cb)
    mountCount -= 1
    if (mountCount <= 0 && pollId !== null) {
      window.clearInterval(pollId)
      window.removeEventListener('focus', onWake)
      document.removeEventListener('visibilitychange', onWake)
      pollId = null
      started = false
      mountCount = 0
    }
  }
}

function getSnapshot(): Snapshot {
  return snapshot
}

export function useUpdateCheck(): UpdateState {
  const snap = useSyncExternalStore(subscribe, getSnapshot, getSnapshot)
  const refresh = useCallback(() => run(true), [])
  return { data: snap.data, loading: snap.loading, error: snap.error, refresh }
}
