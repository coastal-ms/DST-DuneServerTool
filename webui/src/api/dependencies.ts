// System dependency detection + install-offer API.
//
// Backs the reusable "DST needs <X> — install it?" popup. The backend detects
// which build-time tools (go / git / node) are present and can install a
// missing one via winget (DST runs elevated). See app/server/routes/System.ps1
// and app/server/lib/Dependencies.ps1.
import { api } from './client'

export interface SystemDependency {
  name: string
  display: string
  command: string
  wingetId: string
  reason: string
  found: boolean
  path: string | null
}

export interface SystemDependenciesResult {
  ok: boolean
  wingetAvailable: boolean
  dependencies: SystemDependency[]
  missing: string[]
  allPresent: boolean
}

export interface DependencyInstallStart {
  ok: boolean
  status: 'running' | 'success' | 'failed'
  name?: string
  display?: string
  wingetId?: string
  alreadyInstalled?: boolean
  path?: string | null
  error?: string
  logFile?: string
  statusFile?: string
  pid?: number
}

export interface DependencyInstallStatus {
  ok: boolean
  status: 'idle' | 'running' | 'success' | 'failed'
  name?: string
  display?: string
  wingetId?: string
  found: boolean
  path: string | null
  error?: string
  logFile?: string
  logTail?: string
  exitCode?: number
}

/** Probe which build dependencies are installed. Pass a subset of names to
 *  narrow (e.g. ['go','git','node']); omit to check all. */
export function getDependencies(names?: string[]) {
  const qs = names && names.length ? `?names=${encodeURIComponent(names.join(','))}` : ''
  return api<SystemDependenciesResult>(`/api/system/dependencies${qs}`)
}

/** Kick off a detached `winget install` for one dependency. Returns immediately;
 *  poll dependencyInstallStatus() until status is terminal. */
export function installDependency(name: string) {
  return api<DependencyInstallStart>(`/api/system/dependencies/install`, {
    method: 'POST',
    body: JSON.stringify({ name }),
  })
}

/** Poll the install status for one dependency. */
export function dependencyInstallStatus(name: string) {
  return api<DependencyInstallStatus>(
    `/api/system/dependencies/install-status?name=${encodeURIComponent(name)}`,
  )
}
