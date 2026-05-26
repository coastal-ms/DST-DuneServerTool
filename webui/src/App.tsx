import { Routes, Route } from 'react-router-dom'
import { AppShell } from './layout/AppShell'
import { Dashboard } from './pages/Dashboard'
import { PageStub } from './pages/PageStub'

export default function App() {
  return (
    <AppShell>
      <Routes>
        <Route path="/"           element={<Dashboard />} />
        <Route path="/monitoring" element={<PageStub title="Monitoring"  icon="Activity"        description="Live pod, log, and resource streams." phase="Phase 3" />} />
        <Route path="/terminal"   element={<PageStub title="Terminal"    icon="SquareTerminal"  description="Embedded PowerShell session for kubectl / SSH." phase="Phase 4" />} />
        <Route path="/characters" element={<PageStub title="Characters"  icon="Users"           description="Browse, search, and manage player characters." phase="Phase 2" />} />
        <Route path="/gameconfig" element={<PageStub title="Game Config" icon="Sliders"         description="Edit DefaultGame.ini overrides at runtime." phase="Phase 2" />} />
        <Route path="/database"   element={<PageStub title="Database"    icon="Database"        description="Direct Postgres access with a SQL editor." phase="Phase 2" />} />
        <Route path="/sietches"   element={<PageStub title="Sietches"    icon="Network"         description="Switch between, create, and inspect sietches." phase="Phase 3" />} />
        <Route path="/settings"   element={<PageStub title="Settings"    icon="Settings"        description="Tool configuration (dune-server.config)." phase="Phase 1" />} />
        <Route path="/setup"      element={<PageStub title="Setup Wizard" icon="Wand2"          description="First-run guided setup." phase="Phase 3" />} />
        <Route path="*"           element={<PageStub title="Not Found"   icon="HelpCircle"      description="No page at that path." phase="—" />} />
      </Routes>
    </AppShell>
  )
}
