// Update API — GitHub-release-driven in-app auto-updater.
import { api } from './client'

export interface UpdateCheck {
  available: boolean
  /**
   * True when `available` AND the release has an installer .exe asset that
   * the in-app auto-updater can download and run. False when a newer release
   * exists but no asset is attached — UI should still show "update available"
   * but link to the release page instead of offering an Install button.
   *
   * Optional for backward compatibility with older backends that didn't
   * split this from `available`.
   */
  installable?: boolean
  /** True when `available` but no installer asset is present. Diagnostic. */
  assetMissing?: boolean
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
