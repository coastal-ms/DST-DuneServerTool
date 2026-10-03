import { api } from './client'

export interface PortalManagedAccount {
  id: string
  username: string
  role: 'owner' | 'admin' | 'player'
  enabled: boolean
  mustChangePassword: boolean
  locallyVerified: boolean
  gameCharacterId: string
  gameCharacterLabel: string
  createdAt: string
  lastLoginAt: string
}

export interface PortalAccountsState {
  accountLoginEnabled: boolean
  nativeAppsBlockedInAccountMode: boolean
  accounts: PortalManagedAccount[]
  roles: Array<'owner' | 'admin' | 'player'>
}

export function getPortalAccounts(): Promise<PortalAccountsState> {
  return api('/api/remote-access/portal-accounts')
}

export function createPortalAccount(input: {
  username: string
  role: 'owner' | 'admin' | 'player'
  password?: string
  gameCharacterId?: string
  gameCharacterLabel?: string
}): Promise<{ account: PortalManagedAccount; oneTimePassword: string }> {
  return api('/api/remote-access/portal-accounts', { method: 'POST', body: JSON.stringify(input) })
}

export function updatePortalAccount(id: string, input: Partial<Pick<PortalManagedAccount, 'enabled' | 'role' | 'gameCharacterId' | 'gameCharacterLabel'>>): Promise<{ account: PortalManagedAccount }> {
  return api(`/api/remote-access/portal-accounts/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify(input) })
}

export function deletePortalAccount(id: string): Promise<{ ok: boolean }> {
  return api(`/api/remote-access/portal-accounts/${encodeURIComponent(id)}`, { method: 'DELETE' })
}

export function resetPortalAccountPassword(id: string): Promise<{ ok: boolean; oneTimePassword: string }> {
  return api(`/api/remote-access/portal-accounts/${encodeURIComponent(id)}/reset-password`, { method: 'POST' })
}

export function revokePortalAccountSessions(id: string): Promise<{ ok: boolean }> {
  return api(`/api/remote-access/portal-accounts/${encodeURIComponent(id)}/revoke-sessions`, { method: 'POST' })
}

export function verifyPortalOwner(username: string, password: string): Promise<{ ok: boolean }> {
  return api('/api/remote-access/portal-accounts/verify-owner', { method: 'POST', body: JSON.stringify({ username, password }) })
}

export function setPortalAccountMode(enabled: boolean, acknowledgeNativeAppRetirement = false): Promise<{ accountLoginEnabled: boolean }> {
  return api('/api/remote-access/portal-account-mode', {
    method: 'PUT',
    body: JSON.stringify({ enabled, acknowledgeNativeAppRetirement }),
  })
}
