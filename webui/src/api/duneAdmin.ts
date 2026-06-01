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

export type DuneAdminDiagLevel = 'ok' | 'info' | 'warn' | 'error'

export interface DuneAdminFinding {
  level: DuneAdminDiagLevel
  message: string
  hint?: string | null
}

export interface DuneAdminDiagnostics {
  ok: boolean
  generatedAt: string
  verdict: 'ok' | 'warn' | 'error'
  machine?: string
  findings: DuneAdminFinding[]
  install: {
    exePath: string | null
    exeExists: boolean
    targetDir: string | null
    files: { name: string; present: boolean; size: number }[]
  }
  config: {
    configYamlPath: string
    exists: boolean
    listenAddr: string
    dbHost: string
    dbPort: string
    dbUser: string
    dbName: string
    dbSchema: string
    dbPassSet: boolean
    sshHost: string
    sshUser: string
    sshKey: string
    sshKeyExists: boolean
    control: string
    controlNamespace: string
    marketBotEnabled: string
    marketBotAddr: string
    marketBotContainer: string
    marketBotNamespace: string
    marketBotTokenSet: boolean
    marketBotCacheDb: string
  }
  effective: { listenAddr: string; port: number }
  envOverrides: { key: string; scope: string; value: string }[]
  sidecars: {
    name: string
    resolvedPath: string | null
    dotFolderPath: string
    dotFolderExists: boolean
    installPath: string | null
    installExists: boolean
    shadowsInstall: boolean
  }[]
  processes: {
    duneAdmin: { pid: number; path: string | null; startTime: string | null }[]
    count: number
    multipleInstances: boolean
  }
  listener: { port: number; listening: boolean }
  httpProbe: { url: string; ok: boolean; statusCode: number | null; error: string | null }
  marketBot: {
    cacheDbPath: string
    cacheDbExists: boolean
    cacheDbLocked: boolean
    addrConfigured: boolean
    containerConfigured: boolean
    running?: boolean
    status?: 'running' | 'configured' | 'not configured'
  }
  pricing: {
    status: 'idle' | 'running' | 'success' | 'failed'
    error?: string
    exitCode?: number
    targetTag?: string
    startedAt?: string
    finishedAt?: string
    logFile?: string
    logTail?: string
    autoApply: boolean
    goAvailable: boolean
    gitAvailable: boolean
  }
}

/** Runs a one-shot health report on the local dune-admin install: backend
 *  reachability, config.yaml/env precedence, sidecar shadowing, duplicate
 *  instances (market-bot DB lock), and pricing-patch state. Surfaces a list of
 *  findings so a user can self-diagnose "Failed to fetch" and paste the full
 *  report back for support. */
export function getDuneAdminDiagnostics() {
  return api<DuneAdminDiagnostics>(`/api/dune-admin/diagnostics`)
}

export interface DuneAdminDotFolder {
  path: string
  exists: boolean
}

/** Reports whether the per-user ~/.dune-admin config folder exists. A stale
 *  copy (left behind when the install location changes) makes the market bot
 *  fail. The install/setup preflight uses this to OFFER a cleanup. */
export function getDuneAdminDotFolder() {
  return api<DuneAdminDotFolder>(`/api/dune-admin/dotfolder`)
}

export interface DuneAdminDotFolderDeleteResult {
  ok: boolean
  deleted: boolean
  path: string
  message?: string
}

/** Deletes EXACTLY %USERPROFILE%\.dune-admin. Only call after the user has
 *  explicitly granted permission — the server never deletes on its own. */
export function deleteDuneAdminDotFolder() {
  return api<DuneAdminDotFolderDeleteResult>(`/api/dune-admin/dotfolder/delete`, { method: 'POST', body: '{}' })
}

export function runDuneAdminSetup() {
  return api<DuneAdminSetupResult>(`/api/dune-admin/setup`, { method: 'POST', body: '{}' })
}

export interface DuneAdminWebUrl {
  configured: boolean
  port: number
  listenAddr: string
  url: string
  listening: boolean
}

/** Resolves dune-admin's effective web URL from its config.yaml listen_addr.
 *  The port is per-user (default 8080, but :18080 for AMP installs or any
 *  custom value chosen at setup), so the UI must NEVER hardcode 8080 — it asks
 *  the backend, which reads the real listen_addr. */
export function getDuneAdminWebUrl() {
  return api<DuneAdminWebUrl>(`/api/dune-admin/web-url`)
}
