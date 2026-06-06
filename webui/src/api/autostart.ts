// Autostart API — backs the Help → "Run at Windows startup" toggle.
//
// Loopback-only on the backend: a remote viewer (Tailscale / LAN) cannot
// register or remove the per-user scheduled task on the host machine, and the
// UI hides the menu entry entirely in that case via isLocalViewer().
import { api } from './client'

export interface AutostartState {
  /** True when a per-user scheduled task currently exists for the logged-in user. */
  enabled: boolean
  /** False when running from a dev pwsh shell (no .exe to register). UI should grey the toggle. */
  available: boolean
  taskName: string
  taskPath: string
  exePath?: string | null
  user: string
}

export function getAutostartState() {
  return api<AutostartState>('/api/autostart')
}

export function setAutostartEnabled(enabled: boolean) {
  return api<AutostartState>('/api/autostart', {
    method: 'POST',
    body: JSON.stringify({ enabled }),
  })
}
