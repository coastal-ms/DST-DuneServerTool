import { useEffect, useState } from 'react'

type AwakeState = 'inactive' | 'requesting' | 'active' | 'unavailable'

/** Keep the visible expanded map awake; never hold a lock after leaving it. */
export function useScreenAwake(enabled: boolean): AwakeState {
  const [status, setStatus] = useState<AwakeState>('inactive')
  useEffect(() => {
    if (!enabled) return
    let active = true, pending = false
    let lock: WakeLockSentinel | null = null
    const release = () => {
      const current = lock
      lock = null
      if (current) void current.release().catch(() => {})
    }
    const acquire = async () => {
      if (!active || document.visibilityState !== 'visible' || pending || lock) return
      if (!navigator.wakeLock) { setStatus('unavailable'); return }
      pending = true
      setStatus('requesting')
      try {
        const next = await navigator.wakeLock.request('screen')
        if (!active || document.visibilityState !== 'visible') {
          await next.release()
          return
        }
        lock = next
        next.addEventListener('release', () => {
          if (lock === next) {
            lock = null
            if (active) setStatus('unavailable')
          }
        })
        setStatus('active')
      } catch { if (active) setStatus('unavailable') }
      finally { pending = false }
    }
    const visibility = () => {
      if (document.visibilityState === 'visible') void acquire()
      else release()
    }
    void acquire()
    document.addEventListener('visibilitychange', visibility)
    window.addEventListener('pagehide', release)
    window.addEventListener('pageshow', visibility)
    return () => {
      active = false
      document.removeEventListener('visibilitychange', visibility)
      window.removeEventListener('pagehide', release)
      window.removeEventListener('pageshow', visibility)
      release()
    }
  }, [enabled])
  return enabled ? status : 'inactive'
}
