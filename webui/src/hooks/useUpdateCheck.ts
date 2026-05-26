import { useCallback, useEffect, useRef, useState } from 'react'
import type { UpdateCheck } from '../api/update'
import { checkForUpdate } from '../api/update'

const POLL_MS = 6 * 60 * 60 * 1000 // 6 hours

export interface UpdateState {
  data: UpdateCheck | null
  loading: boolean
  error: string | null
  refresh: () => Promise<void>
}

export function useUpdateCheck(): UpdateState {
  const [data, setData] = useState<UpdateCheck | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const inflight = useRef(false)

  const run = useCallback(async (force = false) => {
    if (inflight.current) return
    inflight.current = true
    setLoading(true)
    setError(null)
    try {
      const res = await checkForUpdate({ force })
      setData(res)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      inflight.current = false
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void run(false)
    const id = window.setInterval(() => { void run(false) }, POLL_MS)
    return () => window.clearInterval(id)
  }, [run])

  return { data, loading, error, refresh: () => run(true) }
}
