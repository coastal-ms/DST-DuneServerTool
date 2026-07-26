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

// VM health blockers for the always-on Server Health banner. Each one is a
// specific fault the operator can act on, and every one of them used to be
// invisible while DST's own board stayed fully green: a stuck DatabaseOperation
// (no map pods are ever created), DiskPressure / a filling root volume, a
// missing game-UDP DNAT bridge after a Hyper-V host migration, per-map memory
// limits crushed by Funcom's experimental swap preset, and retained historical
// build images. Backed by the same read-only 60s-cached probe as vm-memory.
export interface VmHealthBlocker {
  id: string
  severity: 'warn' | 'critical'
  headline: string
  detail: string
  action: string
}

export interface VmHealth {
  ok: boolean
  blockers: VmHealthBlocker[]
  message?: string
  disk?: { usePct: number | null; availK: number | null; sizeK: number | null; known: boolean }
  database?: {
    phase: string
    total: number
    open: number
    stuck: { name: string; phase: string; ageMinutes: number | null }[]
  }
  mapLimits?: { swapMode: boolean; driftCount: number }
  images?: { buildCount: number; totalBytes: number }
  dnat?: { udpRules: number | null; missing: boolean }
  node?: { diskPressure: boolean; memoryPressure: boolean; ready: boolean }
}

export function getVmHealth() {
  return api<VmHealth>('/api/diagnostics/vm-health')
}
