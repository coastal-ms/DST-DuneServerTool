import { useCallback, useEffect, useRef, useState } from 'react'
import { getDuneAdminWebUrl, type DuneAdminWebUrl } from '../api/duneAdmin'

const POLL_MS = 30_000

export interface DuneAdminWebUrlState {
  data: DuneAdminWebUrl | null
  loading: boolean
  error: string | null
  refresh: () => Promise<void>
}

/** Polls /api/dune-admin/web-url so anything that wants to react to whether
 *  dune-admin is installed + currently listening can do so without each
 *  consumer running its own poller. Default cadence is 30 s, which is fine
 *  for menu visibility; the DuneAdmin page itself runs a faster local poller
 *  (every couple seconds) while waiting for the process to come up after a
 *  "Start dune-admin" click. */
export function useDuneAdminWebUrl(intervalMs: number = POLL_MS): DuneAdminWebUrlState {
  const [data, setData] = useState<DuneAdminWebUrl | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const inflight = useRef(false)

  const run = useCallback(async () => {
    if (inflight.current) return
    inflight.current = true
    setLoading(true)
    setError(null)
    try {
      const res = await getDuneAdminWebUrl()
      setData(res)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      inflight.current = false
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void run()
    const id = window.setInterval(() => { void run() }, intervalMs)
    return () => window.clearInterval(id)
  }, [run, intervalMs])

  return { data, loading, error, refresh: run }
}
