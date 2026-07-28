// Diagnostics API — build a redacted bundle of logs the user can drag into
// their GitHub bug report. Triggered from the Help dropdown.
import { api } from './client'

export interface DiagnosticBundle {
  ok: boolean
  path: string
  sizeBytes: number
  fileCount: number
  sanitized: boolean
  warnings: string[]
}

export function buildDiagnosticBundle() {
  return api<DiagnosticBundle>('/api/diagnostics/bundle', {
    method: 'POST',
    body: '{}',
  })
}

// VM memory-pressure finding for the Server Health red banner. Read-only,
// cached 60s server-side. `ok=false` (VM unreachable / probe failed) or
// `pressure=false` (healthy) => the banner stays hidden.
export interface VmMemoryPressure {
  ok: boolean
  pressure: boolean
  severity: 'none' | 'warn' | 'critical'
  headline: string
  warnings: string[]
  message?: string
  maxRestarts?: number
  oomKills?: number
  mem?: {
    availK: number | null
    totalK: number | null
    availPct: number | null
    swapZero: boolean
    lowAvailable: boolean
  }
}

export function getVmMemoryPressure() {
  return api<VmMemoryPressure>('/api/diagnostics/vm-memory')
}

// VM facts for the Database page's info card. This GET is deliberately an
// OBSERVATION feed, not a health score: disk usage, retained Funcom build
// images, per-map memory limits and the UDP rule count are reported as plain
// numbers with no verdict attached, because deployments differ and Funcom
// changes its own defaults between patches.
//
// `faults` is the short exception: states the system ITSELF reports as broken
// (an unfinished database operation while the battlegroup says DATABASE is not
// Ready, Kubernetes' own DiskPressure condition, or a public IP configured with
// zero game UDP rules while pods are running). None of those can be true on a
// healthy server.
export interface VmFault {
  id: string
  headline: string
  detail: string
  action: string
}

export interface VmHealth {
  ok: boolean
  faults: VmFault[]
  message?: string
  disk?: { usePct: number | null; availK: number | null; sizeK: number | null; known: boolean }
  database?: {
    phase: string
    total: number
    open: number
    activeCount: number
    failedCount: number
    active: { name: string; phase: string; ageMinutes: number | null }[]
    failed: { name: string; phase: string; ageMinutes: number | null }[]
    stuck: { name: string; phase: string; ageMinutes: number | null }[]
  }
  mapLimits?: { entries: { map: string; limit: string; reference: string }[]; known: boolean }
  images?: { buildCount: number; totalBytes: number }
  dnat?: { udpRules: number | null; missing: boolean }
  node?: { diskPressure: boolean; memoryPressure: boolean; ready: boolean }
  swap?: { totalK: number | null; active: boolean }
}

export function getVmHealth() {
  return api<VmHealth>('/api/diagnostics/vm-health')
}

export interface ImageCleanupResult {
  ok: boolean
  complete: boolean
  message: string
  removedCount: number
  removedIds: string[]
  failedIds: string[]
  estimatedBytes: number
  reclaimedK: number
  activeBuilds: number[]
  preservedBuilds: number[]
  disk?: { usePct: number | null; availK: number | null; sizeK: number | null; known: boolean }
}

export function cleanupOldFuncomImages() {
  return api<ImageCleanupResult>('/api/diagnostics/cleanup-old-images', {
    method: 'POST',
    body: '{}',
  })
}

export interface DatabaseOperationCleanupResult {
  ok: boolean
  complete: boolean
  message: string
  removedCount: number
  removedNames: string[]
  failedNames: string[]
}

export function cleanupFailedDatabaseOperations() {
  return api<DatabaseOperationCleanupResult>('/api/diagnostics/cleanup-failed-database-operations', {
    method: 'POST',
    body: '{}',
  })
}
