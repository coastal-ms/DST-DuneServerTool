// Backend-console window control — backs Help → Show / Hide backend console.
//
// Loopback-only on the backend: a remote viewer (Tailscale / LAN) cannot toggle
// the host machine's console window, and the UI hides the menu entry entirely
// in that case via isLocalViewer().
import { api } from './client'

export interface ConsoleState {
  /** False when running as a dev pwsh shell (no DuneServer.exe console to control). UI hides the menu item. */
  available: boolean
  /** True when the console window is currently visible (shown or minimized — not SW_HIDE'd). */
  visible: boolean
  /** True when the console window is minimized to the taskbar. */
  minimized: boolean
}

export function getConsoleState() {
  return api<ConsoleState>('/api/console')
}

export function setConsoleVisible(visible: boolean) {
  return api<ConsoleState>('/api/console', {
    method: 'POST',
    body: JSON.stringify({ visible }),
  })
}
