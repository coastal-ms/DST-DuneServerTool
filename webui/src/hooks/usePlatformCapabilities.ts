import { useMemo } from 'react'
import { useApi } from './useApi'
import type { PlatformCapabilitiesResponse } from '../api/platform'

export function usePlatformCapabilities() {
  const result = useApi<PlatformCapabilitiesResponse>('/api/v1/capabilities')
  const capabilityIds = useMemo(
    () => new Set(result.data?.data.capabilities.map(capability => capability.id) ?? []),
    [result.data],
  )

  return {
    ...result,
    hasCapability: (id: string) => capabilityIds.has(id),
  }
}
