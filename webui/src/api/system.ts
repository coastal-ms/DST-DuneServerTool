import { api } from './client'

export interface InstallLocation {
  ok: boolean
  path: string
  installed: boolean
}

export function getInstallLocation() {
  return api<InstallLocation>('/api/system/install-location')
}

export function openInstallLocation() {
  return api<{ ok: boolean; path: string }>('/api/system/install-location/open', {
    method: 'POST',
  })
}
