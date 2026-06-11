import { Routes, Route, Navigate } from 'react-router-dom'
import { AppShell } from './layout/AppShell'
import { Dashboard } from './pages/Dashboard'
import { Commands } from './pages/Commands'
import { GameConfig } from './pages/GameConfig'
import { GameplayEnvironment } from './pages/GameplayEnvironment'
import { Database } from './pages/Database'
import { Sietches } from './pages/Sietches'
import { DDMap } from './pages/DDMap'
import { MapSpinUp } from './pages/MapSpinUp'
import { SetupWizard } from './pages/SetupWizard'
import { Settings } from './pages/Settings'
import { TerminalPage } from './pages/Terminal'
import { PageStub } from './pages/PageStub'
import { StatusProvider } from './hooks/useStatus'
import { isLocalViewer } from './util/viewer'

export default function App() {
  // The free-form PowerShell page can run arbitrary commands on the host
  // as the DuneServer service user. It's safe locally (you're already on
  // the host with admin) but a foot-gun for remote viewers (friend over
  // Tailscale), so we redirect /terminal to Server Health for them. The
  // backend /ws/terminal route enforces this too — this is just the UX
  // half so the page doesn't render an empty failing terminal.
  const showTerminal = isLocalViewer()
  return (
    <StatusProvider>
      <AppShell>
        <Routes>
          <Route path="/"           element={<Dashboard />} />
          <Route path="/commands"   element={<Commands />} />
          <Route
            path="/terminal"
            element={showTerminal ? <TerminalPage /> : <Navigate to="/" replace />}
          />
          <Route path="/gameconfig" element={<GameConfig />} />
          <Route path="/gameplay"   element={<GameplayEnvironment />} />
          <Route path="/database"   element={<Database />} />
          <Route path="/sietches"   element={<Sietches />} />
          <Route path="/dd-map"     element={<DDMap />} />
          <Route path="/map-spinup" element={<MapSpinUp />} />
          <Route path="/settings"   element={<Settings />} />
          <Route path="/setup"      element={<SetupWizard />} />
          {/* /monitoring merged into Dashboard in v6.1 — redirect old path */}
          <Route path="/monitoring" element={<Dashboard />} />
          <Route path="*"           element={<PageStub title="Not Found"   icon="HelpCircle"      description="No page at that path." phase="—" />} />
        </Routes>
      </AppShell>
    </StatusProvider>
  )
}
