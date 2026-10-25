import { useEffect, useState } from 'react'

type AwakeState = 'inactive' | 'requesting' | 'active' | 'unavailable'

/** Keep a visible map awake; release on pause, navigation or a hidden page. */
export function useScreenAwake(enabled: boolean): AwakeState {
  const [status, setStatus] = useState<AwakeState>('inactive')
  useEffect(() => {
    if (!enabled) return
    let active = true, pending = false, pageActive = true, recoveryAvailable = true
    let recovery: ReturnType<typeof setTimeout> | undefined
    let lock: WakeLockSentinel | null = null
    const release = () => {
      clearTimeout(recovery)
      const current = lock
      lock = null
      if (current) void current.release().catch(() => {})
    }
    const acquire = async () => {
      if (lock?.released) lock = null
      if (!active || !pageActive || document.visibilityState !== 'visible' || pending || lock) return
      if (!navigator.wakeLock) { setStatus('unavailable'); return }
      pending = true
      setStatus('requesting')
      try {
        const next = await navigator.wakeLock.request('screen')
        if (!active || !pageActive || document.visibilityState !== 'visible') {
          await next.release()
          return
        }
        lock = next
        next.addEventListener('release', () => {
          if (lock === next) {
            lock = null
            if (active) {
              setStatus('unavailable')
              // Recover one unexpected release. A device refusing locks must
              // not cause a request loop; another gesture can explicitly retry.
              if (pageActive && document.visibilityState === 'visible' && recoveryAvailable) {
                recoveryAvailable = false
                recovery = setTimeout(() => void acquire(), 250)
              }
            }
          }
        })
        setStatus('active')
      } catch { if (active) setStatus('unavailable') }
      finally { pending = false }
    }
    const retry = () => { recoveryAvailable = true; void acquire() }
    const renew = () => { release(); retry() }
    const visibility = () => {
      if (document.visibilityState === 'visible') retry()
      else release()
    }
    const hide = () => { pageActive = false; release() }
    const show = () => { pageActive = true; visibility() }
    void acquire()
    document.addEventListener('visibilitychange', visibility)
    window.addEventListener('pagehide', hide)
    window.addEventListener('pageshow', show)
    window.addEventListener('focus', retry)
    window.addEventListener('dst-screen-awake-retry', renew)
    window.addEventListener('dst-screen-awake-activity', retry)
    document.addEventListener('pointerdown', retry)
    document.addEventListener('keydown', retry)
    return () => {
      active = false
      document.removeEventListener('visibilitychange', visibility)
      window.removeEventListener('pagehide', hide)
      window.removeEventListener('pageshow', show)
      window.removeEventListener('focus', retry)
      window.removeEventListener('dst-screen-awake-retry', renew)
      window.removeEventListener('dst-screen-awake-activity', retry)
      document.removeEventListener('pointerdown', retry)
      document.removeEventListener('keydown', retry)
      release()
    }
  }, [enabled])
  return enabled ? status : 'inactive'
}
