import { api } from './client'

export interface PlatformCapability {
  id: string
  rolloutState: string
}

export interface PlatformCapabilitiesResponse {
  schemaVersion: number
  capabilities: string[]
  data: {
    registryVersion: number
    capabilities: PlatformCapability[]
  }
}

export function getPlatformCapabilities() {
  return api<PlatformCapabilitiesResponse>('/api/v1/capabilities')
}
