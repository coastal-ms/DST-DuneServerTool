// Persisted user preference for the VM memory-pressure dashboard banner.
//
// The banner is intentionally loud (it flags OOM-kills / Postgres eviction),
// but operators who understand the risk asked to silence it permanently. This
// stores a single "hidden" flag in localStorage and exposes a live-updating
// hook so the banner (reader) and the Settings re-enable toggle (reader +
// writer) stay in sync without a page reload.
import { useEffect, useState } from 'react'

const KEY = 'dst.vmMemPressure.hidden'
const EVENT = 'dst:vmMemPressurePref'

export function isVmMemPressureHidden(): boolean {
  try {
    return localStorage.getItem(KEY) === '1'
  } catch {
    return false
  }
}

export function setVmMemPressureHidden(hidden: boolean): void {
  try {
    if (hidden) localStorage.setItem(KEY, '1')
    else localStorage.removeItem(KEY)
  } catch {
    /* private mode / storage disabled — nothing we can do, fail quiet */
  }
  try {
    window.dispatchEvent(new CustomEvent(EVENT))
  } catch {
    /* ignore */
  }
}

// Shared live-updating hook. Returns [hidden, setHidden]. Subscribes to same-tab
// changes (custom event) and cross-tab changes (storage event).
export function useVmMemPressureHidden(): [boolean, (hidden: boolean) => void] {
  const [hidden, setHidden] = useState<boolean>(isVmMemPressureHidden)

  useEffect(() => {
    const sync = () => setHidden(isVmMemPressureHidden())
    window.addEventListener(EVENT, sync)
    window.addEventListener('storage', sync)
    return () => {
      window.removeEventListener(EVENT, sync)
      window.removeEventListener('storage', sync)
    }
  }, [])

  return [hidden, setVmMemPressureHidden]
}
