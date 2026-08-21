// Local-only management client for the Settings → Remote Access card.
// Targets /api/remote-access/*  (NOT /api/remote/*) — these endpoints are
// gated by DuneToken (same as the rest of the desktop portal), and are
// intentionally unreachable through the Cloudflare tunnel.
//
// Issue #74 (v11.1.0).

import { api } from './client'

export interface RemoteAcl {
  owner: string
  admins: string[]
  hostname: string
  cloudflareTeamDomain: string
  cloudflareAudience: string
}

export interface PortalManagedAccount {
  id: string
  username: string
  role: 'owner' | 'admin'
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
  accounts: PortalManagedAccount[]
  roles: Array<'owner' | 'admin'>
}

export function getPortalAccounts(): Promise<PortalAccountsState> {
  return api('/api/remote-access/portal-accounts')
}

export function createPortalAccount(input: {
  username: string
  role: 'owner' | 'admin'
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

export function setPortalAccountMode(enabled: boolean): Promise<{ accountLoginEnabled: boolean }> {
  return api('/api/remote-access/portal-account-mode', { method: 'PUT', body: JSON.stringify({ enabled }) })
}

export interface CloudflaredStatus {
  installed: boolean
  path: string
  version: string
}

export interface RemoteAuditEntry {
  ts: string
  role: string
  email: string
  method: string
  path: string
  status: string
  note: string
  raw: string
}

export function getAcl(): Promise<RemoteAcl> {
  return api<RemoteAcl>('/api/remote-access/acl')
}

export function saveAcl(acl: RemoteAcl): Promise<RemoteAcl> {
  return api<RemoteAcl>('/api/remote-access/acl', {
    method: 'PUT',
    body: JSON.stringify(acl),
  })
}

export function getAuditLog(lines = 50): Promise<{ entries: RemoteAuditEntry[]; count: number }> {
  return api(`/api/remote-access/audit-log?lines=${encodeURIComponent(String(lines))}`)
}

export function getCloudflaredStatus(): Promise<CloudflaredStatus> {
  return api<CloudflaredStatus>('/api/remote-access/cloudflared-status')
}

export interface MobileServiceTokenStatus {
  configured: boolean
  clientId: string
}

export function getMobileServiceToken(): Promise<MobileServiceTokenStatus> {
  return api<MobileServiceTokenStatus>('/api/remote-access/mobile-service-token')
}

// Save (both fields) or clear (both empty) the mobile Cloudflare Access service
// token. The secret is write-only: the GET route never echoes it back.
export function saveMobileServiceToken(clientId: string, clientSecret: string): Promise<MobileServiceTokenStatus> {
  return api<MobileServiceTokenStatus>('/api/remote-access/mobile-service-token', {
    method: 'PUT',
    body: JSON.stringify({ clientId, clientSecret }),
  })
}
