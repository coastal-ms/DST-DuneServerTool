import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { useApi } from './useApi'
import type { StatusSnapshot } from '../api/types'
import { api } from '../api/client'

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
  const s = useApi<StatusSnapshot>('/api/status', { intervalMs: 10_000 })
  const [cachedStatus] = useState<StatusSnapshot | null>(() => readCachedStatus())

  useEffect(() => {
    if (s.data) writeCachedStatus(s.data)
  }, [s.data])

  const value: StatusCtx = {
    status:   s.data ?? cachedStatus,
    loading:  s.loading,
    error:    s.error,
    refresh:  s.refresh,
    forceRefresh: async () => { await api<StatusSnapshot>('/api/status/refresh', { method: 'POST' }); await s.refresh() },
  }
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export function useStatus(): StatusCtx {
  const v = useContext(Ctx)
  if (!v) throw new Error('useStatus must be used within <StatusProvider>')
  return v
}
