// Setup Wizard API — preflight checks + config summary
import { api } from './client'

export interface PreflightCheck {
  key: string
  label: string
  ok: boolean
  severity: 'ok' | 'warning' | 'error' | 'info'
  detail: string
  fix?: string
  freeGB?: number
}

export interface PreflightResult {
  ok: boolean
  checks: PreflightCheck[]
  errorCount: number
  warningCount: number
}

export interface SetupConfigSummary {
  windowsUser: string | null
  sshKey: string | null
  sshKeyExists: boolean
  steamPath: string | null
  portCheckMode: string | null
  vmName: string
  sshPort: number
}

export function getPreflight() { return api<PreflightResult>('/api/setup/preflight') }
export function getSetupConfig() { return api<SetupConfigSummary>('/api/setup/config') }
