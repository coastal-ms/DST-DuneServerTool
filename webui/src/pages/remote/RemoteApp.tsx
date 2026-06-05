import { Routes, Route, Navigate } from 'react-router-dom'
import { RemoteShell } from './RemoteShell'
import { RemoteDashboard } from './Dashboard'
import { RemoteMaps } from './Maps'
import { LoginRequired } from './LoginRequired'

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
        <Route path="/remote/maps"           element={<RemoteMaps />} />
        <Route path="/remote/login-required" element={<LoginRequired />} />
        <Route path="*"                      element={<Navigate to="/remote" replace />} />
      </Routes>
    </RemoteShell>
  )
}
