// API response shapes (kept in sync with app/server/routes/*.ps1)

export type VmStatus = {
  exists: boolean
  name: string
  state: string
  running: boolean
  ip: string | null
  uptime: number
  error?: string
}

export type BgState = 'running' | 'stopped' | 'starting' | 'stopping' | 'updating' | 'unknown'

export type BattlegroupSnapshot = {
  available: boolean
  reason?: string
  output?: string
  exitCode?: number
  state?: BgState
  vm?: VmStatus
}

export type PortResult = {
  port: number
  protocol: 'TCP' | 'UDP'
  label: string
  status: 'open' | 'closed' | 'unknown' | 'udp-skip'
}

export type PortStatus = {
  mode: 'builtin' | 'custom' | 'disabled'
  publicIp: string | null
  results: PortResult[]
  cached?: boolean
  ageSecs?: number
}

export type StatusSnapshot = {
  vm: VmStatus
  bg: BattlegroupSnapshot | null
  ports: PortStatus | null
  ts: string
}

export type ConfigResponse = {
  path: string
  exists: boolean
  complete: boolean
  keys: string[]
  values: Record<string, string>
}

export type Command = {
  section: 'VM' | 'Battlegroup' | 'Tools'
  key: string
  name: string
  mode: 'InApp' | 'Console'
  requires: 'none' | 'exists' | 'running'
  disabledWhen?: string
  external: boolean
  desc: string
  available: boolean
  reason: string
}

export type CommandsResponse = {
  state: {
    vmExists: boolean
    vmRunning: boolean
    bgState: BgState
    vm: VmStatus
  }
  order: string[] | null
  commands: Command[]
}

// ---------- Characters ------------------------------------------------------

export type CharacterListEntry = { id: number; name: string }
export type CharactersListResponse = {
  available: boolean
  reason?: string
  characters: CharacterListEntry[]
}

export type CharStatDef = {
  key: string
  label: string
  field: 'properties' | 'gas_attributes'
  path: string
  min: number
  max: number
  step: number
  default: number
}
export type CurrencyDef     = { id: number; label: string }
export type WritableInvType = { type: number; label: string }
export type CharacterDefs = {
  stats: CharStatDef[]
  specTracks: string[]
  specKeystonePrefixes: string[]
  currencies: CurrencyDef[]
  writableInvTypes: WritableInvType[]
  stackLimits: Record<string, number>
  defaultStackLimit: number
  equipmentCategoryPrefixes: string[]
}

export type CatalogItem = { templateId: string; name: string; category: string }
export type ItemCatalog = {
  meta: { total: number; source: string | null; scraped: string | null; error?: string }
  categories: string[]
  items: CatalogItem[]
}

export type SpecTrack    = { trackType: string; level: number; xp: number }
export type CurrencyRow  = { currencyId: number; balance: number }
export type FactionRepRow = { factionId: number; factionName: string; reputation: number }
export type FactionRow   = { id: number; name: string }
export type InventoryRow = { id: number; inventoryType: number; maxItemCount: number }
export type ItemRow = {
  id: number
  inventoryId: number
  templateId: string
  stackSize: number
  positionIndex: number
  inventoryType: number
}

export type CharacterDetail = {
  id: number
  stats: Record<string, number | string>
  specializations: { tracks: SpecTrack[] }
  economy: {
    controllerId: number
    currency: CurrencyRow[]
    factionRep: FactionRepRow[]
    factions: FactionRow[]
  }
  cosmetics: string[]
  inventory: {
    inventories: InventoryRow[]
    items: ItemRow[]
  }
}
