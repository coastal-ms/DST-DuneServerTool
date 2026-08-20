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
  map:        string
  phase:      string
  ready:      string
  players:    string
  age:        string
  sietchName?: string
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
  // True for [ConsoleVariables] entries, which only take effect after a
  // battlegroup restart rebuilds the startup command — unlike game INI keys
  // that apply on save.
  consoleVar?: boolean
  // When set, this field is a scalar member of a nested struct (e.g. the
  // LandsraadSettings Data=(...) box) rather than a flat INI key. Members that
  // share a (file, section, structKey) are written into one struct line.
  structKey?: string
  options?: GameConfigFieldOption[]
  /** Experimental controls only: which themed card they belong on. */
  group?: string
  /** Experimental controls only: 'Confirmed' | 'Unconfirmed'. */
  status?: string
  /** Experimental Lab metadata derived from the recovered binary catalog. */
  source?: 'Dune' | 'Engine'
  scope?: string
  risk?: 'experimental' | 'diagnostic' | 'high' | 'critical'
}

export type GameConfigCategory = {
  category: string
  fields: GameConfigField[]
}

export type GameConfigSchemaResponse = {
  schema: GameConfigCategory[]
}

export type GameConfigExperimentalCategoriesResponse = {
  categories: Array<{ category: string; count: number }>
}

export type GameConfigExperimentalCategoryResponse = {
  category: string
  fields: GameConfigField[]
}

