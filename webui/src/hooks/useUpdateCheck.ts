import { useCallback, useSyncExternalStore } from 'react'
import type { UpdateCheck } from '../api/update'
import { checkForUpdate } from '../api/update'

const POLL_MS = 60 * 60 * 1000 // 1 hour

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
// reload or the next 6-hour poll. With a shared store, any update found by any
// consumer (or pushed via publishUpdateCheck) surfaces in the banner instantly.
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
    setState({ data: res })
  } catch (e) {
    setState({ error: e instanceof Error ? e.message : String(e) })
  } finally {
    inflight = false
    setState({ loading: false })
  }
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
  }
  return () => {
    listeners.delete(cb)
    mountCount -= 1
    if (mountCount <= 0 && pollId !== null) {
      window.clearInterval(pollId)
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
