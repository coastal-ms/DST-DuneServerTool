// GameConfig API — typed wrappers around /api/gameconfig/*
import { api } from './client'
import type {
  GameConfigSchemaResponse,
  GameConfigResponse,
  GameConfigSaveResponse,
  SpicefieldsResponse,
  SpicefieldSaveResponse,
  SpicefieldType,
} from './types'

export function getGameConfigSchema() {
  return api<GameConfigSchemaResponse>('/api/gameconfig/schema')
}

export function getGameConfig() {
  return api<GameConfigResponse>('/api/gameconfig')
}

export function saveGameConfig(updates: Record<string, string>) {
  return api<GameConfigSaveResponse>('/api/gameconfig', {
    method: 'PUT',
    body: JSON.stringify({ updates }),
  })
}

export function getSpicefields() {
  return api<SpicefieldsResponse>('/api/gameconfig/spicefields')
}

export function saveSpicefield(
  id: number,
  payload: Pick<SpicefieldType, 'maxActive' | 'maxPrimed' | 'isSpawningActive' | 'spawnWeight'>,
) {
  return api<SpicefieldSaveResponse>(`/api/gameconfig/spicefields/${id}`, {
    method: 'PUT',
    body: JSON.stringify(payload),
  })
}
