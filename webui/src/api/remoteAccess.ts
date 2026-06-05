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
