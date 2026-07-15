// Setup Wizard API — preflight checks + config summary
import { api } from './client'

export interface PreflightCheck {
  key: string
  label: string
  ok: boolean
  severity: 'ok' | 'warning' | 'error' | 'info'
  detail: string
  fix?: string
  freeGB?: number
}

export interface PreflightResult {
  ok: boolean
  checks: PreflightCheck[]
  errorCount: number
  warningCount: number
}

export interface SetupConfigSummary {
  windowsUser: string | null
  sshKey: string | null
  sshKeyExists: boolean
  steamPath: string | null
  portCheckMode: string | null
  vmName: string
  sshPort: number
}

export function getPreflight(mode?: 'existing' | 'fresh' | 'lan') {
  const q = mode ? `?mode=${encodeURIComponent(mode)}` : ''
  return api<PreflightResult>(`/api/setup/preflight${q}`)
}
export function getSetupConfig() { return api<SetupConfigSummary>('/api/setup/config') }

// Hyper-V over LAN — manage a VM that lives on a separate Hyper-V host on the
// local network. 'mode' is the routing toggle: 'lan' points every Hyper-V call
// at hostIp; 'local' restores the default local-VM behavior.
export interface HyperVLanSettings { mode: 'local' | 'lan'; hostIp: string }
export interface HyperVLanTest { ok: boolean; vmFound: boolean; reason: string }

export function getHyperVLan() { return api<HyperVLanSettings>('/api/setup/hyperv-lan') }
export function saveHyperVLan(mode: 'local' | 'lan', hostIp: string) {
  return api<{ ok: boolean; mode: string; hostIp: string }>('/api/setup/hyperv-lan', {
    method: 'POST',
    body: JSON.stringify({ mode, hostIp }),
  })
}
export function testHyperVLan(hostIp: string) {
  return api<HyperVLanTest>('/api/setup/hyperv-lan/test', {
    method: 'POST',
    body: JSON.stringify({ hostIp }),
  })
}
