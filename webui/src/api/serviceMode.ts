// Service-mode API — backs the "Stay online when signed out" toggle.
//
// Loopback-only on the backend: a remote viewer (Tailscale Funnel / Cloudflare
// domain / LAN) cannot register or remove the always-on scheduled task, and the
// UI hides the control entirely for them via isLocalViewer().
//
// SECURITY: enabling requires the host's Windows password so Task Scheduler can
// run the backend "whether logged on or not" with the user profile loaded. The
// password is sent once over the loopback API and is never stored by DST.
import { api } from './client'

export interface ServiceModeState {
  /** True when the always-on (run-when-signed-out) task exists for this user. */
  enabled: boolean
  /** False on a dev pwsh build (no .exe to register). UI should grey the toggle. */
  available: boolean
  taskName: string
  taskPath: string
  exePath?: string | null
  user: string
}

export function getServiceModeState() {
  return api<ServiceModeState>('/api/service-mode')
}

// Enable requires the Windows password; disable does not.
export function setServiceModeEnabled(enabled: boolean, password?: string) {
  return api<ServiceModeState>('/api/service-mode', {
    method: 'POST',
    body: JSON.stringify(enabled ? { enabled, password } : { enabled }),
  })
}
