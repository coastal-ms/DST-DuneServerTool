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
  /** Update channel this check resolved against: 'stable' (default) or 'test'. */
  channel?: 'stable' | 'test'
  /** True when the resolved release is a GitHub pre-release (test channel). */
  isPrerelease?: boolean
  /** The exact tag the updater resolved to act on (stable latest or pinned pre-release). */
  selectedTag?: string
}

/** One test-channel candidate build for the Settings pre-release picker. */
export interface PreReleaseInfo {
  tag: string
  name?: string
  version: string
  publishedAt?: string
  releaseUrl?: string
  assetSize?: number
  hasAsset: boolean
}

export interface PreReleaseList {
  channel: 'stable' | 'test'
  /** Currently pinned tag; empty string means "latest" (the first item). */
  selectedTag: string
  count: number
  releases: PreReleaseInfo[]
  checkedAt?: string
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
 * List test-channel candidate builds (published pre-releases that carry the
 * installer asset, newest-first) for the Settings pre-release picker.
 */
export function listPreReleases(opts: { force?: boolean } = {}) {
  const qs = opts.force ? '?force=1' : ''
  return api<PreReleaseList>(`/api/update/prereleases${qs}`)
}

/**
 * Persist the update channel + pinned pre-release tag via the generic config
 * endpoint. Sends only the two keys; the backend merges them into the existing
 * config without disturbing other settings. Pass an empty `preReleaseTag` to
 * mean "latest".
 */
export function setUpdateChannel(channel: 'stable' | 'test', preReleaseTag = '') {
  return api<{ ok: boolean; values: Record<string, string> }>(`/api/config`, {
    method: 'PUT',
    body: JSON.stringify({
      values: { UpdateChannel: channel, UpdatePreReleaseTag: preReleaseTag },
    }),
  })
}

/** Persist just the pinned pre-release tag (test channel). Empty = latest. */
export function setPreReleaseTag(preReleaseTag: string) {
  return api<{ ok: boolean; values: Record<string, string> }>(`/api/config`, {
    method: 'PUT',
    body: JSON.stringify({ values: { UpdatePreReleaseTag: preReleaseTag } }),
  })
}

/**
 * One-time "DST is now decoupled from the reference implementation" notice. `needed` is true only
 * for installs upgraded from a pre-decouple build (<= 11.4.13) that haven't
 * acknowledged yet. `duneAdminFolder` is recovered from the legacy
 * `DuneAdminExe` config value so the user can still launch the reference implementation manually.
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
