// Update API — GitHub-release-driven in-app auto-updater.
import { api } from './client'

export interface UpdateCheck {
  available: boolean
  currentVersion: string
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
}

export interface UpdateInstallResult {
  launched: boolean
  reason?: string
  installerPath?: string
  fromVersion?: string
  toVersion?: string
  note?: string
}

export function checkForUpdate(opts: { force?: boolean } = {}) {
  const qs = opts.force ? '?force=1' : ''
  return api<UpdateCheck>(`/api/update/check${qs}`)
}

export function installUpdate() {
  return api<UpdateInstallResult>(`/api/update/install`, { method: 'POST', body: '{}' })
}
