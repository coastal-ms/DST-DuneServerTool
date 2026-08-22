import { usePortalAuth } from './PortalAuthGate'
import { isLocalViewer } from '../util/viewer'

export type PortalAccountRole = 'owner' | 'admin' | null

export function resolvePortalAccess(
  localViewer: boolean,
  accountLoginEnabled: boolean,
  role: PortalAccountRole,
) {
  return {
    canAccessOwnerSurfaces: localViewer || !accountLoginEnabled || role === 'owner',
    canAccessSetup: localViewer,
  }
}

export function usePortalAccess() {
  const portalAuth = usePortalAuth()
  const role = portalAuth?.status.account?.role ?? null
  return resolvePortalAccess(
    isLocalViewer(),
    portalAuth?.status.accountLoginEnabled === true,
    role,
  )
}
