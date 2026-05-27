// Characters API — typed wrappers around /api/characters/* and /api/catalog/*
import { api, withOnlinePlayerGuard } from './client'
import type {
  CharactersListResponse,
  CharacterDetail,
  CharacterDefs,
  ItemCatalog,
} from './types'

// `?force=true` bypasses the server's players-online guard. The withOnlinePlayerGuard
// wrapper sets force=true automatically when the user confirms the prompt.
const fq = (force: boolean) => (force ? '?force=true' : '')

export function listCharacters() {
  return api<CharactersListResponse>('/api/characters')
}

export function getCharacter(id: number) {
  return api<CharacterDetail>(`/api/characters/${id}`)
}

export function saveStats(id: number, values: Record<string, number>) {
  return withOnlinePlayerGuard(force =>
    api<{ ok: boolean; updated: number }>(`/api/characters/${id}/stats${fq(force)}`, {
      method: 'PUT',
      body: JSON.stringify({ values }),
    }),
  )
}

export function techUnlockAll(id: number) {
  return withOnlinePlayerGuard(force =>
    api<{ ok: boolean }>(`/api/characters/${id}/tech/unlock-all${fq(force)}`, { method: 'POST' }),
  )
}
export function techLockAll(id: number) {
  return withOnlinePlayerGuard(force =>
    api<{ ok: boolean }>(`/api/characters/${id}/tech/lock-all${fq(force)}`, { method: 'POST' }),
  )
}

export function saveSpec(id: number, track: string, xp: number, level: number) {
  return withOnlinePlayerGuard(force =>
    api<{ ok: boolean }>(`/api/characters/${id}/specs/${encodeURIComponent(track)}${fq(force)}`, {
      method: 'PUT',
      body: JSON.stringify({ xp, level }),
    }),
  )
}

export function unlockKeystones(id: number, prefix: string) {
  return withOnlinePlayerGuard(force =>
    api<{ ok: boolean }>(
      `/api/characters/${id}/specs/${encodeURIComponent(prefix)}/unlock-keystones${fq(force)}`,
      { method: 'POST' },
    ),
  )
}

export function saveCurrency(id: number, currencyId: number, balance: number) {
  return withOnlinePlayerGuard(force =>
    api<{ ok: boolean }>(`/api/characters/${id}/currency/${currencyId}${fq(force)}`, {
      method: 'PUT',
      body: JSON.stringify({ balance }),
    }),
  )
}

export function saveFactionRep(id: number, factionId: number, amount: number) {
  return withOnlinePlayerGuard(force =>
    api<{ ok: boolean }>(`/api/characters/${id}/faction/${factionId}${fq(force)}`, {
      method: 'PUT',
      body: JSON.stringify({ amount }),
    }),
  )
}

export function addCosmetic(id: number, cosmeticId: string) {
  return withOnlinePlayerGuard(force =>
    api<{ ok: boolean }>(`/api/characters/${id}/cosmetics${fq(force)}`, {
      method: 'POST',
      body: JSON.stringify({ cosmeticId }),
    }),
  )
}

export function removeCosmetic(id: number, cosmeticId: string) {
  return withOnlinePlayerGuard(force =>
    api<{ ok: boolean }>(
      `/api/characters/${id}/cosmetics/${encodeURIComponent(cosmeticId)}${fq(force)}`,
      { method: 'DELETE' },
    ),
  )
}

export function addInventoryItem(
  inventoryId: number,
  templateId: string,
  stackSize: number,
  isEquipment: boolean,
) {
  return withOnlinePlayerGuard(force =>
    api<{ ok: boolean }>(`/api/inventories/${inventoryId}/items${fq(force)}`, {
      method: 'POST',
      body: JSON.stringify({ templateId, stackSize, isEquipment }),
    }),
  )
}

export function removeItem(itemId: number) {
  return withOnlinePlayerGuard(force =>
    api<{ ok: boolean }>(`/api/items/${itemId}${fq(force)}`, { method: 'DELETE' }),
  )
}

export function getCharacterDefs() {
  return api<CharacterDefs>('/api/catalog/character-defs')
}

export function getItemCatalog() {
  return api<ItemCatalog>('/api/catalog/items')
}
