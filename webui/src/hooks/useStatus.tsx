import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react'
import { useApi } from './useApi'
import type { StatusSnapshot } from '../api/types'
import { api } from '../api/client'
import { useHealthRefreshPreset } from './useHealthRefresh'
import { useSoloInstallation } from './useInstallationMode'

type StatusCtx = {
  status: StatusSnapshot | null
  loading: boolean
  error: string | null
  refresh: () => Promise<void>
  forceRefresh: () => Promise<void>
}

const Ctx = createContext<StatusCtx | null>(null)

export const STATUS_CACHE_KEY = 'dst.status.last.v1'
export const STATUS_CACHE_MAX_AGE_MS = 30 * 60 * 1000

type StatusStorage = Pick<Storage, 'getItem' | 'setItem'>

export function readCachedStatus(
  storage: StatusStorage = localStorage,
  now = Date.now(),
): StatusSnapshot | null {
  try {
    const raw = storage.getItem(STATUS_CACHE_KEY)
    if (!raw) return null
    const parsed = JSON.parse(raw) as {
      savedAt?: unknown
      status?: Partial<StatusSnapshot>
    }
    if (
      typeof parsed.savedAt !== 'number'
      || !Number.isFinite(parsed.savedAt)
      || parsed.savedAt > now
      || now - parsed.savedAt > STATUS_CACHE_MAX_AGE_MS
      || !parsed.status
      || typeof parsed.status.ts !== 'string'
      || !parsed.status.vm
      || typeof parsed.status.vm !== 'object'
    ) return null
    return parsed.status as StatusSnapshot
  } catch {
    return null
  }
}

export function writeCachedStatus(
  status: StatusSnapshot,
  storage: StatusStorage = localStorage,
  now = Date.now(),
): void {
  try {
    storage.setItem(STATUS_CACHE_KEY, JSON.stringify({ savedAt: now, status }))
  } catch {
    // Storage may be disabled or full; live status remains authoritative.
  }
}

export function StatusProvider({ children }: { children: ReactNode }) {
  const refreshPreset = useHealthRefreshPreset()
  const soloOnly = useSoloInstallation()
  const [mapViewerPaused, setMapViewerPaused] = useState(false)
  useEffect(() => {
    const receive = (event: Event) => { setMapViewerPaused((event as CustomEvent).detail === true) }
    window.addEventListener('dst-map-viewer-paused', receive)
    return () => window.removeEventListener('dst-map-viewer-paused', receive)
  }, [])
  const s = useApi<StatusSnapshot>('/api/status', { intervalMs: refreshPreset.statusIntervalMs, enabled: !soloOnly && !mapViewerPaused })
  const [forcing, setForcing] = useState(false)
  const [forceError, setForceError] = useState<string | null>(null)
  const forcedRequest = useRef<Promise<void> | null>(null)
  const [cachedStatus] = useState<StatusSnapshot | null>(() => readCachedStatus())

  useEffect(() => {
    if (s.data) writeCachedStatus(s.data)
  }, [s.data])

  const value: StatusCtx = {
    status:   soloOnly ? null : s.data ?? cachedStatus,
    loading:  !soloOnly && (s.loading || forcing),
    error:    soloOnly ? null : forceError ?? s.error,
    refresh:  s.refresh,
    forceRefresh: async () => {
      if (soloOnly) return
      if (forcedRequest.current) return forcedRequest.current
      setForcing(true); setForceError(null)
      const pending = (async () => {
        try {
          const fresh = await api<StatusSnapshot>('/api/status/refresh', { method: 'POST' })
          s.replaceData(fresh)
        } catch (e) {
          setForceError(`Status refresh failed: ${e instanceof Error ? e.message : String(e)}`)
        } finally {
          setForcing(false); forcedRequest.current = null
        }
      })()
      forcedRequest.current = pending
      return pending
    },
  }
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export function useStatus(): StatusCtx {
  const v = useContext(Ctx)
  if (!v) throw new Error('useStatus must be used within <StatusProvider>')
  return v
}

// Progress also appears in the widget, outside the full server-status provider.
export function useStatusSnapshot(): StatusSnapshot | null {
  return useContext(Ctx)?.status ?? null
}
