// dune-admin updater API - mirrors update.ts but targets the third-party
// Icehunter/dune-admin companion tool and replaces dune-admin.exe at the
// DuneAdminExe path configured in Settings.
import { api } from './client'

export interface DuneAdminInstalledInfo {
  path: string
  exists: boolean
  version: string | null
  versionSource: 'sidecar' | 'fileinfo' | 'unknown' | null
  fileSize: number
  lastWriteTime: string | null
}

export interface DuneAdminCheck {
  configured: boolean
  exePath: string
  installed: DuneAdminInstalledInfo
  available: boolean
  latestVersion?: string
  tagName?: string
  releaseName?: string
  releaseUrl?: string
  releaseNotes?: string
  publishedAt?: string
  assetName?: string
  assetSize?: number
  checkedAt: string
  error?: string
  configYamlPath?: string
  configYamlExists?: boolean
}

export interface DuneAdminPricingPatchStatus {
  ok: boolean
  status: 'idle' | 'running' | 'success' | 'failed'
  statusFile?: string
  targetTag?: string
  targetDir?: string
  logFile?: string
  startedAt?: string
  finishedAt?: string
  exitCode?: number
  error?: string
  pid?: number
  logTail?: string
}

export interface DuneAdminSshKeyCopyResult {
  ok: boolean
  skipped?: boolean
  source?: string | null
  dest?: string | null
  message?: string | null
}

export interface DuneAdminInstallResult {
  ok: boolean
  fromVersion?: string | null
  toVersion?: string
  tagName?: string
  assetName?: string
  assetSize?: number
  targetDir?: string
  copied?: string[]
  note?: string
  /**
   * Result of copying the user's SSH key (from dune-server.config or
   * %LOCALAPPDATA%\DuneAwakeningServer\sshKey, whichever is newer) into
   * the dune-admin install folder. dune-admin's SSH/kubectl-over-SSH
   * layer reads `./sshKey` so this copy is what makes the binary
   * actually able to talk to the VM. Non-fatal: ok=false means
   * dune-admin will start but won't be able to authenticate until the
   * key is placed manually. (v6.1.31)
   */
  sshKeyCopy?: DuneAdminSshKeyCopyResult
  /**
   * Present when `AutoApplyPricingPatch=true` in dune-server.config. The
   * /install route launches the patched-build as a detached background
   * process and returns `pricingPatch.status='running'` immediately. The
   * UI should then poll `pricingPatchStatus()` every couple of seconds
   * until status is `'success'` or `'failed'`. See DuneAdmin.ps1
   * `Start-DuneAdminPricingRebuild` (v6.1.25).
   */
  pricingPatch?: DuneAdminPricingPatchStatus
  /**
   * PIDs of any running dune-admin instances the install route stopped before
   * overwriting dune-admin.exe. Handles the hidden-window / detached-process
   * case where the user can't close it manually. Empty when nothing was running.
   * (v6.3.2)
   */
  stoppedPids?: number[]
}

export interface DuneAdminSetupResult {
  ok: boolean
  exePath?: string
  targetDir?: string
  didInstall?: boolean
  /** See DuneAdminInstallResult.sshKeyCopy. (v6.1.31) */
  sshKeyCopy?: DuneAdminSshKeyCopyResult
  configYamlPath?: string
  configYamlExists?: boolean
  wizardScript?: string
  note?: string
}

export function checkDuneAdminUpdate(opts: { force?: boolean } = {}) {
  const qs = opts.force ? '?force=1' : ''
  return api<DuneAdminCheck>(`/api/dune-admin/check${qs}`)
}

export function installDuneAdminUpdate() {
  return api<DuneAdminInstallResult>(`/api/dune-admin/install`, { method: 'POST', body: '{}' })
}

export function pricingPatchStatus() {
  return api<DuneAdminPricingPatchStatus>(`/api/dune-admin/pricing-patch-status`)
}

export interface DuneAdminMarketBotHealth {
  checked: boolean
  configExists: boolean
  botEnabled: boolean | null
  dbHost: string | null
  dbPort: number | null
  reachable: boolean | null
  status: 'ok' | 'unreachable' | 'disabled' | 'no-config' | 'unknown'
  message: string | null
}

export function marketBotHealth() {
  return api<DuneAdminMarketBotHealth>(`/api/dune-admin/market-bot-health`)
}

export function runDuneAdminSetup() {
  return api<DuneAdminSetupResult>(`/api/dune-admin/setup`, { method: 'POST', body: '{}' })
}
