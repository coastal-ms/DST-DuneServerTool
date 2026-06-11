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
  running: boolean
  configured?: boolean
  uptime?: number
  last_list_tick?: string
  last_buy_tick?: string
  listing_count?: number
  balance?: number
  error_count?: number
  error?: string
  source?: DataSource
}

export interface BotConfig {
  enabled: boolean
  list_tick_interval: number
  buy_tick_interval: number
  buy_threshold: number
  max_buys_per_tick: number
  listings_per_grade: number
  rarity_multipliers: Record<string, number>
  vendor_multipliers: Record<string, number>
  grade_multipliers: number[]
  disabled_items: string[]
  configured?: boolean
  source?: DataSource
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

export interface MarketItemsQuery {
  search?: string
  category?: string
  tier?: string
  rarity?: string
  owner?: string
  page?: number
  limit?: number
  demo?: boolean
}

export function getMarketItems(q: MarketItemsQuery = {}) {
  return api<MarketItemsResponse>(`/api/gameplay/market/items${qs({
    search: q.search, category: q.category, tier: q.tier, rarity: q.rarity,
    owner: q.owner, page: q.page, limit: q.limit, demo: q.demo ? 1 : undefined,
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
