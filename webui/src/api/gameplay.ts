// Gameplay API — native Market / Exchange + Market Bot, ported from the reference implementation.
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

export interface BotStatusByClass {
  class: string
  count: number
}

export interface BotSeedProgress {
  phase?: 'starting' | 'reading-listings' | 'writing' | 'done' | 'error' | 'aborted' | string
  running?: boolean
  chunks_done?: number
  chunks_total?: number
  inserted?: number
  eligible?: number
  considered?: number
  masks_known?: number
  errors?: number
  listed_before?: number
  listed_after?: number
  message?: string
  started?: string
  updated?: string
  finished?: string
  last_chunk_ms?: number
}

export interface BotListTickProgress {
  phase?: 'starting' | 'done' | 'error' | string
  running?: boolean
  started?: string
  updated?: string
  finished?: string
  message?: string
}

export interface BotStatus {
  configured?: boolean
  running: boolean
  enabled?: boolean
  die_size?: number
  die_target?: number
  last_buy_tick?: string
  last_list_tick?: string
  listing_count?: number               // Duke's own NPC listings
  listings_npc_total?: number          // ALL NPC listings across actor classes
  listings_by_class?: BotStatusByClass[]
  legacy_listings_count?: number       // NPC listings owned by non-Duke actors
  balance?: number
  provisioned?: boolean
  error_count?: number
  error?: string
  seed_progress?: BotSeedProgress | null
  list_tick_progress?: BotListTickProgress | null
  source?: DataSource
  db_message?: string
}

export interface BotPricingConfig {
  price_cap: number
  price_floor: number
  default_unit_price: number
  tier_base_prices: Record<string, number>
  stack_unit_prices: Record<string, number>
  category_factors: Record<string, number>
  grade_multipliers: number[]
  rarity_multipliers: Record<string, number>
  vendor_multipliers: Record<string, number>
  price_overrides: Record<string, number>
  // Upstream Funcom-style pricing mode (default OFF). When upstream_pricing is
  // true the bot routes Get-DuneBotItemPrice through the pre-sane-pricing
  // formula: vendor_price * vendor_mult(rarity) (up to 5x for rare/unique) or
  // uncapped equipment / schematic / stack tier tables * rarity_mult, then
  // graded. No 100k Solari cap.
  upstream_pricing: boolean
  upstream_tier_equipment_prices: Record<string, number>
  upstream_tier_schematic_prices: Record<string, number>
  upstream_stack_unit_prices: Record<string, number>
  upstream_rarity_multipliers: Record<string, number>
  upstream_vendor_multipliers: Record<string, number>
  upstream_grade_multipliers: number[]
}