export type GameConfigExperimentalSearchResponse = {
  query: string
  fields: GameConfigField[]
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

export type GameConfigPodReloadResponse = {
  ok: boolean
  noop?: boolean
  found: number
  restarted: number
  pods: string[]
  message: string
}

export type DeepDesertPvpInstance = {
  map: 'DeepDesert_1'
  partitionId: number
  dimension: number
  phase: string
  ready: boolean
  gamePort: number
  serverDisplayName: string
  pvpEnabled: boolean
}

// State of the Deep Desert base-backup guard: whether DST keeps stored base
// backups excluded from Funcom's Coriolis season-end wipe.
export type BaseBackupGuardState = {
  ok: boolean
  // false when the VM/DB can't be reached, so applied/functionFound are unknown
  available: boolean
  enabled: boolean
  functionFound: boolean
  applied: boolean
  changed?: boolean
  message?: string
}

export type DeepDesertPvpState = {
  ok: boolean
  enabled: boolean
  forceAll: boolean
  selectedPartitionIds: number[]
  inactiveSelectedPartitionIds: number[]
  staleSelectedPartitionIds: number[]
  instances: DeepDesertPvpInstance[]
  message?: string
  restart?: {
    ok: boolean
    noop?: boolean
    podsFound?: number
    podsDeleted?: number
    message?: string
  }
}

export type GameConfigClientApplyItem = {
  file: 'game' | 'engine'
  key: string
  label: string
  section: string
  value: string
  structKey?: string
  remove?: boolean
}

export type GameConfigClientApply = {
  path: string
  paths?: { game: string; engine: string }
  items: GameConfigClientApplyItem[]
}

// ---------- Defaults catalog -----------------------------------------------
// Per-key entry inside a default INI section. `default` = value shipped in
// DefaultGame.ini / DefaultEngine.ini; `current` = effective value after any
// User*.ini override; `overridden` flags whether the user changed it.
// For array rows (isArray=true), `prefix` carries the original line's INI
// prefix ('+' array-append, '-' array-remove) so the array editor can
// rebuild the correct +/-key= lines on save.
export type GameConfigDefaultKey = {
  key: string
  default: string
  current: string
  overridden: boolean
  isArray: boolean
  prefix?: '+' | '-' | ''
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
// any section/key the defaults browser surfaces. Either `value` (scalar
// update) or `arrayLines` (rewrite the full +/-key= entry set for an array
// row) is supplied — not both. An empty `arrayLines` array means "remove
// every +/-key= line for this key" (equivalent to arrayRemove on the wire).
export type GameConfigRawUpdate = {
  file: 'game' | 'engine'
  section: string
  key: string
  value?: string
  arrayLines?: string[]
}

export type GameConfigClientFileInfo = {
  file: 'game' | 'engine'
  path: string
  exists: boolean
  raw: string
  sections: GameConfigIniSection[]
  effective: Record<string, string>
  effectiveByKey?: Record<string, string>
  managedSections: string[]
}

// Legacy top-level file fields continue to represent Game.ini. `game` and
// `engine` expose both client files for file-aware views and comparisons.
export type GameConfigClientInfo = GameConfigClientFileInfo & {
  dir: string
  dirResolved: string
  dirExists: boolean
  default: string
  engineEnabled: boolean
  game: GameConfigClientFileInfo
  engine: GameConfigClientFileInfo
}

export type GameConfigClientEngineGateResult = {
  ok: boolean
  enabled: boolean
  removed: number
  client: GameConfigClientInfo
}

export type GameConfigClientApplyResult = {
  ok: boolean
  path: string
  paths?: { game: string; engine: string }
  files?: Partial<Record<'game' | 'engine', {
    file: 'game' | 'engine'
    path: string
    created: boolean
    applied: number
  }>>
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
  landsraadGoalApply?: {
    ok: boolean
    skipped?: boolean
    term_id?: number
    goal_amount?: number
    updated?: number
    message?: string
    error?: string
  }
}

// Land-claim (staking unit) extension timer — dedicated card/endpoint.
export type LandclaimTimerServerState = {
  available: boolean
  enabled: boolean
  seconds: string
  formattedOk: boolean
  path?: string
  reason?: string
  error?: string
}

export type LandclaimTimerClientState = {
  exists: boolean
  dirExists: boolean
  path: string
  dir: string
  enabled: boolean
  seconds: string
  formattedOk: boolean
}

export type LandclaimTimerState = {
  server: LandclaimTimerServerState
  client: LandclaimTimerClientState
  clientBlock: string
}

export type LandclaimTimerSaveResponse = {
  ok: boolean
  enabled: boolean
  seconds: string
  result: {
    ok: boolean
    server: { ok: boolean; path?: string; applied?: boolean; reason?: string }
    client: { ok: boolean; path?: string; applied?: boolean; reason?: string }
  }
  server: LandclaimTimerServerState
  client: LandclaimTimerClientState
  clientBlock: string
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

// In-game !commands: which are enabled, their cooldowns, and where DST listens.
export type ChatCommandSetting = {
  enabled: boolean
  cooldownSeconds: number
  maxQty?: number
}

export type ChatTeleportBookmark = {
  name: string
  key: string
  map: string
  partition: number
  dimension: number
  x: number
  y: number
  z: number
  capturedFrom: string
  capturedAt: string
}

export type PendingChatTeleportCapture = {
  name: string
  key: string
  pawnId: number
  funcomId: string
  playerName: string
  token: string
  map: string
  partition: number
  dimension: number
  armedAt: string
  expiresAt: string
}

export type ChatCommandsState = {
  ok: boolean
  enabled: boolean
  replyTitle: string
  channels: string[]
  commands: Record<string, ChatCommandSetting>
  packages?: string[]      // kit names available to !kit, from the package store
  teleports?: ChatTeleportBookmark[]
  pendingTeleportCapture?: PendingChatTeleportCapture | null
  pollSeconds?: number
  pollChoices?: number[]
  ready?: boolean
  readyMessage?: string
  lastSeenAt?: string
}

export type WelcomeBackGrant = {
  at: string
  name: string
  daysAway: number
  package: string
  ok: boolean
  message?: string
}

export type WelcomeBackState = {
  ok: boolean
  enabled: boolean
  packageId: string
  daysAway: number
  announce: boolean
  packages?: Array<{ id: string; name: string; itemCount: number }>
  recent?: WelcomeBackGrant[]
  tracked?: number
  seeded?: number
  lastRunAt?: string
  lastError?: string
  ready?: boolean
  readyMessage?: string
}

export type SpicefieldType = {
  spicefieldTypeId: number
  mapName: string         // raw DB name, e.g. "HaggaBasin", "DeepDesert"
  mapId?: string          // normalised to the battlegroup's id, e.g. "Survival_1"
  fieldType: string       // e.g. "Small", "Medium", "Large"
  dimensionIndex: number  // instance index — a map can have more than one
  maxActive: number
  maxPrimed: number
  currentActive: number   // read-only — maintained by the game
  currentPrimed: number   // read-only — maintained by the game
  isSpawningActive: boolean
  spawnWeight: number     // float
  // Whether this (map, dimension) is currently running or kept warm by a pin.
  // Rows survive in the DB long after an instance stops existing, so these
  // drive what the dashboard shows.
  partitionLive?: boolean
  partitionPinned?: boolean
  partitionActive?: boolean
}

export type SpicefieldsResponse = {
  available: boolean
  rows: SpicefieldType[]
  // False when the battlegroup could not be read, in which case callers should
  // show every row rather than hide real data on a transient failure.
  partitionGate?: boolean
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
  total?: number
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
  ownerKind?: string
  ownerName?: string
  ownerIsController?: boolean
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
