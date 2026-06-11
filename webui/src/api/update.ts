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

/**
 * One-time "DST is now decoupled from Dune-Admin" notice. `needed` is true only
 * for installs upgraded from a pre-decouple build (<= 11.4.13) that haven't
 * acknowledged yet. `duneAdminFolder` is recovered from the legacy
 * `DuneAdminExe` config value so the user can still launch dune-admin manually.
 */
export interface MigrationNotice {
  needed: boolean
  acknowledged: boolean
  fromLegacy: boolean
  duneAdminExe?: string
  duneAdminFolder?: string
  portalUrl: string
  currentVersion?: string
  checkedAt?: string
}

export function getMigrationNotice() {
  return api<MigrationNotice>(`/api/update/migration-notice`)
}

export function ackMigrationNotice() {
  return api<{ ok: boolean; acknowledged: boolean; ackVersion?: string }>(
    `/api/update/migration-notice/ack`,
    { method: 'POST', body: '{}' },
  )
}
