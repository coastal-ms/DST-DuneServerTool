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
import { Tailscale } from './pages/Tailscale'
import { PageStub } from './pages/PageStub'
import { StatusProvider } from './hooks/useStatus'
import { isLocalViewer } from './util/viewer'
import { PageErrorBoundary } from './components/PageErrorBoundary'

// Wrap every route subtree in an error boundary so an unhandled render
// exception on one page can't white-out the entire app. The boundary
// renders an inline error card with the JS stack trace and logs the
// failure through console.error so it lands in webview2-debug.log for
// the diagnostics ZIP (added in v12.0.1).
function Boundary({ name, children }: { name: string; children: React.ReactNode }) {
  return <PageErrorBoundary pageName={name}>{children}</PageErrorBoundary>
}

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
          <Route path="/"           element={<Boundary name="Dashboard"><Dashboard /></Boundary>} />
          <Route path="/commands"   element={<Boundary name="Commands"><Commands /></Boundary>} />
          <Route
            path="/terminal"
            element={showTerminal
              ? <Boundary name="Terminal"><TerminalPage /></Boundary>
              : <Navigate to="/" replace />}
          />
          <Route path="/gameconfig" element={<Boundary name="Game Config"><GameConfig /></Boundary>} />
          <Route path="/gameplay"   element={<Boundary name="Gameplay Admin"><GameplayEnvironment /></Boundary>} />
          <Route path="/database"   element={<Boundary name="Database"><Database /></Boundary>} />
          <Route path="/sietches"   element={<Boundary name="Sietches"><Sietches /></Boundary>} />
          <Route path="/dd-map"     element={<Boundary name="Deep Desert Map"><DDMap /></Boundary>} />
          <Route path="/map-spinup" element={<Boundary name="Map SpinUp"><MapSpinUp /></Boundary>} />
          <Route path="/settings"   element={<Boundary name="Settings"><Settings /></Boundary>} />
          <Route path="/setup"      element={<Boundary name="Setup Wizard"><SetupWizard /></Boundary>} />
          <Route
            path="/tailscale"
            element={isLocalViewer()
              ? <Boundary name="Tailscale"><Tailscale /></Boundary>
              : <Navigate to="/" replace />}
          />
          {/* /monitoring merged into Dashboard in v6.1 — redirect old path */}
          <Route path="/monitoring" element={<Boundary name="Dashboard"><Dashboard /></Boundary>} />
          <Route path="*"           element={<PageStub title="Not Found"   icon="HelpCircle"      description="No page at that path." phase="—" />} />
        </Routes>
      </AppShell>
    </StatusProvider>
  )
}
