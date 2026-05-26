import { useEffect, useState, useCallback, useRef } from 'react'
import { api } from '../api/client'

type Options = {
  intervalMs?: number
  enabled?: boolean
}

export type AsyncState<T> = {
  data: T | null
  loading: boolean
  error: string | null
  refresh: () => Promise<void>
}

export function useApi<T>(path: string, opts: Options = {}): AsyncState<T> {
  const { intervalMs = 0, enabled = true } = opts
  const [data, setData] = useState<T | null>(null)
  const [loading, setLoading] = useState<boolean>(true)
  const [error, setError] = useState<string | null>(null)
  const mountedRef = useRef(true)

  const fetchOnce = useCallback(async () => {
    if (!enabled) return
    setLoading(true)
    try {
      const out = await api<T>(path)
      if (mountedRef.current) {
        setData(out)
        setError(null)
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      if (mountedRef.current) setError(msg)
    } finally {
      if (mountedRef.current) setLoading(false)
    }
  }, [path, enabled])

  useEffect(() => {
    mountedRef.current = true
    void fetchOnce()
    let id: number | undefined
    if (intervalMs > 0 && enabled) {
      id = window.setInterval(() => { void fetchOnce() }, intervalMs)
    }
    return () => {
      mountedRef.current = false
      if (id) window.clearInterval(id)
    }
  }, [fetchOnce, intervalMs, enabled])

  return { data, loading, error, refresh: fetchOnce }
}
