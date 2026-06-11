// Gameplay API — native Market / Exchange + Market Bot, ported from dune-admin.
// All market responses carry a `source: 'live' | 'demo'` flag so the UI can
// label whether data came from the live game DB or the bundled demo dataset.
import { api } from './client'

export type DataSource = 'live' | 'demo'

export interface GameplayStatus {
  db_available: boolean
  db_message: string
  bot_configured: boolean
  bot_reachable: boolean
  source: DataSource
}

export interface MarketItem {
  template_id: string
  quality: number
  display_name: string
  category: string
  tier: number
  rarity: string
  lowest_price: number
  total_stock: number
  bot_stock: number
  listing_count: number
  icon: string
}

export interface MarketItemsResponse {
  items: MarketItem[]
  total: number
  page: number
  limit: number
  source: DataSource
  liveError?: string
}

export interface MarketListing {
  order_id: string
  template_id: string
  owner_type: 'bot' | 'player'
  owner_name: string
  price: number
  stock: number
  quality: number
}

export interface MarketListingsResponse {
  listings: MarketListing[]
  source: DataSource
  liveError?: string
}

export interface MarketSale {
  order_id: string
  template_id: string
  seller_type: 'bot' | 'player'
  seller_name: string
  price: number
  quantity: number
}

export interface MarketSalesResponse {
  sales: MarketSale[]
  source: DataSource
  liveError?: string
}

export interface MarketStats {
  total_listings: number
  bot_listings: number
  player_listings: number
  total_stock: number
  bot_stock: number
  player_stock: number
  unique_items: number
}

export interface MarketStatsResponse {
  stats: MarketStats
  source: DataSource
  liveError?: string
}

export interface BotStatus {
  configured?: boolean
  running: boolean
  enabled?: boolean
  die_size?: number
  die_target?: number
  last_buy_tick?: string
  listing_count?: number
  balance?: number
  provisioned?: boolean
  error_count?: number
  error?: string
  source?: DataSource
  db_message?: string
}

export interface BotConfig {
  enabled: boolean
  buy_tick_interval: number
  max_buys_per_tick: number
  die_size: number
  die_target: number
  target_balance: number
  maintain_balance: boolean
  disabled_items: string[]
  configured?: boolean
  source?: DataSource
}

export interface BotTickWinner {
  template_id: string
  order_id: string
  price: number
  stack: number
  roll: number
}

export interface BotTickResult {
  ok: boolean
  dryRun: boolean
  enabled: boolean
  candidates: number
  rolled: number
  won: number
  purchased: number
  skipped: number
  errors: number
  die: string
  winners: BotTickWinner[]
  message: string
}

export interface BotBalance {
  ok: boolean
  provisioned: boolean
  balance: number | null
  owner_id?: number
  message?: string
}

export interface CatalogEntry {
  template_id: string
  display_name: string
}

function qs(params: Record<string, string | number | undefined>): string {
  const parts: string[] = []
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined && v !== '' && v !== null) {
      parts.push(`${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`)
    }
  }
  return parts.length ? `?${parts.join('&')}` : ''
}

export function getGameplayStatus() {
  return api<GameplayStatus>('/api/gameplay/status')
}

export type MarketSortKey =
  | 'display_name' | 'category' | 'tier' | 'rarity'
  | 'lowest_price' | 'total_stock' | 'listing_count'

export interface MarketItemsQuery {
  search?: string
  category?: string
  tier?: string
  rarity?: string
  owner?: string
  sort?: MarketSortKey
  dir?: 'asc' | 'desc'
  page?: number
  limit?: number
  demo?: boolean
}

export function getMarketItems(q: MarketItemsQuery = {}) {
  return api<MarketItemsResponse>(`/api/gameplay/market/items${qs({
    search: q.search, category: q.category, tier: q.tier, rarity: q.rarity,
    owner: q.owner, sort: q.sort, dir: q.dir,
    page: q.page, limit: q.limit, demo: q.demo ? 1 : undefined,
  })}`)
}

export function getMarketListings(templateId?: string, owner?: string, demo?: boolean) {
  return api<MarketListingsResponse>(`/api/gameplay/market/listings${qs({
    template_id: templateId, owner, demo: demo ? 1 : undefined,
  })}`)
}

export function getMarketSales(demo?: boolean) {
  return api<MarketSalesResponse>(`/api/gameplay/market/sales${qs({ demo: demo ? 1 : undefined })}`)
}

export function getMarketStats(demo?: boolean) {
  return api<MarketStatsResponse>(`/api/gameplay/market/stats${qs({ demo: demo ? 1 : undefined })}`)
}

