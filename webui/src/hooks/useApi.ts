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

  const lastFetchRef = useRef(0)

  const fetchOnce = useCallback(async () => {
    if (!enabled) return
    lastFetchRef.current = Date.now()
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

    // This app is designed to stay open indefinitely. Browsers throttle
    // setInterval in backgrounded tabs and freeze it entirely while the
    // machine sleeps, so when the operator returns to an always-open Server
    // Health window the polled data can be badly stale and won't refresh
    // until the next (possibly long-delayed) tick. Re-fetch the moment the
    // page regains visibility or window focus so what they see is current.
    // Coalesce the two events (and avoid hammering right after a tick) with a
    // short staleness guard.
    let onWake: (() => void) | undefined
    if (intervalMs > 0 && enabled) {
      const staleAfter = Math.min(intervalMs, 5_000)
      onWake = () => {
        if (document.visibilityState !== 'visible') return
        if (Date.now() - lastFetchRef.current < staleAfter) return
        void fetchOnce()
      }
      document.addEventListener('visibilitychange', onWake)
      window.addEventListener('focus', onWake)
    }

    return () => {
      mountedRef.current = false
      if (id) window.clearInterval(id)
      if (onWake) {
        document.removeEventListener('visibilitychange', onWake)
        window.removeEventListener('focus', onWake)
      }
    }
  }, [fetchOnce, intervalMs, enabled])

  return { data, loading, error, refresh: fetchOnce }
}
