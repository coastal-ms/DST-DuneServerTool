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
  replaceData: (value: T) => void
}

export function useApi<T>(path: string, opts: Options = {}): AsyncState<T> {
  const { intervalMs = 0, enabled = true } = opts
  const [data, setData] = useState<T | null>(null)
  const [loading, setLoading] = useState<boolean>(true)
  const [error, setError] = useState<string | null>(null)
  const mountedRef = useRef(true)
  const pathRef = useRef(path)
  const enabledRef = useRef(enabled)
  const inFlightRef = useRef<{ key: string; promise: Promise<void> } | null>(null)
  const requestVersionRef = useRef(0)

  const lastFetchRef = useRef(0)
  pathRef.current = path
  enabledRef.current = enabled

  const fetchOnce = useCallback(async () => {
    if (!enabled) return
    const key = path
    if (inFlightRef.current?.key === key) return inFlightRef.current.promise
    const requestVersion = ++requestVersionRef.current
    const request = (async () => {
      lastFetchRef.current = Date.now()
      setLoading(true)
      try {
        const out = await api<T>(path)
        if (mountedRef.current && enabledRef.current && pathRef.current === key &&
            requestVersionRef.current === requestVersion) {
          setData(out)
          setError(null)
        }
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e)
        if (mountedRef.current && enabledRef.current && pathRef.current === key &&
            requestVersionRef.current === requestVersion) setError(msg)
      } finally {
        if (mountedRef.current && enabledRef.current && pathRef.current === key &&
            requestVersionRef.current === requestVersion) setLoading(false)
      }
    })()
    inFlightRef.current = { key, promise: request }
    try {
      await request
    } finally {
      if (inFlightRef.current?.promise === request) inFlightRef.current = null
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

  const replaceData = useCallback((value: T) => {
    if (!mountedRef.current || !enabledRef.current) return
    // A forced result supersedes any older poll still in flight.
    ++requestVersionRef.current
    setData(value)
    setError(null)
    setLoading(false)
  }, [])

  return { data, loading, error, refresh: fetchOnce, replaceData }
}
