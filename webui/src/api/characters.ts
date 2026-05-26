// Characters API — typed wrappers around /api/characters/* and /api/catalog/*
import { api } from './client'
import type {
  CharactersListResponse,
  CharacterDetail,
  CharacterDefs,
  ItemCatalog,
} from './types'

export function listCharacters() {
  return api<CharactersListResponse>('/api/characters')
}

export function getCharacter(id: number) {
  return api<CharacterDetail>(`/api/characters/${id}`)
}

export function saveStats(id: number, values: Record<string, number>) {
  return api<{ ok: boolean; updated: number }>(`/api/characters/${id}/stats`, {
    method: 'PUT',
    body: JSON.stringify({ values }),
  })
}

export function techUnlockAll(id: number) {
  return api<{ ok: boolean }>(`/api/characters/${id}/tech/unlock-all`, { method: 'POST' })
}
export function techLockAll(id: number) {
  return api<{ ok: boolean }>(`/api/characters/${id}/tech/lock-all`, { method: 'POST' })
}

export function saveSpec(id: number, track: string, xp: number, level: number) {
  return api<{ ok: boolean }>(`/api/characters/${id}/specs/${encodeURIComponent(track)}`, {
    method: 'PUT',
    body: JSON.stringify({ xp, level }),
  })
}

export function unlockKeystones(id: number, prefix: string) {
  return api<{ ok: boolean }>(`/api/characters/${id}/specs/${encodeURIComponent(prefix)}/unlock-keystones`, {
    method: 'POST',
  })
}

export function saveCurrency(id: number, currencyId: number, balance: number) {
  return api<{ ok: boolean }>(`/api/characters/${id}/currency/${currencyId}`, {
    method: 'PUT',
    body: JSON.stringify({ balance }),
  })
}

export function saveFactionRep(id: number, factionId: number, amount: number) {
  return api<{ ok: boolean }>(`/api/characters/${id}/faction/${factionId}`, {
    method: 'PUT',
    body: JSON.stringify({ amount }),
  })
}

export function addCosmetic(id: number, cosmeticId: string) {
  return api<{ ok: boolean }>(`/api/characters/${id}/cosmetics`, {
    method: 'POST',
    body: JSON.stringify({ cosmeticId }),
  })
}

export function removeCosmetic(id: number, cosmeticId: string) {
  return api<{ ok: boolean }>(`/api/characters/${id}/cosmetics/${encodeURIComponent(cosmeticId)}`, {
    method: 'DELETE',
  })
}

export function addInventoryItem(
  inventoryId: number,
  templateId: string,
  stackSize: number,
  isEquipment: boolean,
) {
  return api<{ ok: boolean }>(`/api/inventories/${inventoryId}/items`, {
    method: 'POST',
    body: JSON.stringify({ templateId, stackSize, isEquipment }),
  })
}

export function removeItem(itemId: number) {
  return api<{ ok: boolean }>(`/api/items/${itemId}`, { method: 'DELETE' })
}

export function getCharacterDefs() {
  return api<CharacterDefs>('/api/catalog/character-defs')
}

export function getItemCatalog() {
  return api<ItemCatalog>('/api/catalog/items')
}
