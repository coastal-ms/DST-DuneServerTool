import type { PortalAccountRole } from './portalAccess'

const REMOTE_ALLOWED = new Set(['startup', 'start', 'restart', 'start-vm', 'reboot', 'apply-inis'])

export function canAccessCommand(
  commandName: string,
  localViewer: boolean,
  role: PortalAccountRole,
) {
  return localViewer ||
    REMOTE_ALLOWED.has(commandName) ||
    (role === 'owner' && commandName === 'update')
}
