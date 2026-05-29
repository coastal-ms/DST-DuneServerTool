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
}

export interface DuneAdminSetupResult {
  ok: boolean
  exePath?: string
  targetDir?: string
  didInstall?: boolean
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

export function runDuneAdminSetup() {
  return api<DuneAdminSetupResult>(`/api/dune-admin/setup`, { method: 'POST', body: '{}' })
}
