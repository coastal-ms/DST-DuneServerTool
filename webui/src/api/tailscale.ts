// Local-only client for the Tailscale page. Targets /api/tailscale/* which is
// token-gated (same as the rest of the desktop portal) and read-only — the
// backend exposes no mutating tailscale commands by design.

import { api } from './client'

export interface TailscaleNode {
  id: string
  name: string
  dnsName: string
  os: string
  tailscaleIPs: string[]
  online: boolean
  exitNode: boolean
  lastSeen: string
}

export interface TailscaleStatus {
  available: boolean
  installed: boolean
  path: string
  backendState: string
  tailnetName: string
  self: TailscaleNode | null
  peers: TailscaleNode[]
  adminUrl: string
  error: string
}

// PowerShell's ConvertTo-Json collapses single-element arrays/objects, so
// normalize anything that should be a list back into one.
function asArray<T>(v: unknown): T[] {
  if (Array.isArray(v)) return v as T[]
  if (v === null || v === undefined) return []
  return [v as T]
}

function normalizeNode(n: TailscaleNode | null): TailscaleNode | null {
  if (!n) return null
  return { ...n, tailscaleIPs: asArray<string>(n.tailscaleIPs) }
}

export async function getTailscaleStatus(): Promise<TailscaleStatus> {
  const r = await api<TailscaleStatus>('/api/tailscale/status')
  return {
    ...r,
    self: normalizeNode(r.self),
    peers: asArray<TailscaleNode>(r.peers).map(p => normalizeNode(p)!).filter(Boolean),
  }
}

export function openTailscaleConsole(): Promise<{ ok: boolean; url: string }> {
  return api<{ ok: boolean; url: string }>('/api/tailscale/open-console', { method: 'POST' })
}