export interface BotConfig extends Partial<BotPricingConfig> {
  enabled: boolean
  buy_tick_interval: number
  max_buys_per_tick: number
  die_size: number
  die_target: number
  target_balance: number
  maintain_balance: boolean
  disabled_items: string[]
  // Listing side (sane-pricing port, v11.5.2+).
  list_tick_interval: number
  listings_per_grade: number
  stackables_only: boolean
  display_cap_enabled?: boolean
  display_cap_solari?: number
  sane_defaults_revision?: number
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

export interface BotListTickPlan {
  template_id: string
  target_price: number
  stack_max: number
  existing: number
  aligned: number
  stale: number
  to_insert: number
  tier: number
  rarity: string
  stackable: boolean
}

export interface BotListTickResult {
  ok: boolean
  dryRun: boolean
  enabled: boolean
  considered: number
  eligible: number
  listed_before: number
  listed_after: number
  inserted: number
  deleted: number
  errors: number
  planned: BotListTickPlan[]
  message: string
}

export interface BotSeedPlan {
  template_id: string
  target_price: number
  stack_max: number
  existing: number
  aligned: number
  to_insert: number
  tier: number
  rarity: string
  stackable: boolean
  source: string
}

export interface BotSeedResult {
  ok: boolean
  dryRun: boolean
  considered: number
  eligible: number
  masks_known: number
  listed_before: number
  listed_after: number
  inserted: number
  chunks: number
  errors: number
  planned: BotSeedPlan[]
  message: string
}

export interface BotVendorCandidate {
  template_id: string
  tier: number
  rarity: string
  stackable: boolean
  stack_max: number
  vendor_price: number
  target_price: number
}

export interface BotVendorSnapshotResponse {
  ok: boolean
  provisioned: boolean
  total?: number
  candidates: BotVendorCandidate[]
  message?: string
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
  nocache?: boolean
}

export function getMarketItems(q: MarketItemsQuery = {}) {
  return api<MarketItemsResponse>(`/api/gameplay/market/items${qs({
    search: q.search, category: q.category, tier: q.tier, rarity: q.rarity,
    owner: q.owner, sort: q.sort, dir: q.dir,
    page: q.page, limit: q.limit, demo: q.demo ? 1 : undefined,
    nocache: q.nocache ? 1 : undefined,
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
  return api<{ ok: boolean; cleared: number; items_deleted?: number; orphans?: number; inventory_id?: number; message?: string }>(
    '/api/gameplay/market-bot/clear-listings',
    { method: 'POST' },
  )
}

export function clearBotLegacyListings() {
  return api<{ ok: boolean; cleared: number; message?: string }>(
    '/api/gameplay/market-bot/clear-legacy-listings',
    { method: 'POST' },
  )
}

export function clearBotError() {
  return api<{ ok: boolean }>(
    '/api/gameplay/market-bot/clear-error',
    { method: 'POST' },
  )
}

// Dry runs of the list tick still run inline and return the full plan. Live
// runs are dispatched into a background runspace and return an ack — progress
// is then published into BotStatus.list_tick_progress.
export interface BotListTickLaunch {
  ok: boolean
  running?: boolean
  message?: string
  error?: string
  progress?: BotListTickProgress
}

export function runBotListTick(dryRun: true): Promise<BotListTickResult>
export function runBotListTick(dryRun: false): Promise<BotListTickLaunch>
export function runBotListTick(dryRun: boolean): Promise<BotListTickResult | BotListTickLaunch> {
  return api<BotListTickResult | BotListTickLaunch>(`/api/gameplay/market-bot/tick/list${dryRun ? '?dry=1' : ''}`, {
    method: 'POST',
    body: JSON.stringify({ dryRun }),
  })
}

// Live seed market is dispatched into a dedicated server-side runspace —
// the POST returns immediately with this ack and progress is published into
// BotStatus.seed_progress (polled via getBotStatus). 409 means "already
// running" and the body still carries the current progress snapshot.
export interface BotSeedLaunch {
  ok: boolean
  running?: boolean
  message?: string
  error?: string
  progress?: BotSeedProgress
}

export function runBotSeedDryRun() {
  return api<BotSeedResult>('/api/gameplay/market-bot/seed?dry=1', {
    method: 'POST',
    body: JSON.stringify({ dryRun: true }),
  })
}

export function startBotSeedMarket() {
  return api<BotSeedLaunch>('/api/gameplay/market-bot/seed', {
    method: 'POST',
    body: JSON.stringify({}),
  })
}

export interface BotSeedAbortResult {
  ok: boolean
  stopped?: boolean
  message?: string
}

export function abortBotSeedMarket() {
  return api<BotSeedAbortResult>('/api/gameplay/market-bot/seed/abort', {
    method: 'POST',
    body: JSON.stringify({}),
  })
}

export function getBotVendorSnapshot() {
  return api<BotVendorSnapshotResponse>('/api/gameplay/market-bot/vendor-snapshot')
}

// ---------------------------------------------------------------------------
// Players
// ---------------------------------------------------------------------------
export interface Player {
  id: number            // pawn actor id (inventory writes)
  account_id: number    // rename, tags
  controller_id: number // currency + specialization (tracks/keystones) writes
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
  water_amount: string
  water_type: string
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

export function giveItem(pawnId: number, template: string, qty: number, quality: number, allowOverflow = false) {
  return api<WriteResult>('/api/gameplay/players/give-item', {
    method: 'POST', body: JSON.stringify({ pawn_id: pawnId, template, qty, quality, allow_overflow: allowOverflow }),
  })
}

export function renamePlayer(accountId: number, name: string) {
  return api<WriteResult>('/api/gameplay/players/rename', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, name }),
  })
}

export function awardSpecXp(controllerId: number, trackType: string, delta: number) {
  return api<WriteResult>('/api/gameplay/players/award-xp', {
    method: 'POST', body: JSON.stringify({ controller_id: controllerId, track_type: trackType, delta }),
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

export function setItemDurability(itemId: number, max: number, current: number, decayed: number) {
  return api<WriteResult>('/api/gameplay/players/set-item-durability', {
    method: 'POST',
    body: JSON.stringify({ item_id: itemId, max, current, decayed }),
  })
}

export function setItemWater(itemId: number, amount: number) {
  return api<WriteResult>('/api/gameplay/players/set-item-water', {
    method: 'POST',
    body: JSON.stringify({ item_id: itemId, amount }),
  })
}

// ---------------------------------------------------------------------------
// Landsraad house-contribution admin (#224).
// ---------------------------------------------------------------------------
export interface LandsraadHouse {
  task_id: number
  board_index: number
  house_name: string
  display_name: string
  goal_amount: number
  completed: boolean
  winning_faction_id: number
}
export interface LandsraadIniSetting {
  key: string
  label: string
  help: string
  value: string | null
}
export interface LandsraadOverviewResponse {
  term_id: number
  houses: LandsraadHouse[]
  settings: LandsraadIniSetting[]
  settings_error?: string | null
  source: DataSource
  liveError?: string
}
export interface LandsraadContribution {
  task_id: number
  house_name: string
  display_name: string
  amount: number
}
export interface LandsraadContributionsResponse {
  term_id: number
  contributions: LandsraadContribution[]
  source: DataSource
  liveError?: string
}

export function getLandsraadOverview(demo?: boolean) {
  return api<LandsraadOverviewResponse>(`/api/gameplay/landsraad/overview${qs({ demo: demo ? 1 : undefined })}`)
}

export function getLandsraadPlayerContributions(controllerId: number, demo?: boolean) {
  return api<LandsraadContributionsResponse>(`/api/gameplay/landsraad/player-contributions${qs({
    controller: controllerId, demo: demo ? 1 : undefined,
  })}`)
}

export function setLandsraadContribution(controllerId: number, taskId: number, amount: number) {
  return api<WriteResult>('/api/gameplay/landsraad/set-contribution', {
    method: 'POST',
    body: JSON.stringify({ controller_id: controllerId, task_id: taskId, amount }),
  })
}

// ---------------------------------------------------------------------------
// v11.5.6 — extended player surface (port of the reference implementation's player tooling).
// ---------------------------------------------------------------------------

export interface PlayerSummaryBucket { name: string; count: number }

export interface PlayerSummaryResponse {
  totals: { players: number; online: number; factions: number }
  by_faction: PlayerSummaryBucket[]
  by_map: PlayerSummaryBucket[]
  source: DataSource
  liveError?: string
}

export function getPlayerSummary(demo?: boolean) {
  return api<PlayerSummaryResponse>(`/api/gameplay/players/summary${qs({ demo: demo ? 1 : undefined })}`)
}

export interface PlayerStats {
  pawn_id: number
  account_id: number
  controller_id: number
  character_name: string
  class: string
  map: string
  online_status: string
  last_seen: string
  faction_id: number
  faction_name: string
  solaris: number
  total_currency: number
}

export interface PlayerStatsResponse {
  stats: PlayerStats | null
  source: DataSource
  liveError?: string
}

export function getPlayerStats(pawnId: number, demo?: boolean) {
  return api<PlayerStatsResponse>(`/api/gameplay/players/stats${qs({
    pawn: pawnId, demo: demo ? 1 : undefined,
  })}`)
}

export interface SpecTrackFull {
  track_type: string
  xp: number
  level: number
  xp_max: number
  level_max: number
}

export interface PlayerSpecsResponse {
  tracks: SpecTrackFull[]
  keystones_total: number
  keystones_max: number
  unsupported?: boolean
  source: DataSource
  liveError?: string
}

export function getPlayerSpecs(pawnId: number, controllerId: number, demo?: boolean) {
  return api<PlayerSpecsResponse>(`/api/gameplay/players/specs${qs({
    pawn: pawnId, controller: controllerId, demo: demo ? 1 : undefined,
  })}`)
}

export function grantMaxSpec(controllerId: number, trackType: string) {
  return api<WriteResult>('/api/gameplay/players/grant-max-spec', {
    method: 'POST', body: JSON.stringify({ controller_id: controllerId, track_type: trackType }),
  })
}

export function resetSpec(controllerId: number, trackType: string) {
  return api<WriteResult>('/api/gameplay/players/reset-spec', {
    method: 'POST', body: JSON.stringify({ controller_id: controllerId, track_type: trackType }),
  })
}

export function resetAllSpecs(controllerId: number) {
  return api<WriteResult>('/api/gameplay/players/reset-all-specs', {
    method: 'POST', body: JSON.stringify({ controller_id: controllerId }),
  })
}

export function grantAllKeystones(controllerId: number) {
  return api<WriteResult>('/api/gameplay/players/grant-all-keystones', {
    method: 'POST', body: JSON.stringify({ controller_id: controllerId }),
  })
}

export function resetAllKeystones(controllerId: number) {
  return api<WriteResult>('/api/gameplay/players/reset-all-keystones', {
    method: 'POST', body: JSON.stringify({ controller_id: controllerId }),
  })
}

export interface PlayerTagsResponse {
  tags: string[]
  unsupported?: boolean
  source: DataSource
  liveError?: string
}

export function getPlayerTags(accountId: number, demo?: boolean) {
  return api<PlayerTagsResponse>(`/api/gameplay/players/tags${qs({
    account: accountId, demo: demo ? 1 : undefined,
  })}`)
}

export function setPlayerTags(accountId: number, tags: string[]) {
  return api<WriteResult>('/api/gameplay/players/tags', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, tags }),
  })
}

export interface PlayerEvent {
  id: number
  ts: string
  event_type: string
  meta: string
}

export interface PlayerEventsResponse {
  events: PlayerEvent[]
  unsupported?: boolean
  source: DataSource
  liveError?: string
}

export function getPlayerEvents(accountId: number, limit?: number, demo?: boolean) {
  return api<PlayerEventsResponse>(`/api/gameplay/players/events${qs({
    account: accountId, limit: limit ?? undefined, demo: demo ? 1 : undefined,
  })}`)
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

// ---------------------------------------------------------------------------
// v11.5.7 — Item catalog (for autocomplete), Fill Water, Coriolis admin.
// ---------------------------------------------------------------------------

/**
 * A valid give-item template id is a game class string (e.g. "CopperBar"),
 * never a bare number. The game's dune.items.template_id can't resolve a numeric
 * id, so such rows are inserted but render invisible and get dropped on zone/login
 * load. Reject empty and purely-numeric ids so they can't reach a give request.
 */
export function isValidTemplateId(t: string): boolean {
  const s = (t ?? '').trim()
  if (!s) return false
  if (/^\d+$/.test(s)) return false
  return /[A-Za-z]/.test(s)
}

export interface CatalogItem {
  template_id: string
  name: string
  category: string
  gradeable?: boolean
  tier?: number
}

interface RawCatalogEntry {
  templateId?: string
  template_id?: string
  name?: string
  category?: string
  gradeable?: boolean
  tier?: number
}

interface CatalogResponse {
  _meta?: { count?: number; source?: string }
  meta?: { total?: number; source?: string }
  // The backend (/api/catalog/items -> Get-DuneItemCatalog) serializes `items`
  // as an ARRAY of { templateId, name, category }. Older/alternate builds may
  // emit a dict keyed by template_id. flattenItemCatalog handles both.
  items: RawCatalogEntry[] | Record<string, { name?: string; category?: string; gradeable?: boolean; tier?: number }>
}

let _catalogCache: CatalogItem[] | null = null
let _catalogPromise: Promise<CatalogItem[]> | null = null

/**
 * Normalize the /api/catalog/items payload into CatalogItem[]. Critically, the
 * template_id MUST be the game class string (e.g. "AzuriteOre"), never an array
 * index — the give-item guard rejects numeric ids, so an index would make every
 * picked item unselectable. Reads the entry's `templateId` field for the array
 * shape, or the object key for the dict shape.
 */
export function flattenItemCatalog(raw: CatalogResponse['items'] | undefined | null): CatalogItem[] {
  const flat: CatalogItem[] = []
  if (Array.isArray(raw)) {
    for (const e of raw) {
      const tid = String(e?.templateId ?? e?.template_id ?? '').trim()
      if (!tid) continue
      flat.push({ template_id: tid, name: e?.name || tid, category: e?.category || '', gradeable: !!e?.gradeable, tier: e?.tier })
    }
  } else if (raw && typeof raw === 'object') {
    const dict = raw as Record<string, { name?: string; category?: string; gradeable?: boolean; tier?: number }>
    for (const tid of Object.keys(dict)) {
      const key = tid.trim()
      if (!key) continue
      const v = dict[tid]
      flat.push({ template_id: key, name: v?.name || key, category: v?.category || '', gradeable: !!v?.gradeable, tier: v?.tier })
    }
  }
  flat.sort((a, b) => a.name.localeCompare(b.name))
  return flat
}

/**
 * Load + cache the full item catalog. ~979 entries, ~110KB JSON; only fetched
 * once per session. See flattenItemCatalog for the shape handling.
 */
export function getItemCatalog(): Promise<CatalogItem[]> {
  if (_catalogCache) return Promise.resolve(_catalogCache)
  if (_catalogPromise) return _catalogPromise
  _catalogPromise = api<CatalogResponse>('/api/catalog/items').then(r => {
    const flat = flattenItemCatalog(r.items)
    _catalogCache = flat
    _catalogPromise = null
    return flat
  }).catch(e => {
    _catalogPromise = null
    throw e
  })
  return _catalogPromise
}

/**
 * Distinct, alphabetically-sorted list of non-empty categories in the catalog.
 * Drives the ItemPicker category selector.
 */
export function catalogCategories(catalog: CatalogItem[]): string[] {
  const set = new Set<string>()
  for (const it of catalog) {
    const c = (it.category || '').trim()
    if (c) set.add(c)
  }
  return Array.from(set).sort((a, b) => a.localeCompare(b))
}

/**
 * Case-insensitive substring filter over name OR template_id. Returns up to
 * `limit` matches sorted by best-match (template_id prefix > name prefix >
 * substring), then alphabetically.
 *
 * When `category` is set, results are restricted to that category. An empty
 * query normally returns nothing (we don't dump 1.3k items), but if a category
 * is selected an empty query lists that category's items alphabetically so the
 * selector alone is a usable browse mode.
 */
export function filterCatalog(catalog: CatalogItem[], query: string, limit = 20, category = ''): CatalogItem[] {
  const q = query.trim().toLowerCase()
  const cat = category.trim()
  const inCat = cat ? catalog.filter(it => (it.category || '').trim() === cat) : catalog
  if (!q) {
    if (!cat) return []
    return inCat.slice().sort((a, b) => a.name.localeCompare(b.name)).slice(0, limit)
  }
  const out: { item: CatalogItem; rank: number }[] = []
  for (const it of inCat) {
    const tid = it.template_id.toLowerCase()
    const nm  = it.name.toLowerCase()
    let rank = -1
    if (tid === q || nm === q)                 rank = 0
    else if (tid.startsWith(q))                rank = 1
    else if (nm.startsWith(q))                 rank = 2
    else if (tid.includes(q) || nm.includes(q)) rank = 3
    if (rank >= 0) out.push({ item: it, rank })
  }
  out.sort((a, b) => a.rank - b.rank || a.item.name.localeCompare(b.item.name))
  return out.slice(0, limit).map(o => o.item)
}

export interface FillWaterResponse {
  ok: boolean
  message: string
  result?: { refilled?: number }
}

export function fillWater(pawnId: number): Promise<FillWaterResponse> {
  return api<FillWaterResponse>('/api/gameplay/players/fill-water', {
    method: 'POST', body: JSON.stringify({ pawn_id: pawnId }),
  })
}

export interface CoriolisMap       { map: string; seed: number }
export interface CoriolisPartition { partition_id: number; map: string; seed: number }

export interface CoriolisSeedsResponse {
  ok: boolean
  source: DataSource
  farm_seed: number
  maps: CoriolisMap[]
  partitions: CoriolisPartition[]
  liveError?: string
}

export function getCoriolisSeeds() {
  return api<CoriolisSeedsResponse>('/api/gameplay/coriolis/seeds')
}

export function setCoriolisFarmSeed(seed: number) {
  return api<WriteResult>('/api/gameplay/coriolis/set-farm-seed', {
    method: 'POST', body: JSON.stringify({ seed }),
  })
}

export function setCoriolisMapSeed(map: string, seed: number) {
  return api<WriteResult>('/api/gameplay/coriolis/set-map-seed', {
    method: 'POST', body: JSON.stringify({ map, seed }),
  })
}

export function setCoriolisPartitionSeed(partitionId: number, seed: number) {
  return api<WriteResult>('/api/gameplay/coriolis/set-partition-seed', {
    method: 'POST', body: JSON.stringify({ partition_id: partitionId, seed }),
  })
}

// ===========================================================================
// v11.5.9 — Phase A/B/C/G+H/I — full the reference implementation player surface port.
// Adds the remaining 40+ endpoints not previously surfaced. Existing
// wrappers above (giveSolari, giveItem, renamePlayer, awardSpecXp,
// setPlayerTags, fillWater) are kept untouched for back-compat.
// ===========================================================================

// ----- Shared player-target type ------------------------------------------
// Most v11.5.9 RMQ-live handlers accept either fls_id (preferred) or actor_id
// (server resolves fls). This helper keeps call sites readable.
export interface PlayerTarget {
  fls_id?: string
  actor_id?: number
}
function targetBody(t: PlayerTarget, rest: Record<string, unknown> = {}) {
  const out: Record<string, unknown> = { ...rest }
  if (t.fls_id)   out.fls_id   = t.fls_id
  if (t.actor_id) out.actor_id = t.actor_id
  return JSON.stringify(out)
}

// ---------------------------------------------------------------------------
// Phase A — currency / progression / admin writes (5 + 3 endpoints)
// ---------------------------------------------------------------------------

export function giveScrip(controllerId: number, amount: number) {
  return api<WriteResult>('/api/gameplay/players/give-scrip', {
    method: 'POST', body: JSON.stringify({ actor_id: controllerId, delta: amount }),
  })
}

export type FactionId = 'atreides' | 'harkonnen' | string

// The faction-write routes expect a numeric faction_id (1=Atreides, 2=Harkonnen,
// 4=Smuggler). The UI collects a name (or a raw number), so normalize here.
const FACTION_NAME_TO_ID: Record<string, number> = { atreides: 1, harkonnen: 2, smuggler: 4 }
function resolveFactionId(faction: FactionId): number {
  const key = String(faction || '').trim().toLowerCase()
  if (FACTION_NAME_TO_ID[key] != null) return FACTION_NAME_TO_ID[key]
  const n = Number(key)
  return Number.isFinite(n) ? n : 0
}

export function giveFactionRep(controllerId: number, faction: FactionId, delta: number) {
  return api<WriteResult>('/api/gameplay/players/give-faction-rep', {
    method: 'POST', body: JSON.stringify({ actor_id: controllerId, faction_id: resolveFactionId(faction), delta }),
  })
}

export function setFactionTier(controllerId: number, faction: FactionId, tier: number) {
  return api<WriteResult>('/api/gameplay/players/set-faction-tier', {
    method: 'POST', body: JSON.stringify({ actor_id: controllerId, faction_id: resolveFactionId(faction), tier }),
  })
}

// Phase A award-char-xp: increments character XP + level + SP + intel.
// Auto-routes server-side: offline players get a direct DB write; online players
// get the game-native RMQ AwardXP command (category-based, default Combat) so the
// award isn't clobbered on logout. Response.path = 'rmq' (live) | 'sql' (offline).
export function awardCharXp(pawnId: number, delta: number, category = 'Combat') {
  return api<WriteResult>('/api/gameplay/players/award-char-xp', {
    method: 'POST', body: JSON.stringify({ pawn_id: pawnId, delta, category }),
  })
}

export function awardIntel(controllerId: number, pawnId: number, amount: number) {
  return api<WriteResult>('/api/gameplay/players/award-intel', {
    method: 'POST', body: JSON.stringify({ actor_id: controllerId, pawn_id: pawnId, delta: amount }),
  })
}

export function returningPlayerAward(accountId: number) {
  return api<WriteResult>('/api/gameplay/players/returning-player-award', {
    method: 'POST', body: JSON.stringify({ account_id: accountId }),
  })
}

export function dismissReturningPlayerAward(accountId: number) {
  return api<WriteResult>('/api/gameplay/players/dismiss-returning-player-award', {
    method: 'POST', body: JSON.stringify({ account_id: accountId }),
  })
}

// PERMANENT — purges the account row + dependent rows. No undo.
export function deleteAccount(accountId: number) {
  return api<WriteResult>('/api/gameplay/players/delete-account', {
    method: 'POST', body: JSON.stringify({ account_id: accountId }),
  })
}

// ---------------------------------------------------------------------------
// Phase B — read endpoints (12 + 3 catalogs)
// ---------------------------------------------------------------------------

export interface OnlinePlayer {
  account_id: number
  display_name: string
  fls_id?: string
  pawn_id?: number
  controller_id?: number
  partition_id?: number
}
export interface PlayersOnlineResponse {
  ok: boolean
  source: DataSource
  players: OnlinePlayer[]
  liveError?: string
}
export function getPlayersOnline(demo?: boolean) {
  return api<PlayersOnlineResponse>(`/api/gameplay/players/online${qs({ demo: demo ? 1 : undefined })}`)
}

export interface FactionRow { id: string; display_name: string; aliases?: string[] }
export function getFactionCatalog() {
  return api<{ ok: boolean; factions: FactionRow[]; source: DataSource }>('/api/gameplay/players/factions')
}

export interface SpecTrackCatalog { id: string; name: string; tracks: Array<{ id: string; name: string }> }
export function getSpecCatalog() {
  return api<{ ok: boolean; specs: SpecTrackCatalog[]; source: DataSource }>('/api/gameplay/players/specs')
}

export interface JourneyStep { id: string; name: string; completed: boolean; current?: boolean }
export function getPlayerJourney(id: number, demo?: boolean) {
  return api<{ ok: boolean; account_id: number; steps: JourneyStep[]; source: DataSource }>(
    `/api/gameplay/players/${id}/journey${qs({ demo: demo ? 1 : undefined })}`)
}

// Full character dump - shape is intentionally loose (mirrors the reference implementation export).
export function exportPlayerData(id: number, demo?: boolean) {
  return api<{ ok: boolean; account_id: number; data: Record<string, unknown>; source: DataSource }>(
    `/api/gameplay/players/${id}/export${qs({ demo: demo ? 1 : undefined })}`)
}

export interface CharXpResponse {
  ok: boolean
  account_id: number
  pawn_id?: number
  level: number
  xp: number
  xp_to_next?: number
  unspent_skill_points?: number
  total_skill_points_earned?: number
  source: DataSource
}
export function getPlayerCharXp(id: number, demo?: boolean) {
  return api<CharXpResponse>(`/api/gameplay/players/${id}/char-xp${qs({ demo: demo ? 1 : undefined })}`)
}

export interface KeystoneRow { id: string; name?: string; unlocked_at?: string }
export function getPlayerKeystones(id: number, demo?: boolean) {
  return api<{ ok: boolean; keystones: KeystoneRow[]; source: DataSource }>(
    `/api/gameplay/players/${id}/keystones${qs({ demo: demo ? 1 : undefined })}`)
}

export interface PlayerVehicleRow {
  vehicle_id: number
  template: string
  display_name?: string
  fuel?: number
  durability?: number
}
export function getPlayerVehicles(id: number, demo?: boolean) {
  return api<{ ok: boolean; vehicles: PlayerVehicleRow[]; source: DataSource }>(
    `/api/gameplay/players/${id}/vehicles${qs({ demo: demo ? 1 : undefined })}`)
}

export interface DungeonRunRow { dungeon_id: string; cleared: boolean; best_time_seconds?: number }
export function getPlayerDungeons(id: number, demo?: boolean) {
  return api<{ ok: boolean; runs: DungeonRunRow[]; source: DataSource }>(
    `/api/gameplay/players/${id}/dungeons${qs({ demo: demo ? 1 : undefined })}`)
}

export interface PlayerIdsResponse {
  ok: boolean
  account_id: number
  pawn_id?: number
  controller_id?: number
  fls_id?: string
  source: DataSource
}
export function getPlayerIds(id: number) {
  return api<PlayerIdsResponse>(`/api/gameplay/players/${id}/player-ids`)
}

export interface PartitionRow { id: number; map: string; display_name?: string; is_blocked?: boolean }
export function getPartitions() {
  return api<{ ok: boolean; partitions: PartitionRow[]; source: DataSource }>('/api/gameplay/players/partitions')
}

export interface ContractRow { id: string; name: string; faction?: string; tier?: number }
export function getContracts() {
  return api<{ ok: boolean; contracts: ContractRow[]; source: DataSource }>('/api/gameplay/contracts')
}

export interface ProgressionPreset {
  id: string
  name: string
  description?: string
  node_count?: number
  nodes: string[]
}
export function getProgressionPresets() {
  return api<{ ok: boolean; presets: ProgressionPreset[]; source: DataSource }>('/api/gameplay/progression/presets')
}

// ---------------------------------------------------------------------------
// Phase C/D/E/F — items / vehicles / teleport / progression / contracts /
// jobs / codex / tutorials (20 endpoints)
// ---------------------------------------------------------------------------

export interface GiveItemEntry { template: string; qty: number; quality?: number }
export function giveItems(pawnId: number, items: GiveItemEntry[]) {
  return api<WriteResult>('/api/gameplay/players/give-items', {
    method: 'POST', body: JSON.stringify({ pawn_id: pawnId, items }),
  })
}

// Admin-defined item packages — a saved, named bundle of items an admin can
// hand to any player in one click (delivered via giveItems). Persisted
// server-side (%APPDATA%\DuneServer\item-packages.json) so they survive restarts
// and are shared across the desktop app and the remote portal.
export interface ItemPackage { id: string; name: string; items: GiveItemEntry[] }

export async function getItemPackages(): Promise<ItemPackage[]> {
  const r = await api<{ ok: boolean; packages: ItemPackage[] }>('/api/gameplay/item-packages')
  return r.packages ?? []
}

export async function saveItemPackage(pkg: { id?: string; name: string; items: GiveItemEntry[] }): Promise<ItemPackage> {
  const r = await api<{ ok: boolean; package: ItemPackage }>('/api/gameplay/item-packages', {
    method: 'PUT', body: JSON.stringify(pkg),
  })
  return r.package
}

export function deleteItemPackage(id: string) {
  return api<{ ok: boolean; removed: boolean }>(`/api/gameplay/item-packages?id=${encodeURIComponent(id)}`, {
    method: 'DELETE',
  })
}

export function repairGear(pawnId: number) {
  return api<WriteResult>('/api/gameplay/players/repair-gear', {
    method: 'POST', body: JSON.stringify({ pawn_id: pawnId }),
  })
}

export function restoreDestroyed(pawnId: number) {
  return api<WriteResult>('/api/gameplay/players/restore-destroyed', {
    method: 'POST', body: JSON.stringify({ pawn_id: pawnId }),
  })
}

export function repairVehicle(vehicleId: number) {
  return api<WriteResult>('/api/gameplay/players/repair-vehicle', {
    method: 'POST', body: JSON.stringify({ vehicle_id: vehicleId }),
  })
}

export function refuelVehicle(vehicleId: number, fuel?: number) {
  const body: Record<string, unknown> = { vehicle_id: vehicleId }
  if (typeof fuel === 'number') body.fuel = fuel
  return api<WriteResult>('/api/gameplay/players/refuel-vehicle', {
    method: 'POST', body: JSON.stringify(body),
  })
}

// Teleport A -> B. Auto-dispatches: if source is online, server uses RMQ
// TeleportToExact; if offline, falls back to admin_move_offline_player_to_partition.
export function teleportToPlayer(sourcePawnId: number, targetPawnId: number) {
  return api<WriteResult>('/api/gameplay/players/teleport-to-player', {
    method: 'POST', body: JSON.stringify({ source_pawn_id: sourcePawnId, target_pawn_id: targetPawnId }),
  })
}

export function progressionUnlock(pawnId: number, nodeIds: string[]) {
  return api<WriteResult>('/api/gameplay/players/progression-unlock', {
    method: 'POST', body: JSON.stringify({ pawn_id: pawnId, node_ids: nodeIds }),
  })
}

export function progressionReverse(pawnId: number, nodeIds: string[]) {
  return api<WriteResult>('/api/gameplay/players/progression-reverse', {
    method: 'POST', body: JSON.stringify({ pawn_id: pawnId, node_ids: nodeIds }),
  })
}

export function applyProgressionPreset(accountId: number, presetId: string) {
  return api<WriteResult>('/api/gameplay/players/progression/apply-preset', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, preset_id: presetId }),
  })
}

export function completeJourneyStep(accountId: number, stepId: string) {
  return api<WriteResult>('/api/gameplay/players/journey/complete', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, step_id: stepId }),
  })
}

export function resetJourney(accountId: number) {
  return api<WriteResult>('/api/gameplay/players/journey/reset', {
    method: 'POST', body: JSON.stringify({ account_id: accountId }),
  })
}

export function wipeJourney(accountId: number) {
  return api<WriteResult>('/api/gameplay/players/journey/wipe', {
    method: 'POST', body: JSON.stringify({ account_id: accountId }),
  })
}

export function completeContract(accountId: number, contractId: string) {
  return api<WriteResult>('/api/gameplay/players/contract/complete', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, contract_id: contractId }),
  })
}

export function completeContracts(accountId: number, contractIds: string[]) {
  return api<WriteResult>('/api/gameplay/players/contracts/complete', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, contract_ids: contractIds }),
  })
}

export function reverseContracts(accountId: number, contractIds: string[]) {
  return api<WriteResult>('/api/gameplay/players/contracts/reverse', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, contract_ids: contractIds }),
  })
}

export function grantJobSkills(pawnId: number, jobId: string) {
  return api<WriteResult>('/api/gameplay/players/grant-job-skills', {
    method: 'POST', body: JSON.stringify({ pawn_id: pawnId, job_id: jobId }),
  })
}

export function resetJobSkills(pawnId: number, jobId: string) {
  return api<WriteResult>('/api/gameplay/players/reset-job-skills', {
    method: 'POST', body: JSON.stringify({ pawn_id: pawnId, job_id: jobId }),
  })
}

export function setStarterClass(pawnId: number, classId: string) {
  return api<WriteResult>('/api/gameplay/players/set-starter-class', {
    method: 'POST', body: JSON.stringify({ pawn_id: pawnId, class_id: classId }),
  })
}

export function deleteTutorials(accountId: number) {
  return api<WriteResult>('/api/gameplay/players/delete-tutorials', {
    method: 'POST', body: JSON.stringify({ account_id: accountId }),
  })
}

export function wipeCodex(accountId: number) {
  return api<WriteResult>('/api/gameplay/players/wipe-codex', {
    method: 'POST', body: JSON.stringify({ account_id: accountId }),
  })
}

// ---------------------------------------------------------------------------
// Phase G+H — RMQ live commands (require RabbitMQ pipeline; need ONLINE player)
// + grant-live (pg_notify, works online or offline).
// ---------------------------------------------------------------------------

export function kickPlayer(t: PlayerTarget) {
  return api<WriteResult>('/api/gameplay/players/kick', {
    method: 'POST', body: targetBody(t),
  })
}

export function setSkillPoints(t: PlayerTarget, skillPoints: number) {
  return api<WriteResult>('/api/gameplay/players/set-skill-points', {
    method: 'POST', body: targetBody(t, { skill_points: skillPoints }),
  })
}

export function cleanPlayerInventory(t: PlayerTarget) {
  return api<WriteResult>('/api/gameplay/players/clean-inventory', {
    method: 'POST', body: targetBody(t),
  })
}

export function resetProgressionLive(t: PlayerTarget) {
  return api<WriteResult>('/api/gameplay/players/reset-progression', {
    method: 'POST', body: targetBody(t),
  })
}

export function setSkillModuleLive(t: PlayerTarget, moduleId: string, level: number) {
  return api<WriteResult>('/api/gameplay/players/set-skill-module', {
    method: 'POST', body: targetBody(t, { module_id: moduleId, level }),
  })
}

export function giveItemLive(t: PlayerTarget, template: string, qty: number, quality: number) {
  return api<WriteResult>('/api/gameplay/players/give-item-live', {
    method: 'POST', body: targetBody(t, { template, qty, quality }),
  })
}

export function cheatScript(t: PlayerTarget, script: string) {
  return api<WriteResult>('/api/gameplay/players/cheat-script', {
    method: 'POST', body: targetBody(t, { script }),
  })
}

// Landsraad-style grant; pops a Claim Rewards prompt for the player.
// Works whether the player is online or offline (pg_notify trigger).
export function grantLive(controllerId: number, template: string, amount: number) {
  return api<WriteResult>('/api/gameplay/players/grant-live', {
    method: 'POST', body: JSON.stringify({ controller_id: controllerId, template, amount }),
  })
}

export interface SpawnVehicleInput {
  target: PlayerTarget
  className: string
  templateName?: string
  persistent?: boolean
  faction?: string
  location?: { x: number; y: number; z: number }
}
export function spawnVehicle(input: SpawnVehicleInput) {
  const body: Record<string, unknown> = { class_name: input.className }
  if (input.target.fls_id)      body.fls_id        = input.target.fls_id
  if (input.target.actor_id)    body.actor_id      = input.target.actor_id
  if (input.templateName)       body.template_name = input.templateName
  if (input.persistent != null) body.persistent    = input.persistent
  if (input.faction)            body.faction       = input.faction
  if (input.location) { body.x = input.location.x; body.y = input.location.y; body.z = input.location.z }
  return api<WriteResult>('/api/gameplay/vehicles/spawn', {
    method: 'POST', body: JSON.stringify(body),
  })
}

export function chatWhisper(flsId: string, message: string) {
  return api<WriteResult>('/api/gameplay/chat/whisper', {
    method: 'POST', body: JSON.stringify({ fls_id: flsId, message }),
  })
}

// ---------------------------------------------------------------------------
// Phase I — tags add/remove delta (separate from setPlayerTags overwrite)
// ---------------------------------------------------------------------------

export function updatePlayerTags(accountId: number, add: string[], remove: string[]) {
  return api<WriteResult>('/api/gameplay/players/update-tags', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, add, remove }),
  })
}

// ---------------------------------------------------------------------------
// §10 — storage owner debug
// ---------------------------------------------------------------------------

export interface StorageOwnerDebug {
  ok: boolean
  placeable_id: number
  debug?: Record<string, unknown>
  source: DataSource
}
export function getStorageOwnerDebug(placeableId: number) {
  return api<StorageOwnerDebug>(`/api/gameplay/storage/${placeableId}/owner-debug`)
}