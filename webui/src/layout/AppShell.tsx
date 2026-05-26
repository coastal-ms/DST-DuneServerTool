import type { ReactNode } from 'react'
import { Sidebar } from './Sidebar'
import { StatusBar } from './StatusBar'

export function AppShell({ children }: { children: ReactNode }) {
  return (
    <div className="h-full flex overflow-hidden">
      <Sidebar />
      <div className="flex-1 flex flex-col min-w-0">
        <StatusBar />
        <main className="flex-1 overflow-y-auto">
          <div className="max-w-7xl mx-auto px-6 py-6">
            {children}
          </div>
        </main>
      </div>
    </div>
  )
}
