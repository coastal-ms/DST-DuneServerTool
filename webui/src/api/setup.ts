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
// user/password test a NEW credential without saving it (the Connect step,
// before anything is saved). Omit both to test using the already-saved
// credential for hostIp instead.
export function testHyperVLan(hostIp: string, user?: string, password?: string) {
  return api<HyperVLanTest>('/api/setup/hyperv-lan/test', {
    method: 'POST',
    body: JSON.stringify({ hostIp, user, password }),
  })
}

// The saved Hyper-V LAN host credential — never carries the password. Lets the
// UI show "using saved credential for <user>" instead of re-prompting.
export interface HyperVLanCredentialInfo {
  ok: boolean
  exists: boolean
  matchesHost: boolean
  user: string
  savedHostIp: string
  error: string | null
}
export function getHyperVLanCredential(hostIp?: string) {
  const q = hostIp ? `?hostIp=${encodeURIComponent(hostIp)}` : ''
  return api<HyperVLanCredentialInfo>(`/api/setup/hyperv-lan/credential${q}`)
}
export function saveHyperVLanCredential(hostIp: string, user: string, password: string) {
  return api<{ ok: boolean }>('/api/setup/hyperv-lan/credential', {
    method: 'POST',
    body: JSON.stringify({ hostIp, user, password }),
  })
}
export function deleteHyperVLanCredential() {
  return api<{ ok: boolean }>('/api/setup/hyperv-lan/credential', { method: 'DELETE' })
}

// Remote install (VM lives on a headless Hyper-V host). user/password are
// optional — omit them to use the saved Hyper-V LAN credential for hostIp
// (set in the Connect step) instead of re-entering it; an explicit value here
// is used only for this call and is never persisted by this route.
export interface HyperVLanDrive { drive: string; freeGB: number }
export interface HyperVLanHostResources {
  ok: boolean
  error?: string
  drives?: HyperVLanDrive[]
  allDrives?: HyperVLanDrive[]
  switches?: string[]
  vmExists?: boolean
  hostRamGB?: number
}
export interface HyperVLanInstallStep { id: string; label: string; status: string; detail: string }
export interface HyperVLanInstallStatus {
  running: boolean
  phase: string
  steps: HyperVLanInstallStep[]
  ip: string
  error: string
}
export interface HyperVLanInstallRequest {
  hostIp: string
  user?: string
  password?: string
  destDrive: string
  memoryGB: number
  switchName: string
  vmPassword: string
  replaceExisting: boolean
}

export function getHyperVLanHostResources(hostIp: string, user?: string, password?: string) {
  return api<HyperVLanHostResources>('/api/setup/hyperv-lan/host-resources', {
    method: 'POST',
    body: JSON.stringify({ hostIp, user, password }),
  })
}
export function startHyperVLanInstall(req: HyperVLanInstallRequest) {
  return api<{ ok: boolean; running: boolean; error?: string }>('/api/setup/hyperv-lan/install', {
    method: 'POST',
    body: JSON.stringify(req),
  })
}
export function getHyperVLanInstallStatus() {
  return api<HyperVLanInstallStatus>('/api/setup/hyperv-lan/install/status')
}