export function getMarketCategories() {
  return api<{ categories: string[] }>('/api/gameplay/market/categories')
}

export function getMarketCatalog() {
  return api<{ items: CatalogEntry[] }>('/api/gameplay/market/catalog')
}

export function getBotStatus(demo?: boolean) {
  return api<BotStatus>(`/api/gameplay/market-bot/status${qs({ demo: demo ? 1 : undefined })}`)
}

export function getBotConfig(demo?: boolean) {
  return api<BotConfig>(`/api/gameplay/market-bot/config${qs({ demo: demo ? 1 : undefined })}`)
}

export function saveBotConfig(cfg: Partial<BotConfig>) {
  return api<BotConfig>('/api/gameplay/market-bot/config', {
    method: 'PUT',
    body: JSON.stringify(cfg),
  })
}

export function runBotTick(dryRun: boolean) {
  return api<BotTickResult>(`/api/gameplay/market-bot/tick${dryRun ? '?dry=1' : ''}`, {
    method: 'POST',
    body: JSON.stringify({ dryRun }),
  })
}

export function botExec(action: 'start' | 'stop' | 'restart') {
  return api<{ ok: boolean; action: string; enabled: boolean }>('/api/gameplay/market-bot/exec', {
    method: 'POST',
    body: JSON.stringify({ action }),
  })
}

export function getBotBalance() {
  return api<BotBalance>('/api/gameplay/market-bot/balance')
}

export function setBotBalance(targetBalance: number) {
  return api<{ ok: boolean; before: number; after: number; delta: number }>(
    '/api/gameplay/market-bot/balance',
    { method: 'POST', body: JSON.stringify({ target_balance: targetBalance }) },
  )
}

export function clearBotListings() {
  return api<{ ok: boolean; cleared: number; message?: string }>(
    '/api/gameplay/market-bot/clear-listings',
    { method: 'POST' },
  )
}

// ---------------------------------------------------------------------------
// Players
// ---------------------------------------------------------------------------
export interface Player {
  id: number            // pawn actor id (inventory / spec writes)
  account_id: number    // rename, tags
  controller_id: number // currency writes
  name: string
  class: string
  map: string
  faction_id: number
  faction_name: string
  online_status: string
}

export interface PlayersResponse {
  players: Player[]
  total: number
  source: DataSource
  liveError?: string
}

export interface InventoryItem {
  id: number
  template_id: string
  name: string
  kind?: 'item' | 'emote' | 'contract'
  stack_size: number
  quality: number
  durability: string
  max_durability: string
}

export interface SpecTrack {
  track_type: string
  xp: number
  level: number
}

export interface CurrencyBalance {
  currency_id: number
  balance: number
}

export interface PlayerDetailResponse {
  inventory: InventoryItem[]
  specs: SpecTrack[]
  currency: CurrencyBalance[]
  source: DataSource
  liveError?: string
}

export interface WriteResult {
  ok: boolean
  message: string
  result?: Record<string, unknown>
}

export function getPlayers(demo?: boolean) {
  return api<PlayersResponse>(`/api/gameplay/players${qs({ demo: demo ? 1 : undefined })}`)
}

export function getPlayerDetail(pawnId: number, controllerId: number, demo?: boolean) {
  return api<PlayerDetailResponse>(`/api/gameplay/players/detail${qs({
    pawn: pawnId, controller: controllerId, demo: demo ? 1 : undefined,
  })}`)
}

export function giveSolari(controllerId: number, amount: number) {
  return api<WriteResult>('/api/gameplay/players/give-solari', {
    method: 'POST', body: JSON.stringify({ controller_id: controllerId, amount }),
  })
}

export function giveItem(pawnId: number, template: string, qty: number, quality: number) {
  return api<WriteResult>('/api/gameplay/players/give-item', {
    method: 'POST', body: JSON.stringify({ pawn_id: pawnId, template, qty, quality }),
  })
}

export function renamePlayer(accountId: number, name: string) {
  return api<WriteResult>('/api/gameplay/players/rename', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, name }),
  })
}

export function awardSpecXp(pawnId: number, trackType: string, delta: number) {
  return api<WriteResult>('/api/gameplay/players/award-xp', {
    method: 'POST', body: JSON.stringify({ pawn_id: pawnId, track_type: trackType, delta }),
  })
}

export function deleteInventoryItem(itemId: number) {
  return api<WriteResult>('/api/gameplay/players/delete-item', {
    method: 'POST', body: JSON.stringify({ item_id: itemId }),
  })
}

