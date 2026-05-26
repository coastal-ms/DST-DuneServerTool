// Links API — VM-hosted web URLs (File Browser, Battlegroup Director)
import { api } from './client'

export interface DuneLink {
  available: boolean
  url: string | null
  reason: string | null
}

export interface LinksResponse {
  vmRunning: boolean
  bgRunning: boolean
  fileBrowser: DuneLink
  director: DuneLink
}

export function getLinks(opts: { force?: boolean } = {}) {
  const qs = opts.force ? '?force=1' : ''
  return api<LinksResponse>(`/api/links${qs}`)
}
