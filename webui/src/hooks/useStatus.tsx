import { createContext, useContext, type ReactNode } from 'react'
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

export function StatusProvider({ children }: { children: ReactNode }) {
  const s = useApi<StatusSnapshot>('/api/status', { intervalMs: 10_000 })
  const value: StatusCtx = {
    status:   s.data,
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
