import { api } from './client'

export interface PortalAccount {
  id: string
  username: string
  role: 'owner' | 'admin'
  enabled: boolean
  mustChangePassword: boolean
  gameCharacterId: string
  gameCharacterLabel: string
}

export interface PortalAuthStatus {
  accountLoginEnabled: boolean
  authenticated: boolean
  mustChangePassword: boolean
  account: PortalAccount | null
}

export function getPortalAuthStatus(): Promise<PortalAuthStatus> {
  return api('/api/portal-auth/status')
}

export function loginPortal(username: string, password: string): Promise<PortalAuthStatus> {
  return api('/api/portal-auth/login', {
    method: 'POST',
    body: JSON.stringify({ username, password }),
  })
}

export function changePortalPassword(currentPassword: string, newPassword: string): Promise<{ ok: boolean }> {
  return api('/api/portal-auth/change-password', {
    method: 'POST',
    body: JSON.stringify({ currentPassword, newPassword }),
  })
}

export function logoutPortal(): Promise<{ ok: boolean }> {
  return api('/api/portal-auth/logout', { method: 'POST' })
}
