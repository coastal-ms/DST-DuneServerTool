export const PORTAL_HANDOFF_REQUEST_EVENT = 'dst:portal-handoff-request'

export function requestPortalHandoff() {
  window.dispatchEvent(new Event(PORTAL_HANDOFF_REQUEST_EVENT))
}
