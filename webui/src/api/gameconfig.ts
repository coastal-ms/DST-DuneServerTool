// GameConfig API — typed wrappers around /api/gameconfig/*
import { api, withOnlinePlayerGuard } from './client'
import type {
  GameConfigSchemaResponse,
  GameConfigResponse,
  GameConfigSaveResponse,
  GameConfigBackupResponse,
  GameConfigBackupListResponse,
  GameConfigClientInfo,
  GameConfigClientApplyResult,
  GameConfigClientApplyItem,
  GameConfigDefaultsResponse,
  GameConfigRawUpdate,
  SpicefieldsResponse,
  SpicefieldSaveResponse,
  SpicefieldType,
} from './types'

const fq = (force: boolean) => (force ? '?force=true' : '')

export function getGameConfigSchema() {
  return api<GameConfigSchemaResponse>('/api/gameconfig/schema')
}

export function getGameConfig() {
  return api<GameConfigResponse>('/api/gameconfig')
}

export function saveGameConfig(updates: Record<string, string>) {
  return withOnlinePlayerGuard(force =>
    api<GameConfigSaveResponse>(`/api/gameconfig${fq(force)}`, {
      method: 'PUT',
      body: JSON.stringify({ updates }),
    }),
  )
}

// Defaults catalog — full DefaultGame.ini / DefaultEngine.ini from the live
// pod, merged with current overrides. Pass refresh=true to re-read the pod.
export function getGameConfigDefaults(refresh = false) {
  return api<GameConfigDefaultsResponse>(
    `/api/gameconfig/defaults${refresh ? '?refresh=1' : ''}`,
  )
}

// Save arbitrary (file, section, key, value) tuples — used by the defaults
// browser so keys outside the curated schema can still be persisted via the
// existing explicit-array form of PUT /api/gameconfig.
export function saveGameConfigRaw(updates: GameConfigRawUpdate[]) {
  return withOnlinePlayerGuard(force =>
    api<GameConfigSaveResponse>(`/api/gameconfig${fq(force)}`, {
      method: 'PUT',
      body: JSON.stringify({ updates }),
    }),
  )
}

export function backupGameConfig() {
  return api<GameConfigBackupResponse>('/api/gameconfig/backup', { method: 'POST' })
}

export function listGameConfigBackups() {
  return api<GameConfigBackupListResponse>('/api/gameconfig/backups')
}

// --- Local client config (admin's own machine) -----------------------------

export function getGameConfigClient() {
  return api<GameConfigClientInfo>('/api/gameconfig/client')
}

export function setGameConfigClientDir(dir: string) {
  return api<GameConfigClientInfo>('/api/gameconfig/client/dir', {
    method: 'PUT',
    body: JSON.stringify({ dir }),
  })
}

export function applyGameConfigClient(items: GameConfigClientApplyItem[], dir?: string) {
  return api<GameConfigClientApplyResult>('/api/gameconfig/client/apply', {
    method: 'PUT',
    body: JSON.stringify({
      updates: items.map(i => ({ key: i.key, value: i.value })),
      ...(dir ? { dir } : {}),
    }),
  })
}

export function openGameConfigClientFile(dir?: string) {
  return api<{ ok: boolean; path: string }>('/api/gameconfig/client/open', {
    method: 'POST',
    body: JSON.stringify(dir ? { dir } : {}),
  })
}

export function getSpicefields() {
  return api<SpicefieldsResponse>('/api/gameconfig/spicefields')
}

export function saveSpicefield(
  id: number,
  payload: Pick<SpicefieldType, 'maxActive' | 'maxPrimed' | 'isSpawningActive' | 'spawnWeight'>,
) {
  return withOnlinePlayerGuard(force =>
    api<SpicefieldSaveResponse>(`/api/gameconfig/spicefields/${id}${fq(force)}`, {
      method: 'PUT',
      body: JSON.stringify(payload),
    }),
  )
}

// Live toggle for is_spawning_active ONLY. Hits the dedicated guard-railed
// endpoint that never touches any other column and never writes NULL.
export function setSpicefieldSpawning(id: number, active: boolean) {
  return withOnlinePlayerGuard(force =>
    api<SpicefieldSaveResponse>(`/api/gameconfig/spicefields/${id}/spawning${fq(force)}`, {
      method: 'PUT',
      body: JSON.stringify({ active: active === true }),
    }),
  )
}