export function repairInventoryItem(itemId: number) {
  return api<WriteResult>('/api/gameplay/players/repair-item', {
    method: 'POST', body: JSON.stringify({ item_id: itemId }),
  })
}

// ---------------------------------------------------------------------------
// Bases / Storage / Blueprints (read-only)
// ---------------------------------------------------------------------------
export interface BaseRow {
  id: number
  name: string
  pieces: number
  placeables: number
}

export interface BasesResponse {
  bases: BaseRow[]
  total: number
  source: DataSource
  liveError?: string
}

export interface StorageContainer {
  id: number
  name: string
  class: string
  raw_class: string
  map: string
  item_count: number
  item_templates: string[]
  item_names: string[]
  owner_name: string
}

export interface StorageResponse {
  containers: StorageContainer[]
  total: number
  source: DataSource
  liveError?: string
}

export interface StorageItemsResponse {
  items: InventoryItem[]
  source: DataSource
  liveError?: string
}

export interface BlueprintRow {
  id: number
  owner_name: string
  item_id: number
  pieces: number
  placeables: number
  name: string
}

export interface BlueprintsResponse {
  blueprints: BlueprintRow[]
  total: number
  source: DataSource
  liveError?: string
}

export function getBases(demo?: boolean) {
  return api<BasesResponse>(`/api/gameplay/bases${qs({ demo: demo ? 1 : undefined })}`)
}

export function getStorage(demo?: boolean) {
  return api<StorageResponse>(`/api/gameplay/storage${qs({ demo: demo ? 1 : undefined })}`)
}

export function getStorageItems(containerId: number, demo?: boolean) {
  return api<StorageItemsResponse>(`/api/gameplay/storage/items${qs({
    id: containerId, demo: demo ? 1 : undefined,
  })}`)
}

export function getBlueprints(demo?: boolean) {
  return api<BlueprintsResponse>(`/api/gameplay/blueprints${qs({ demo: demo ? 1 : undefined })}`)
}

// ---------------------------------------------------------------------------
// Blueprint / Base export + import, Storage write actions
// ---------------------------------------------------------------------------
export interface BlueprintInstance {
  building_type: string
  x: number
  y: number
  z: number
  rotation: number
  instance_id?: number
  provides_stability?: boolean
}

export interface BlueprintPlaceable {
  building_type: string
  x: number
  y: number
  z: number
  rx: number
  ry: number
  rz: number
  placeable_id?: number
}

export interface BlueprintPentashield {
  placeable_id: number
  scale: number[]
}

export interface BlueprintFile {
  name: string
  instances: BlueprintInstance[]
  placeables: BlueprintPlaceable[]
  pentashields: BlueprintPentashield[]
}

export interface ExportResponse {
  blueprint: BlueprintFile
  filename: string
  source: DataSource
  liveError?: string
}

export function exportBlueprint(id: number, demo?: boolean) {
  return api<ExportResponse>(`/api/gameplay/blueprints/export${qs({ id, demo: demo ? 1 : undefined })}`)
}

export function importBlueprint(playerId: number, blueprint: BlueprintFile) {
  return api<WriteResult>('/api/gameplay/blueprints/import', {
    method: 'POST', body: JSON.stringify({ player_id: playerId, blueprint }),
  })
}

export function exportBase(id: number, demo?: boolean) {
  return api<ExportResponse>(`/api/gameplay/bases/export${qs({ id, demo: demo ? 1 : undefined })}`)
}

export interface StorageGiveItemInput {
  template: string
  qty: number
  quality: number
}

export function giveItemToStorage(containerId: number, template: string, qty: number, quality: number) {
  return api<WriteResult>('/api/gameplay/storage/give-item', {
    method: 'POST', body: JSON.stringify({ container_id: containerId, template, qty, quality }),
  })
}

export function giveItemsToStorage(containerId: number, items: StorageGiveItemInput[]) {
  return api<WriteResult>('/api/gameplay/storage/give-items', {
    method: 'POST', body: JSON.stringify({ container_id: containerId, items }),
  })
}

export function deleteStorageItem(itemId: number) {
  return api<WriteResult>('/api/gameplay/storage/delete-item', {
    method: 'POST', body: JSON.stringify({ item_id: itemId }),
  })
}

// Trigger a client-side download of an exported blueprint/base JSON file.
export function downloadBlueprintFile(blueprint: BlueprintFile, filename: string) {
  const blob = new Blob([JSON.stringify(blueprint, null, 2)], { type: 'application/json' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename || 'blueprint.json'
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
}
