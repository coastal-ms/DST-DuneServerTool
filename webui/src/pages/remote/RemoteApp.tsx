import { useEffect, useState } from 'react'
import { Routes, Route, Navigate, mergeNavigationLocation } from '../../router'
import { RemoteShell } from './RemoteShell'
import { RemoteDashboard } from './Dashboard'
import { RemoteMaps } from './Maps'
import { LoginRequired } from './LoginRequired'
import { DataState } from '../../components/platform/DataState'
import { getPortalAuthStatus } from '../../api/portalAuth'
import { LEGACY_REMOTE_MAP_DESTINATION, shouldRedirectLegacyRemoteMap } from '../../platform/routes'

function LegacyMapCompatibility() {
  const [mode, setMode] = useState<'checking' | 'legacy' | 'redirecting'>('checking')

  useEffect(() => {
    let active = true
    getPortalAuthStatus()
      .then(status => {
        if (!active) return
        if (shouldRedirectLegacyRemoteMap(status.accountLoginEnabled)) {
          setMode('redirecting')
          window.location.replace(mergeNavigationLocation(
            LEGACY_REMOTE_MAP_DESTINATION,
            window.location.search,
            window.location.hash,
          ))
        } else {
          setMode('legacy')
        }
      })
      .catch(() => {
        if (active) setMode('legacy')
      })
    return () => { active = false }
  }, [])

  if (mode === 'legacy') return <RemoteMaps />
  return (
    <DataState
      state="loading"
      title={mode === 'redirecting' ? 'Opening the Map workspace…' : 'Checking portal access…'}
    />
  )
}

// Top-level component for the remote portal tree (issue #74).
//
// Intentionally NOT wrapped in the desktop <StatusProvider> / <AppShell> —
// those poll local-only APIs and render sidebar/menubar/statusbar chrome
// that doesn't belong on a mobile remote view. The split happens in
// main.tsx, where /remote/* paths get this component instead of <App />.
//
// All routes under /remote/* render here; the static handler serves this
// index.html (with the DuneToken injected) so client-side navigation works.
export default function RemoteApp() {
  return (
    <RemoteShell>
      <Routes>
        <Route path="/remote"                element={<RemoteDashboard />} />
        <Route path="/remote/"               element={<RemoteDashboard />} />
        <Route path="/remote/maps"           element={<LegacyMapCompatibility />} />
        <Route path="/remote/login-required" element={<LoginRequired />} />
        <Route path="*"                      element={<Navigate to="/remote" replace />} />
      </Routes>
    </RemoteShell>
  )
}
