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
  schematic_tier_prices: Record<string, number>
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
  over_market_guard: boolean
  over_market_pct: number
  over_market_allow_unpriced?: boolean
  over_market_baseline?: number
  // Market-follow pricing (v12.5.0+): list at the median of competing player
  // sell orders + a markup, instead of the formula. All-or-nothing; toggling
  // requires a Duke-listings wipe (handled server-side on the next list tick).
  market_follow_enabled?: boolean
  market_follow_pct?: number
  market_follow_min_samples?: number
  market_follow_no_market?: 'formula' | 'skip' | 'baseline'
  market_follow_baseline?: number
  market_follow_force_guard?: boolean
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
  blocked?: number
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
  market_medians?: number
  wiped?: boolean
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

export function resetBotConfig() {
  return api<BotConfig>('/api/gameplay/market-bot/config/reset', {
    method: 'POST',
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

export function giveItem(pawnId: number, template: string, qty: number, quality: number, allowOverflow = true) {
  return api<WriteResult>('/api/gameplay/players/give-item', {
    method: 'POST', body: JSON.stringify({ pawn_id: pawnId, template, qty, quality, allow_overflow: allowOverflow }),
  })
}

export function renamePlayer(accountId: number, name: string) {
  return api<WriteResult>('/api/gameplay/players/rename', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, name }),
  })
}

