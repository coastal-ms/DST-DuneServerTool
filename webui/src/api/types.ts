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
  showUdp?: boolean
  cached?: boolean
  ageSecs?: number
}

export type FuncomUpdateBadge = {
  available: boolean
  installedBuild?: string
  latestBuild?: string
  checkedAt?: string
}

export type StatusSnapshot = {
  vm: VmStatus
  bg: BattlegroupSnapshot | null
  ports: PortStatus | null
  serverName?: string | null
  funcomUpdate?: FuncomUpdateBadge | null
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
  default?: string
  help?: string
  placeholder?: string
  unit?: string
  wide?: boolean
  min?: number
  max?: number
  quoted?: boolean
  clientApply?: boolean
  // When set, this field is a scalar member of a nested struct (e.g. the
  // LandsraadSettings Data=(...) box) rather than a flat INI key. Members that
  // share a (file, section, structKey) are written into one struct line.
  structKey?: string
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
  effectiveByKey?: Record<string, string>
  managedSections: string[]
}

export type GameConfigResponse = {
  available: boolean
  source: 'live' | 'template' | 'cache'
  game: GameConfigFileBundle
  engine: GameConfigFileBundle
}

export type GameConfigClientApplyItem = {
  key: string
  label: string
  section: string
  value: string
  remove?: boolean
}

export type GameConfigClientApply = {
  path: string
  items: GameConfigClientApplyItem[]
}

// ---------- Defaults catalog -----------------------------------------------
// Per-key entry inside a default INI section. `default` = value shipped in
// DefaultGame.ini / DefaultEngine.ini; `current` = effective value after any
// User*.ini override; `overridden` flags whether the user changed it.
export type GameConfigDefaultKey = {
  key: string
  default: string
  current: string
  overridden: boolean
  isArray: boolean
  type: GameConfigFieldType
}

export type GameConfigDefaultSection = {
  name: string
  file: 'game' | 'engine'
  count: number
  overriddenCount: number
  keys: GameConfigDefaultKey[]
}

export type GameConfigDefaultsSource = {
  ns: string
  pod: string
  fetchedAt: string
}

export type GameConfigDefaultsResponse = {
  available: true
  cached: boolean
  source: GameConfigDefaultsSource
  sections: GameConfigDefaultSection[]
}

// Raw, explicit-form save item: bypasses the static schema so we can write
// any section/key the defaults browser surfaces.
export type GameConfigRawUpdate = {
  file: 'game' | 'engine'
  section: string
  key: string
  value: string
}

// Local client config (admin's own machine). `bundle`-style fields mirror
// GameConfigFileBundle so the read-only viewer can reuse the same components.
export type GameConfigClientInfo = {
  dir: string
  dirResolved: string
  path: string
  exists: boolean
  dirExists: boolean
  default: string
  raw: string
  sections: GameConfigIniSection[]
  effective: Record<string, string>
  effectiveByKey?: Record<string, string>
  managedSections: string[]
}

export type GameConfigClientApplyResult = {
  ok: boolean
  path: string
  backup: string
  created: boolean
  applied: number
  items: GameConfigClientApplyItem[]
  client: GameConfigClientInfo
}

export type GameConfigSaveResponse = {
  ok: boolean
  applied: number
  source: 'live' | 'template' | 'cache'
  game: GameConfigFileBundle
  engine: GameConfigFileBundle
  clientApply?: GameConfigClientApply
}

export type GameConfigBackupFile = {
  file: 'game' | 'engine'
  path: string
  backup: string | null
  ok: boolean
  reason?: string
}

export type GameConfigBackupResponse = {
  ok: boolean
  timestamp: string
  source: 'live' | 'template' | 'cache'
  files: GameConfigBackupFile[]
}

export type GameConfigBackupEntry = {
  file: 'game' | 'engine'
  path: string
  dir: string
  name: string
  size: number
  stamp: string
  modified: number
}

export type GameConfigBackupListResponse = {
  available: boolean
  source: 'live' | 'template' | 'cache'
  backups: GameConfigBackupEntry[]
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
  keepLast: number
  keepLastPods: number
  keepDaysPods: number
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

export type BackupDumpPod = {
  namespace: string
  name: string
  startTime: string
  phase: string
  nameTimestamp: string | null
  ageMinutes: number | null
}

export type BackupDumpPodList = {
  ok: boolean
  pods: BackupDumpPod[]
  count: number
}

export type BackupDumpPodPruneResult = {
  ok: boolean
  deleted: BackupDumpPod[]
  attempted?: BackupDumpPod[]
  kept: BackupDumpPod[]
  remaining: BackupDumpPod[]
  survivors?: BackupDumpPod[]
  message?: string
  output?: string
}
