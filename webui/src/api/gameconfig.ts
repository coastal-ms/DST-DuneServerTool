// GameConfig API — typed wrappers around /api/gameconfig/*
import { api, withOnlinePlayerGuard } from './client'
import type {
  GameConfigSchemaResponse,
  GameConfigResponse,
  GameConfigSaveResponse,
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