export function setSpecLevel(controllerId: number, trackType: string, level: number) {
  return api<WriteResult>('/api/gameplay/players/set-spec-level', {
    method: 'POST', body: JSON.stringify({ controller_id: controllerId, track_type: trackType, level }),
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

export function setItemStack(itemId: number, stackSize: number) {
  return api<WriteResult>('/api/gameplay/players/set-item-stack', {
    method: 'POST',
    body: JSON.stringify({ item_id: itemId, stack_size: stackSize }),
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

// Landsraad reward thresholds/items admin (#250).
export interface LandsraadRewardTier {
  threshold: number
  template_id: string
  amount: number
}
export interface LandsraadRewardHouse {
  task_id: number
  house_name: string
  display_name: string
  board_index: number
  tiers: LandsraadRewardTier[]
}
export interface LandsraadRewardsResponse {
  term_id: number
  houses: LandsraadRewardHouse[]
  source: DataSource
  liveError?: string
}
export function getLandsraadRewards(demo?: boolean) {
  return api<LandsraadRewardsResponse>(`/api/gameplay/landsraad/rewards${qs({ demo: demo ? 1 : undefined })}`)
}
export function setLandsraadThresholds(mappings: { old: number; new: number }[]) {
  return api<WriteResult>('/api/gameplay/landsraad/set-thresholds', {
    method: 'POST',
    body: JSON.stringify({ mappings }),
  })
}
export function setLandsraadRewardTier(taskId: number, threshold: number, templateId?: string, amount?: number) {
  return api<WriteResult>('/api/gameplay/landsraad/set-reward-tier', {
    method: 'POST',
    body: JSON.stringify({ task_id: taskId, threshold, template_id: templateId, amount }),
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
  faction_reps?: { faction_id: number; faction_name: string; reputation: number }[]
  faction_rep_cap?: number
  scrip?: number
  intel?: number
  intel_max?: number
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
  totemId: number
  owner: string
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

// Release/destroy a base land claim by deleting its totem actor (cascades the
// ownership grants). Destructive + live-DB only; takes effect after a
// battlegroup restart. Callers must confirm + warn about backups first.
export function destroyClaim(totemId: number) {
  return api<WriteResult>('/api/gameplay/bases/destroy-claim', {
    method: 'POST', body: JSON.stringify({ totem_id: totemId }),
  })
}

// Free abandoned base (EXPERIMENTAL): make a deleted-owner's abandoned base
// accessible + re-claimable WITHOUT destroying any structure. Clears the
// per-placeable access locks (doors/storage) for the base's owner entity and
// deletes the lingering totem. No structure rows are removed. Live-DB only;
// takes effect after a battlegroup restart. Mechanism validated live on UAT.
export interface FreeBasePreview extends WriteResult {
  result?: {
    ok: boolean
    entityId: string
    pieces: number
    placeables: number
    locks: number
    doorLocks: number
    buildingGroups: number
    hasTotem: boolean
  }
}

export function freeBasePreview(baseId: number) {
  return api<FreeBasePreview>('/api/gameplay/bases/free-base/preview', {
    method: 'POST', body: JSON.stringify({ base_id: baseId }),
  })
}

export function freeBase(baseId: number) {
  return api<WriteResult>('/api/gameplay/bases/free-base', {
    method: 'POST', body: JSON.stringify({ base_id: baseId }),
  })
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

export function setStorageItemStack(itemId: number, stackSize: number) {
  return api<WriteResult>('/api/gameplay/storage/set-item-stack', {
    method: 'POST', body: JSON.stringify({ item_id: itemId, stack_size: stackSize }),
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

// Cosmetics catalog — appearance set variants, swatches, vehicle skins. Served
// by GET /api/catalog/cosmetics (from gameplay-item-data names). These aren't in
// the standard item catalog; granting one delivers it via the normal give-item
// path so the player unlocks the appearance.
export interface CosmeticEntry { template: string; name: string; group: string }
interface CosmeticsResponse { templates?: CosmeticEntry[]; total?: number }
let _cosmeticsCache: CosmeticEntry[] | null = null
let _cosmeticsPromise: Promise<CosmeticEntry[]> | null = null
export function getCosmeticsCatalog(): Promise<CosmeticEntry[]> {
  if (_cosmeticsCache) return Promise.resolve(_cosmeticsCache)
  if (_cosmeticsPromise) return _cosmeticsPromise
  _cosmeticsPromise = api<CosmeticsResponse>('/api/catalog/cosmetics').then(r => {
    const flat = (r.templates || []).filter(e => e && e.template)
    _cosmeticsCache = flat
    _cosmeticsPromise = null
    return flat
  }).catch(e => {
    _cosmeticsPromise = null
    throw e
  })
  return _cosmeticsPromise
}

// ===========================================================================
// Vehicle-kit catalog — single source of truth for the Give Vehicle Kit action,
// served by GET /api/catalog/vehicle-kits (app/data/vehicle-kits.json). Shared by
// this web UI and the mobile app so a kit change is one server-side edit.
// `className`/`templates` describe the SpawnVehicleAt loadout; `kit`/`unique`/`qty`
// drive the give-kit delivery.
// ===========================================================================
export interface VehicleTemplate {
  id: string
  label: string
  className: string
  templates: string[]
  kit: string[]
  unique: string[]
  qty?: Record<string, number>
}

export interface VehicleKitCatalog {
  fuelTemplate: string
  torchTemplate: string
  vehicles: VehicleTemplate[]
}

// ConvertTo-Json -Compress (Write-DuneJson) unwraps a single-element array into a
// bare value, so any of these list fields can arrive as a scalar — coerce back.
function _toStrArray(x: unknown): string[] {
  if (Array.isArray(x)) return x.map(v => String(v))
  if (x === null || x === undefined || x === '') return []
  return [String(x)]
}

let _vehicleKitCache: VehicleKitCatalog | null = null
let _vehicleKitPromise: Promise<VehicleKitCatalog> | null = null

export function getVehicleKitCatalog(): Promise<VehicleKitCatalog> {
  if (_vehicleKitCache) return Promise.resolve(_vehicleKitCache)
  if (_vehicleKitPromise) return _vehicleKitPromise
  _vehicleKitPromise = api<Partial<VehicleKitCatalog>>('/api/catalog/vehicle-kits').then(r => {
    const rawVehicles = Array.isArray(r?.vehicles) ? r.vehicles : (r?.vehicles ? [r.vehicles as VehicleTemplate] : [])
    const cat: VehicleKitCatalog = {
      fuelTemplate: r?.fuelTemplate || 'FuelCanister_Large',
      torchTemplate: r?.torchTemplate || 'RepairTool5',
      vehicles: rawVehicles.map((v: any) => ({
        id: String(v?.id ?? ''),
        label: String(v?.label ?? v?.id ?? ''),
        className: String(v?.className ?? ''),
        templates: _toStrArray(v?.templates),
        kit: _toStrArray(v?.kit),
        unique: _toStrArray(v?.unique),
        qty: (v?.qty && typeof v.qty === 'object') ? v.qty as Record<string, number> : {},
      })).filter(v => v.id),
    }
    _vehicleKitCache = cat
    _vehicleKitPromise = null
    return cat
  }).catch(e => {
    _vehicleKitPromise = null
    throw e
  })
  return _vehicleKitPromise
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

// ---------------------------------------------------------------------------
// Tag catalog — the universe of known gameplay tags (Contract.*, DialogueFlags.*,
// Journey.*, etc.) that can be written to a player. Powers the Tags editor
// typeahead. The backend serves the raw tag strings; we derive a friendly label
// + category client-side so the picker reads "Friendly Name  raw.tag.id".
// ---------------------------------------------------------------------------
export interface TagCatalogEntry {
  tag: string       // raw tag string written to the player
  label: string     // friendly, humanized breadcrumb label
  category: string  // first dotted segment (Contract, DialogueFlags, Journey, …)
  completable?: boolean // true for DA_* journey nodes that can be completed via the journey API
}

/** First dotted segment of a tag, e.g. "Contract" — used as a coarse category. */
export function tagCategory(tag: string): string {
  const i = tag.indexOf('.')
  return (i > 0 ? tag.slice(0, i) : tag).trim()
}

/** Humanize one tag segment: de-CamelCase, split letter/digit runs, drop underscores. */
function humanizeSegment(seg: string): string {
  return seg
    .replace(/_/g, ' ')
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/([A-Za-z])([0-9])/g, '$1 $2')
    .replace(/\s+/g, ' ')
    .trim()
}

/** Friendly breadcrumb label for a tag, e.g.
 *  "Contract.Tracking.Completed.SeronVarlin.Contract1" ->
 *  "Contract › Tracking › Completed › Seron Varlin › Contract 1". */
export function tagFriendlyLabel(tag: string): string {
  const parts = tag.split('.').map(humanizeSegment).filter(Boolean)
  return parts.length ? parts.join(' › ') : tag
}

let _tagCatalogCache: TagCatalogEntry[] | null = null
let _tagCatalogPromise: Promise<TagCatalogEntry[]> | null = null

interface TagCatalogResponse { tags?: string[]; total?: number; source?: string; completable?: string[] }

/** Load + cache the full player-relevant tag catalog (~3600 entries). Fetched once per session. */
export function getTagCatalog(): Promise<TagCatalogEntry[]> {
  if (_tagCatalogCache) return Promise.resolve(_tagCatalogCache)
  if (_tagCatalogPromise) return _tagCatalogPromise
  _tagCatalogPromise = api<TagCatalogResponse>('/api/gameplay/tags/catalog').then(r => {
    const completable = new Set((r.completable || []).map(t => String(t).trim()))
    const flat = (r.tags || [])
      .map(t => String(t).trim())
      .filter(Boolean)
      .map(tag => ({ tag, label: tagFriendlyLabel(tag), category: tagCategory(tag), completable: completable.has(tag) }))
      .sort((a, b) => a.label.localeCompare(b.label))
    _tagCatalogCache = flat
    _tagCatalogPromise = null
    return flat
  }).catch(e => {
    _tagCatalogPromise = null
    throw e
  })
  return _tagCatalogPromise
}

/**
 * Case-insensitive filter over friendly label OR raw tag. Entries whose tag is
 * in `exclude` (tags the player already has) are dropped. Empty query returns
 * the first `limit` entries so focusing the field shows a browsable list.
 */
export function filterTagCatalog(
  catalog: TagCatalogEntry[], query: string, limit = 50, exclude?: Set<string>,
): TagCatalogEntry[] {
  const q = query.trim().toLowerCase()
  const avail = exclude && exclude.size > 0 ? catalog.filter(e => !exclude.has(e.tag)) : catalog
  if (!q) return avail.slice(0, limit)
  const out: { entry: TagCatalogEntry; rank: number }[] = []
  for (const e of avail) {
    const tag = e.tag.toLowerCase()
    const lbl = e.label.toLowerCase()
    let rank = -1
    if (tag === q || lbl === q)                 rank = 0
    else if (tag.startsWith(q))                 rank = 1
    else if (lbl.startsWith(q))                 rank = 2
    else if (tag.includes(q) || lbl.includes(q)) rank = 3
    if (rank >= 0) out.push({ entry: e, rank })
  }
  out.sort((a, b) => a.rank - b.rank || a.entry.label.localeCompare(b.entry.label))
  return out.slice(0, limit).map(o => o.entry)
}

export interface PackageImportItem extends GiveItemEntry {
  name: string
}export interface PackageImportResult {
  items: PackageImportItem[]
  warnings: string[]
}

function normalizePackageItemName(s: string): string {
  return s.trim().replace(/\s+/g, ' ').toLowerCase()
}

export function parseTcnoPackageText(raw: string, catalog: CatalogItem[]): PackageImportResult {
  const lines = raw.split(/\r?\n/).map(l => l.trim()).filter(Boolean)
  const byName = new Map<string, CatalogItem>()
  const byTemplate = new Map<string, CatalogItem>()
  for (const item of catalog) {
    const nameKey = normalizePackageItemName(item.name)
    const templateKey = normalizePackageItemName(item.template_id)
    if (nameKey && !byName.has(nameKey)) byName.set(nameKey, item)
    if (templateKey && !byTemplate.has(templateKey)) byTemplate.set(templateKey, item)
  }

  const items: PackageImportItem[] = []
  const warnings: string[] = []
  for (let i = 0; i < lines.length; i += 2) {
    const nameLine = lines[i] ?? ''
    const qtyLine = lines[i + 1] ?? ''
    if (!nameLine.endsWith(':')) {
      warnings.push(`Line ${i + 1}: expected "Item name:"`)
      continue
    }
    if (!qtyLine) {
      warnings.push(`Line ${i + 2}: missing quantity for ${nameLine.slice(0, -1).trim()}`)
      continue
    }
    const itemName = nameLine.slice(0, -1).trim()
    const qty = Number.parseInt(qtyLine, 10)
    if (!Number.isFinite(qty) || qty < 1) {
      warnings.push(`Line ${i + 2}: invalid quantity "${qtyLine}" for ${itemName}`)
      continue
    }
    const key = normalizePackageItemName(itemName)
    const match = byName.get(key) ?? byTemplate.get(key)
    if (!match) {
      warnings.push(`Unknown item "${itemName}"`)
      continue
    }
    items.push({ template: match.template_id, name: match.name, qty, quality: 0 })
  }

  if (lines.length % 2 === 1 && lines.length > 0 && !lines[lines.length - 1]?.endsWith(':')) {
    warnings.push(`Line ${lines.length}: quantity has no item name`)
  }
  return { items, warnings }
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
// wrappers above (giveSolari, giveItem, renamePlayer, setSpecLevel,
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

// PERMANENT — purges the account row + dependent rows. No undo.
export function deleteAccount(accountId: number) {
  return api<WriteResult>('/api/gameplay/players/delete-account', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, confirm: 'DELETE' }),
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
    `/api/gameplay/players/journey${qs({ account_id: id, demo: demo ? 1 : undefined })}`)
}

// Full character dump - shape is intentionally loose (mirrors the reference implementation export).
export function exportPlayerData(id: number, demo?: boolean) {
  return api<{ ok: boolean; account_id: number; data: Record<string, unknown>; source: DataSource }>(
    `/api/gameplay/players/export${qs({ account_id: id, demo: demo ? 1 : undefined })}`)
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
  return api<CharXpResponse>(`/api/gameplay/players/char-xp${qs({ actor_id: id, demo: demo ? 1 : undefined })}`)
}

export interface KeystoneRow { id: string; name?: string; unlocked_at?: string }
export function getPlayerKeystones(id: number, demo?: boolean) {
  return api<{ ok: boolean; keystones: KeystoneRow[]; source: DataSource }>(
    `/api/gameplay/players/keystones${qs({ player_id: id, demo: demo ? 1 : undefined })}`)
}

export interface PlayerVehicleRow {
  id: number
  class: string
  vehicle_name?: string
  map?: string
  chassis_durability?: number
  is_recovered?: boolean
  is_backup?: boolean
}
export function getPlayerVehicles(controllerId: number, demo?: boolean) {
  return api<{ ok: boolean; vehicles: PlayerVehicleRow[]; source: DataSource }>(
    `/api/gameplay/players/vehicles${qs({ controller_id: controllerId, demo: demo ? 1 : undefined })}`)
}

export interface DungeonRunRow { dungeon_id: string; cleared: boolean; best_time_seconds?: number }
export function getPlayerDungeons(id: number, demo?: boolean) {
  return api<{ ok: boolean; runs: DungeonRunRow[]; source: DataSource }>(
    `/api/gameplay/players/dungeons${qs({ player_id: id, demo: demo ? 1 : undefined })}`)
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
  return api<PlayerIdsResponse>(`/api/gameplay/players/player-ids${qs({ actor_id: id })}`)
}

export interface PartitionRow { id: number; map: string; display_name?: string; is_blocked?: boolean }
export function getPartitions() {
  return api<{ ok: boolean; partitions: PartitionRow[]; source: DataSource }>('/api/gameplay/players/partitions')
}

export interface ContractRow { id: string; alias?: string; tag_count?: number }
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
export function giveItems(pawnId: number, items: GiveItemEntry[], allowOverflow = true) {
  return api<WriteResult>('/api/gameplay/players/give-items', {
    method: 'POST', body: JSON.stringify({ pawn_id: pawnId, items, allow_overflow: allowOverflow }),
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

// Named teleport / respawn destinations (maps + hubs) for the pickers.
export interface TeleportDestination { id: string; label: string; map: string; partition: number }
export function getTeleportDestinations() {
  return api<{ ok: boolean; destinations: TeleportDestination[]; total: number; source: string }>(
    '/api/gameplay/players/teleport-destinations')
}
// Teleport a player to a named map/hub. Offline-only on the server side.
export function teleportToLocation(accountId: number, destination: string) {
  return api<WriteResult>('/api/gameplay/players/teleport-to-location', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, destination }),
  })
}
// Add a respawn point at a named destination (non-destructive). Offline-only.
export function setRespawn(accountId: number, destination: string) {
  return api<WriteResult>('/api/gameplay/players/set-respawn', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, destination }),
  })
}

// Progression Unlock — completes the DA_FQ_ClimbTheRanks journey nodes for the
// chosen faction and writes the faction tier tags + reputation. preset picks how
// far: 'ch3_start' (tier 5) or 'rank19_eligible' (tier 19, +Landsraad nodes).
export function progressionUnlock(actorId: number, faction: string, preset: string) {
  return api<WriteResult>('/api/gameplay/players/progression-unlock', {
    method: 'POST', body: JSON.stringify({ actor_id: actorId, faction, preset }),
  })
}

export function progressionReverse(actorId: number, faction: string, preset: string) {
  return api<WriteResult>('/api/gameplay/players/progression-reverse', {
    method: 'POST', body: JSON.stringify({ actor_id: actorId, faction, preset }),
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

export function resetFaction(accountId: number, faction: 'atreides' | 'harkonnen' | 'both', deep = false) {
  return api<WriteResult>('/api/gameplay/players/faction/reset', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, faction, deep }),
  })
}

// Fresh Start (keep builds & cosmetics) — snapshot + restore-by-name.
// A truly-fresh character can only be made by the engine (delete + recreate
// in-game). DST preserves the player's unlocked building sets + cosmetics: snapshot
// them BEFORE the delete, then restore them by name onto the recreated character.
export interface FreshStartSnapshot {
  name: string
  saved_at: string
  sets: number
  pieces: number
  cosmetics: boolean
}

export function snapshotBuilds(accountId: number) {
  return api<WriteResult>('/api/gameplay/players/fresh-start/snapshot', {
    method: 'POST', body: JSON.stringify({ account_id: accountId }),
  })
}

export function getFreshStartSnapshotsPath() {
  return api<{ ok: boolean; file: string; folder: string; exists: boolean }>('/api/gameplay/players/fresh-start/snapshots-path')
}

export function getFreshStartSnapshots() {
  return api<{ ok: boolean; snapshots: FreshStartSnapshot[] }>('/api/gameplay/players/fresh-start/snapshots')
}

export function restoreBuilds(name: string) {
  return api<WriteResult>('/api/gameplay/players/fresh-start/restore', {
    method: 'POST', body: JSON.stringify({ name }),
  })
}

// Same as restoreBuilds but also marks the tutorial as completed on the
// restored character (Fresh Start + No NPE variant). Offline-only.
export function restoreBuildsSkipNpe(name: string) {
  return api<WriteResult>('/api/gameplay/players/fresh-start/restore-skip-npe', {
    method: 'POST', body: JSON.stringify({ name }),
  })
}

// Grants every skill in the bundled catalog on the character (SkillPointsSpent=1
// per skill in FLevelComponent.ModuleData). Existing entries preserved.
// Does not add unspent skill points. Offline-only.
export function grantAllSkills(accountId: number) {
  return api<WriteResult>('/api/gameplay/players/grant-all-skills', {
    method: 'POST', body: JSON.stringify({ account_id: accountId }),
  })
}

// Marks every buildable patent + crafting recipe + starter group in the bundled
// catalog as Purchased on the character's Intel terminal. Existing entries
// preserved. Does not add Intel points. Offline-only.
export function grantAllTech(accountId: number) {
  return api<WriteResult>('/api/gameplay/players/grant-all-tech', {
    method: 'POST', body: JSON.stringify({ account_id: accountId }),
  })
}

// Journey Nodes browser — reads every journey_story_node row for the account.
export interface JourneyNode {
  node_id: string
  is_complete: boolean
  is_revealed: boolean
  has_pending_reward: boolean
}
export function getPlayerJourneyNodes(accountId: number, demo?: boolean) {
  return api<{ ok: boolean; nodes: JourneyNode[]; total: number; source: DataSource }>(
    `/api/gameplay/players/journey${qs({ account_id: accountId, demo: demo ? 1 : undefined })}`)
}
export function completeJourneyNode(accountId: number, nodeId: string) {
  return api<WriteResult>('/api/gameplay/players/journey/complete', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, node_id: nodeId }),
  })
}
export function resetJourneyNode(accountId: number, nodeId: string) {
  return api<WriteResult>('/api/gameplay/players/journey/reset', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, node_id: nodeId }),
  })
}

// Unlock Trainers — skill-trainer starting quest lines.
export interface TrainerInfo { job: string; name: string; contract_count: number; skill_count: number }
export function getTrainerCatalog() {
  return api<{ ok: boolean; trainers: TrainerInfo[]; total: number; source: DataSource }>(
    '/api/gameplay/players/trainers')
}
// Per-character skill-tree ownership, used to show present values in the UI.
export interface TrainerStatus {
  job: string; name: string
  blocks_owned: number; blocks_total: number
  modules_owned: number; modules_total: number
  unlocked: boolean; is_starter: boolean
}
export function getTrainerStatus(accountId: number) {
  return api<{ ok: boolean; account_id: number; has_pawn: boolean; jobs: TrainerStatus[]; total: number; source: DataSource }>(
    `/api/gameplay/players/trainer-status?account_id=${accountId}`)
}
export function unlockTrainer(accountId: number, job: string) {
  return api<WriteResult>('/api/gameplay/players/unlock-trainer', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, job }),
  })
}
export function resetTrainerSkills(accountId: number, job: string) {
  return api<WriteResult>('/api/gameplay/players/reset-job-skills', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, job }),
  })
}

// Unlock Main Quest — main-quest story lines.
export interface MainQuestInfo { id: string; name: string; node_count: number }
export function getMainQuestCatalog() {
  return api<{ ok: boolean; main_quests: MainQuestInfo[]; total: number; source: DataSource }>(
    '/api/gameplay/players/main-quests')
}
export function unlockMainQuest(accountId: number, quest: string) {
  return api<WriteResult>('/api/gameplay/players/unlock-main-quest', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, quest }),
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

export function setStarterClass(accountId: number, job: string) {
  return api<WriteResult>('/api/gameplay/players/set-starter-class', {
    method: 'POST', body: JSON.stringify({ account_id: accountId, job }),
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
    method: 'POST', body: targetBody(t, { script_name: script }),
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