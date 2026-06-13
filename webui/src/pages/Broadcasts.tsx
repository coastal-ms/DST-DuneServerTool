import { PageHeader } from '../components/PageHeader'
import { AdminComposers } from '../components/AdminComposers'

// Standalone page wrapper around the shared composers. The same three cards
// (broadcast / shutdown / whisper) are also embedded at the top of Gameplay
// Overview. This page exists so operators can deep-link / bookmark just the
// admin-messaging surface without scrolling the rest of the gameplay console.
export function Broadcasts() {
  return (
    <div className="p-4">
      <PageHeader
        icon="Megaphone"
        title="Broadcasts & whispers"
        description="Server-wide announcements, shutdown countdowns, and per-player whispers. Mirrors dune-admin's /notify, wired straight to the in-game courier."
      />
      <AdminComposers className="mt-4" />
    </div>
  )
}
