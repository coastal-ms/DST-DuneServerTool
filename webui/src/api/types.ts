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

export type BgInfo = {
  status:   string
  database: string
  gateway:  string
  director: string
  uptime:   string
}

export type BgGameServer = {
  map:     string
  phase:   string
  ready:   string
  players: string
  age:     string
}

export type BattlegroupSnapshot = {
  available: boolean
  reason?: string
  output?: string
  exitCode?: number
  state?: BgState
  vm?: VmStatus
  name?: string
  info?: BgInfo | null
  gameServers?: BgGameServer[]
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
  section: 'VM' | 'Battlegroup' | 'Tools'  // original catalogue hint — not used for layout
  key: string
  name: string
  label: string
  mode: 'InApp' | 'Console'
  requires: 'none' | 'exists' | 'running'
  disabledWhen?: string
  external: boolean
  desc: string
  available: boolean
  reason: string
}

// v6.1.10+ layout: three sections, each with a user-renamable label and an
// ordered array of command names. Sections are sized by their contents — they
// grow and shrink as the user drags commands between them.
export type CommandsResponse = {
  state: {
    vmExists: boolean
    vmRunning: boolean
    bgState: BgState
    vm: VmStatus
  }
  sectionNames: [string, string, string]
  sections: [string[], string[], string[]]
  commands: Command[]
}

// ---------- GameConfig ------------------------------------------------------

export type GameConfigFieldOption = { value: string; label: string }

export type GameConfigFieldType =
  | 'float' | 'int' | 'bool' | 'bool01' | 'boolLower' | 'string' | 'select'

export type GameConfigField = {
  section: string
  key: string
  file: 'game' | 'engine'
  type: GameConfigFieldType
  label: string
  help?: string
  placeholder?: string
  unit?: string
  wide?: boolean
  min?: number
  max?: number
  quoted?: boolean
  options?: GameConfigFieldOption[]
}

export type GameConfigCategory = {
  category: string
  fields: GameConfigField[]
}

export type GameConfigSchemaResponse = {
  schema: GameConfigCategory[]
}

export type GameConfigIniKey = {
  key: string
  value: string
  isArray: boolean
  raw: string
}

export type GameConfigIniSection = {
  name: string
  managed: boolean
  keys: GameConfigIniKey[]
}

export type GameConfigFileBundle = {
  path: string
  raw: string
  sections: GameConfigIniSection[]
  effective: Record<string, string>
  managedSections: string[]
}

export type GameConfigResponse = {
  available: boolean
  source: 'live' | 'template' | 'cache'
  game: GameConfigFileBundle
  engine: GameConfigFileBundle
}

export type GameConfigSaveResponse = {
  ok: boolean
  applied: number
  source: 'live' | 'template' | 'cache'
  game: GameConfigFileBundle
  engine: GameConfigFileBundle
}

// ---------- Spicefield types (dune.spicefield_types) ------------------------

export type SpicefieldType = {
  spicefieldTypeId: number
  mapName: string         // e.g. "HaggaBasin", "DeepDesert"
  fieldType: string       // e.g. "Small", "Medium", "Large"
  dimensionIndex: number
  maxActive: number
  maxPrimed: number
  currentActive: number   // read-only — maintained by the game
  currentPrimed: number   // read-only — maintained by the game
  isSpawningActive: boolean
  spawnWeight: number     // float
}

export type SpicefieldsResponse = {
  available: boolean
  rows: SpicefieldType[]
}

export type SpicefieldSaveResponse = {
  ok: boolean
  row: SpicefieldType
}

// ---------- Database --------------------------------------------------------

export type DbTable = {
  schema: string
  name: string
  kind: string  // r=table, v=view, m=mat-view, f=foreign, p=partitioned
}

export type DbInfo = {
  available: boolean
  version: string
  database: string
  user: string
  now: string
  tables: DbTable[]
}

export type SqlOkResult = {
  ok: true
  columns: string[]
  rows: (string | null)[][]
  rowCount: number
  truncated: boolean
  message: string
  durationMs: number
  readOnly: boolean
  maxRows: number
}

export type SqlErrResult = {
  ok: false
  error: string
  raw?: string
  durationMs: number
  readOnly: boolean
}

export type SqlResult = SqlOkResult | SqlErrResult

// ---------- Backup schedule -------------------------------------------------

export type BackupPreset = {
  id: string
  label: string
}

export type BackupSchedule = {
  enabled: boolean
  preset: string
  retentionDays: number
  vmTimezone: string
  vmNowUtc: string
  crondRunning: boolean
  crondStatusRaw: string
  hasUnmanagedBackupLines: boolean
  managedBlockLooksTampered: boolean
  inferredFromUnmanaged: boolean
  presets: BackupPreset[]
}

export type BackupFile = {
  path: string
  sizeBytes: number
  mtimeEpoch: number
  mtimeIso: string
}

export type BackupHistory = {
  recent: BackupFile[]
  logTail: string
  dumpDirPath: string
  dumpDirSize: string
  logPath: string
}
