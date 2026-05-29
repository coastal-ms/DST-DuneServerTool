import { Routes, Route } from 'react-router-dom'
import { AppShell } from './layout/AppShell'
import { Dashboard } from './pages/Dashboard'
import { Commands } from './pages/Commands'
import { Characters } from './pages/Characters'
import { GameConfig } from './pages/GameConfig'
import { Database } from './pages/Database'
import { Sietches } from './pages/Sietches'
import { DDMap } from './pages/DDMap'
import { SetupWizard } from './pages/SetupWizard'
import { Settings } from './pages/Settings'
import { TerminalPage } from './pages/Terminal'
import { PageStub } from './pages/PageStub'
import { StatusProvider } from './hooks/useStatus'

export default function App() {
  return (
    <StatusProvider>
      <AppShell>
        <Routes>
          <Route path="/"           element={<Dashboard />} />
          <Route path="/commands"   element={<Commands />} />
          <Route path="/terminal"   element={<TerminalPage />} />
          <Route path="/characters" element={<Characters />} />
          <Route path="/gameconfig" element={<GameConfig />} />
          <Route path="/database"   element={<Database />} />
          <Route path="/sietches"   element={<Sietches />} />
          <Route path="/dd-map"     element={<DDMap />} />
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
