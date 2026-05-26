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
