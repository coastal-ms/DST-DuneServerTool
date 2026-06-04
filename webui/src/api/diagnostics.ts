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
