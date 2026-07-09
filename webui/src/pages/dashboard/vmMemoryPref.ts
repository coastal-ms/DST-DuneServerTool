// Persisted user preference for the VM memory-pressure dashboard banner.
//
// The banner flags real trouble (OOM-kills / Postgres eviction), but it proved
// too intrusive to show by default, so it is now OPT-IN: hidden unless the
// operator explicitly enables it under Settings → Dashboard warnings. This
// stores a single "enabled" flag in localStorage (absent = off) and exposes a
// live-updating hook so the banner (reader) and the Settings toggle (reader +
// writer) stay in sync without a page reload. The server-side probe and the
// diagnostics-bundle entry are unchanged — this only governs the banner UI.
import { useEffect, useState } from 'react'

const KEY = 'dst.vmMemPressure.enabled'
const EVENT = 'dst:vmMemPressurePref'

export function isVmMemPressureEnabled(): boolean {
  try {
    return localStorage.getItem(KEY) === '1'
  } catch {
    return false
  }
}

export function setVmMemPressureEnabled(enabled: boolean): void {
  try {
    if (enabled) localStorage.setItem(KEY, '1')
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

// Shared live-updating hook. Returns [enabled, setEnabled]. Subscribes to
// same-tab changes (custom event) and cross-tab changes (storage event).
export function useVmMemPressureEnabled(): [boolean, (enabled: boolean) => void] {
  const [enabled, setEnabled] = useState<boolean>(isVmMemPressureEnabled)

  useEffect(() => {
    const sync = () => setEnabled(isVmMemPressureEnabled())
    window.addEventListener(EVENT, sync)
    window.addEventListener('storage', sync)
    return () => {
      window.removeEventListener(EVENT, sync)
      window.removeEventListener('storage', sync)
    }
  }, [])

  return [enabled, setVmMemPressureEnabled]
}
