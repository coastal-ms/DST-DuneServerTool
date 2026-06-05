// Remote portal API client — for /api/remote/* endpoints reached through the
// Cloudflare tunnel. Mirrors the shape of api/client.ts but reads the per-
// launch DuneToken from window.__duneRemoteToken (injected into index.html
// by HttpServer.ps1's Write-DuneFile when the path starts with /remote/).
//
// Issue #74 (v11.1.0). Defense-in-depth: requests carry BOTH the CF Access
// header (set automatically by Cloudflare on the edge) AND the X-Dune-Token
// header so a same-Windows-box attacker forging the CF header still fails.

declare global {
  interface Window {
    __duneRemoteToken?: string
  }
}

export class RemoteApiError extends Error {
  status: number
  body?: unknown
  constructor(status: number, message: string, body?: unknown) {
    super(message)
    this.status = status
    this.body = body
  }
}

function getRemoteToken(): string {
  return (typeof window !== 'undefined' && window.__duneRemoteToken) || ''
}

async function remoteFetch<T = unknown>(
  path: string,
  init: RequestInit = {},
): Promise<T> {
  const headers = new Headers(init.headers)
  headers.set('Accept', 'application/json')
  if (init.body && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json')
  }
  const token = getRemoteToken()
  if (token) headers.set('X-Dune-Token', token)

  const res = await fetch(path, { ...init, headers })
  const text = await res.text()
  let body: unknown = undefined
  if (text) {
    try { body = JSON.parse(text) } catch { body = text }
  }
  if (!res.ok) {
    const msg = (typeof body === 'object' && body && 'error' in body)
      ? String((body as { error: unknown }).error)
      : `${res.status} ${res.statusText}`
    throw new RemoteApiError(res.status, msg, body)
  }
  return body as T
}

// ---- Types ----

export interface RemoteVmStatus {
  exists: boolean
  running: boolean
  state?: string
  ip?: string
}

export interface RemoteStatusResponse {
  vm: RemoteVmStatus | null
  bg: Record<string, unknown> | null
  ports: {
    mode: string
    publicIp: string | null
    results: Array<{ port: number; protocol: string; label: string; status: string }>
  } | null
  publicIp: string | null
  ts: string
  role: 'owner' | 'admin'
  email: string
}

export interface RemoteMapEntry {
  key: string
  label: string
  ok: boolean
  running: boolean
  present: boolean
  totalReplicas: number
  playersOnline: number | null
  hasDisabledPart: boolean
  missingPartitionBinding: boolean
  stuckDedicatedScaling: boolean
  error: string | null
}

export interface RemoteMapsResponse {
  maps: RemoteMapEntry[]
  ts: string
  role: 'owner' | 'admin'
  email: string
}

export interface RemoteBackupEntry {
  name: string
  path: string
  sizeBytes: number
  mtimeEpoch: number
  mtimeIso: string
  ageMinutes: number | null
}

export interface RemoteBackupsResponse {
  recent: RemoteBackupEntry[]
  dumpDirSize: string
  ts: string
  role: 'owner' | 'admin'
  email: string
}

export interface RemoteActionResult {
  ok: boolean
  message?: string
  [k: string]: unknown
}

// ---- Reads ----

export function getRemoteStatus(): Promise<RemoteStatusResponse> {
  return remoteFetch<RemoteStatusResponse>('/api/remote/status')
}

export function getRemoteMaps(): Promise<RemoteMapsResponse> {
  return remoteFetch<RemoteMapsResponse>('/api/remote/maps')
}

export function getRemoteBackups(): Promise<RemoteBackupsResponse> {
  return remoteFetch<RemoteBackupsResponse>('/api/remote/backups')
}

// ---- Writes ----

export function spinUpMap(key: string): Promise<RemoteActionResult> {
  return remoteFetch<RemoteActionResult>(`/api/remote/maps/spin-up/${encodeURIComponent(key)}`, { method: 'POST' })
}

export function spinDownMap(key: string): Promise<RemoteActionResult> {
  return remoteFetch<RemoteActionResult>(`/api/remote/maps/spin-down/${encodeURIComponent(key)}`, { method: 'POST' })
}

export function fixPartitions(): Promise<RemoteActionResult> {
  return remoteFetch<RemoteActionResult>('/api/remote/maps/fix-partitions', { method: 'POST' })
}
