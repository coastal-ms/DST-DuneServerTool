// GameConfig API — typed wrappers around /api/gameconfig/*
import { api } from './client'
import type {
  GameConfigSchemaResponse,
  GameConfigResponse,
  GameConfigSaveResponse,
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
