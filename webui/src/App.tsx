import { Routes, Route } from 'react-router-dom'
import { AppShell } from './layout/AppShell'
import { Dashboard } from './pages/Dashboard'
import { Commands } from './pages/Commands'
import { Characters } from './pages/Characters'
import { Settings } from './pages/Settings'
import { PageStub } from './pages/PageStub'
import { StatusProvider } from './hooks/useStatus'

export default function App() {
  return (
    <StatusProvider>
      <AppShell>
        <Routes>
          <Route path="/"           element={<Dashboard />} />
          <Route path="/commands"   element={<Commands />} />
          <Route path="/terminal"   element={<PageStub title="Terminal"    icon="SquareTerminal"  description="Embedded PowerShell session for kubectl / SSH." phase="Phase 4" />} />
          <Route path="/characters" element={<Characters />} />
          <Route path="/gameconfig" element={<PageStub title="Game Config" icon="Sliders"         description="Edit DefaultGame.ini overrides at runtime." phase="Phase 2" />} />
          <Route path="/database"   element={<PageStub title="Database"    icon="Database"        description="Direct Postgres access with a SQL editor." phase="Phase 2" />} />
          <Route path="/sietches"   element={<PageStub title="Sietches"    icon="Network"         description="Switch between, create, and inspect sietches." phase="Phase 3" />} />
          <Route path="/settings"   element={<Settings />} />
          <Route path="/setup"      element={<PageStub title="Setup Wizard" icon="Wand2"          description="First-run guided setup." phase="Phase 3" />} />
          {/* /monitoring merged into Dashboard in v6.1 — redirect old path */}
          <Route path="/monitoring" element={<Dashboard />} />
          <Route path="*"           element={<PageStub title="Not Found"   icon="HelpCircle"      description="No page at that path." phase="—" />} />
        </Routes>
      </AppShell>
    </StatusProvider>
  )
}
