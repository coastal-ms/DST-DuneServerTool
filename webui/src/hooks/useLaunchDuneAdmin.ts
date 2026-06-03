import { useCallback, useState } from 'react'
import { api } from '../api/client'
import { getDuneAdminWebUrl } from '../api/duneAdmin'

// Launches dune-admin (Icehunter's character/player editor). Server skips the
// spawn if it's already running, then returns its players-page URL. If the
// launch endpoint fails we fall back to resolving the listen port and opening
// the page directly so a user that already has dune-admin up isn't stuck.
export function useLaunchDuneAdmin() {
  const [launching, setLaunching] = useState(false)

  const launch = useCallback(async () => {
    if (launching) return
    setLaunching(true)
    try {
      await api('/api/commands/run/dune-admin', { method: 'POST' })
    } catch {
      try {
        const web = await getDuneAdminWebUrl()
        if (web.listening) window.open(web.url, '_blank', 'noopener')
      } catch {
        // give up silently — better than opening the wrong port
      }
    } finally {
      setLaunching(false)
    }
  }, [launching])

  return { launching, launch }
}
