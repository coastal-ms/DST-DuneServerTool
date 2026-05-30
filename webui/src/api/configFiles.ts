// Local DST config-file store API. Mirrors the backend ConfigFiles routes:
// collects sshKey / dune-server.config / dune-admin config.yaml into
// %APPDATA%\DuneServer\configFiles and re-dumps the sshKey into the dune-admin
// folder. The "repull" button on the Settings page calls syncConfigFiles.
import { api } from './client'

export interface ConfigFileManifestEntry {
  name: string
  source: string | null
  dest: string | null
  copied: boolean
  status: 'copied' | 'skipped' | 'missing' | 'error'
  message: string | null
  mtime: string | null
}

export interface ConfigFilesStatus {
  dir: string
  exists: boolean
  files: { name: string; size: number; mtime: string }[]
}

export interface ConfigFilesSyncResult {
  ok: boolean
  dir: string
  sshKeyDir: string | null
  files: ConfigFileManifestEntry[]
  message: string | null
}

export function getConfigFiles(): Promise<ConfigFilesStatus> {
  return api<ConfigFilesStatus>('/api/config-files')
}

export function syncConfigFiles(): Promise<ConfigFilesSyncResult> {
  return api<ConfigFilesSyncResult>('/api/config-files/sync', { method: 'POST' })
}
