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
