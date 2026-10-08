import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { api } from '../api/client'

const InstallationContext = createContext<'full' | 'solo'>('full')

export function InstallationProvider({ children }: { children: ReactNode }) {
  const [mode, setMode] = useState<'full' | 'solo' | null>(null)
  const [error, setError] = useState(false)
  useEffect(() => {
    let active = true
    api<{ mode: 'full' | 'solo' }>('/api/installation')
      .then(result => { if (active) setMode(result.mode === 'solo' ? 'solo' : 'full') })
      .catch(() => { if (active) setError(true) })
    return () => { active = false }
  }, [])
  if (error) return <div role="alert" className="p-6">Could not load your DST setup. Reload to try again.</div>
  if (!mode) return <div role="status" className="p-6">Opening DST…</div>
  return <InstallationContext.Provider value={mode}>{children}</InstallationContext.Provider>
}

export function useSoloInstallation() {
  return useContext(InstallationContext) === 'solo'
}

export function isSoloDestination(path: string) {
  return ['/solo', '/settings', '/sponsors'].includes(path.split('?')[0])
}
