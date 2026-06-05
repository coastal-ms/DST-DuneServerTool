import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import {
  getAcl,
  saveAcl,
  getAuditLog,
  getCloudflaredStatus,
  type RemoteAcl,
  type CloudflaredStatus,
  type RemoteAuditEntry,
} from '../../api/remoteAccess'

// Settings → Remote Access card (issue #74).
//
// Surfaces the ACL editor + audit-log viewer + cloudflared status pill.
// Modeled on AppearanceCard.tsx for visual consistency. All requests go
// to /api/remote-access/* (DuneToken-gated, desktop-portal-only).
//
// "Remote enabled" is implemented as a single bit on the owner field —
// empty string = disabled, non-empty = enabled. The toggle just hides /
// restores the owner from a buffer.

export function RemoteAccessCard() {
  const [expanded, setExpanded] = useState(false)
  const [acl, setAcl] = useState<RemoteAcl | null>(null)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [savedMsg, setSavedMsg] = useState<string | null>(null)
  const [cf, setCf] = useState<CloudflaredStatus | null>(null)
  const [showAudit, setShowAudit] = useState(false)
  const [audit, setAudit] = useState<RemoteAuditEntry[] | null>(null)
  const [auditLoading, setAuditLoading] = useState(false)
  const [newAdmin, setNewAdmin] = useState('')
  const [ownerBuffer, setOwnerBuffer] = useState('')   // remembered owner while toggled off

  const load = useCallback(async () => {
    setLoading(true); setError(null)
    try {
      const [a, c] = await Promise.allSettled([getAcl(), getCloudflaredStatus()])
      if (a.status === 'fulfilled') {
        setAcl(a.value)
        if (a.value.owner) setOwnerBuffer(a.value.owner)
      } else throw a.reason
      if (c.status === 'fulfilled') setCf(c.value)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    if (expanded && !acl) void load()
  }, [expanded, acl, load])

  const enabled = !!acl?.owner

  const updateAcl = (patch: Partial<RemoteAcl>) => {
    if (!acl) return
    setAcl({ ...acl, ...patch })
  }

  const onToggleEnabled = (v: boolean) => {
    if (!acl) return
    if (v) {
      // Restoring — prefer the remembered owner; fall back to empty (user must fill in)
      updateAcl({ owner: ownerBuffer })
    } else {
      // Disabling — stash the current owner so we can restore it next toggle
      if (acl.owner) setOwnerBuffer(acl.owner)
      updateAcl({ owner: '' })
    }
  }

  const onAddAdmin = () => {
    if (!acl) return
    const e = newAdmin.trim().toLowerCase()
    if (!e || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)) {
      setError('Enter a valid email address.')
      return
    }
    if (acl.admins.includes(e) || e === acl.owner.toLowerCase()) {
      setNewAdmin('')
      return
    }
    updateAcl({ admins: [...acl.admins, e] })
    setNewAdmin('')
    setError(null)
  }

  const onRemoveAdmin = (e: string) => {
    if (!acl) return
    updateAcl({ admins: acl.admins.filter(x => x !== e) })
  }

  const onSave = async () => {
    if (!acl) return
    setSaving(true); setError(null); setSavedMsg(null)
    try {
      const saved = await saveAcl(acl)
      setAcl(saved)
      if (saved.owner) setOwnerBuffer(saved.owner)
      setSavedMsg('Saved.')
      window.setTimeout(() => setSavedMsg(null), 3000)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  const onShowAudit = async () => {
    setShowAudit(true)
    setAuditLoading(true)
    try {
      const r = await getAuditLog(50)
      setAudit(r.entries)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setAuditLoading(false)
    }
  }

  return (
    <div className="card mb-4">
      <button
        type="button"
        onClick={() => setExpanded(v => !v)}
        className="w-full flex items-center justify-between px-6 py-4 text-left hover:bg-surface-2/40 rounded-lg transition-colors"
        aria-expanded={expanded}
      >
        <div className="flex items-center gap-3">
          <Icon name={expanded ? 'ChevronDown' : 'ChevronRight'} size={16} className="text-text-dim" />
          <Icon name="Shield" size={18} className="text-text-muted" />
          <h2 className="text-lg font-semibold">Remote Access</h2>
        </div>
        <div className="flex items-center gap-2">
          {enabled
            ? <span className="pill-success text-xs">enabled</span>
            : <span className="pill-muted text-xs">disabled</span>}
          {cf?.installed
            ? <span className="pill-info text-xs">cloudflared {cf.version || 'detected'}</span>
            : <span className="pill-warning text-xs">cloudflared not detected</span>}
        </div>
      </button>

      {expanded && (
        <div className="px-6 pb-6 space-y-5">
          {loading && (
            <div className="flex items-center text-text-muted text-sm">
              <Icon name="Loader2" size={16} className="animate-spin mr-2" /> Loading…
            </div>
          )}

          {error && (
            <div className="text-sm text-danger bg-danger/10 border border-danger/40 rounded-lg px-3 py-2 flex items-start gap-2">
              <Icon name="AlertTriangle" size={14} className="mt-0.5 flex-none" />
              <div>{error}</div>
            </div>
          )}

          {acl && (
            <>
              <p className="text-sm text-text-muted">
                Lets you and 1–3 trusted admins reach a mobile-friendly subset of DST
                (Dashboard + Maps) from outside the LAN via a Cloudflare Tunnel +
                Access policy. See the{' '}
                <a
                  href="https://coastal-ms.github.io/DST-DuneServerTool/remote"
                  target="_blank"
                  rel="noreferrer"
                  className="text-accent hover:text-accent-bright underline"
                >
                  setup guide
                </a>
                {' '}for cloudflared install + tunnel + Access policy steps.
              </p>

              <label className="flex items-center gap-3 cursor-pointer">
                <input
                  type="checkbox"
                  checked={enabled}
                  onChange={e => onToggleEnabled(e.target.checked)}
                  className="h-4 w-4"
                />
                <span className="text-sm">
                  <strong>Enable remote portal</strong>
                  <span className="block text-xs text-text-dim">
                    Clears the owner field on disable — every /remote/* request is
                    refused until re-enabled.
                  </span>
                </span>
              </label>

              <div>
                <label htmlFor="ra-owner" className="block text-sm font-medium mb-1">Owner email</label>
                <input
                  id="ra-owner"
                  type="email"
                  value={acl.owner}
                  onChange={e => updateAcl({ owner: e.target.value })}
                  disabled={!enabled}
                  className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text disabled:opacity-50"
                  placeholder="you@example.com"
                />
                <p className="text-xs text-text-dim mt-1">
                  Full read + write. This MUST match the email Cloudflare Access
                  authenticates you with.
                </p>
              </div>

              <div>
                <label htmlFor="ra-hostname" className="block text-sm font-medium mb-1">Hostname (for reference)</label>
                <input
                  id="ra-hostname"
                  type="text"
                  value={acl.hostname}
                  onChange={e => updateAcl({ hostname: e.target.value })}
                  className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text"
                  placeholder="dune.example.com"
                />
                <p className="text-xs text-text-dim mt-1">
                  The hostname you mapped in Cloudflare. Stored for documentation —
                  DST doesn&apos;t configure cloudflared itself.
                </p>
              </div>

              <div>
                <label className="block text-sm font-medium mb-2">Admin allow-list</label>
                {acl.admins.length === 0 && (
                  <p className="text-xs text-text-dim mb-2">No admins yet — only the owner can sign in.</p>
                )}
                <ul className="space-y-1 mb-2">
                  {acl.admins.map(e => (
                    <li key={e} className="flex items-center justify-between bg-surface-2 border border-border rounded-lg px-3 py-2 text-sm">
                      <span className="font-mono">{e}</span>
                      <button
                        type="button"
                        onClick={() => onRemoveAdmin(e)}
                        className="btn-ghost text-xs"
                        aria-label={`Remove ${e}`}
                      >
                        <Icon name="X" size={14} />
                        Remove
                      </button>
                    </li>
                  ))}
                </ul>
                <div className="flex gap-2">
                  <input
                    type="email"
                    value={newAdmin}
                    onChange={e => setNewAdmin(e.target.value)}
                    onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); onAddAdmin() } }}
                    placeholder="trusted-admin@example.com"
                    className="flex-1 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text"
                  />
                  <button type="button" onClick={onAddAdmin} className="btn-secondary">
                    <Icon name="Plus" size={14} />
                    Add
                  </button>
                </div>
              </div>

              <div className="flex items-center gap-3 pt-2 border-t border-border">
                <button type="button" onClick={() => { void onSave() }} disabled={saving} className="btn-primary">
                  <Icon name={saving ? 'Loader2' : 'Save'} size={14} className={saving ? 'animate-spin' : ''} />
                  {saving ? 'Saving…' : 'Save changes'}
                </button>
                {savedMsg && <span className="text-sm text-success">{savedMsg}</span>}
                <div className="ml-auto">
                  <button type="button" onClick={() => { void onShowAudit() }} className="btn-ghost text-sm">
                    <Icon name="FileText" size={14} />
                    {showAudit ? 'Refresh audit log' : 'View audit log'}
                  </button>
                </div>
              </div>

              {showAudit && (
                <div className="bg-surface-2/60 border border-border rounded-lg p-3 max-h-80 overflow-auto">
                  {auditLoading && <div className="text-xs text-text-muted">Loading…</div>}
                  {!auditLoading && audit && audit.length === 0 && (
                    <div className="text-xs text-text-muted">No audit entries yet.</div>
                  )}
                  {!auditLoading && audit && audit.length > 0 && (
                    <table className="w-full text-xs font-mono">
                      <thead className="text-text-dim border-b border-border">
                        <tr>
                          <th className="text-left py-1 pr-2">When (UTC)</th>
                          <th className="text-left py-1 pr-2">Role</th>
                          <th className="text-left py-1 pr-2">Email</th>
                          <th className="text-left py-1 pr-2">Method</th>
                          <th className="text-left py-1 pr-2">Path</th>
                          <th className="text-left py-1 pr-2">Status</th>
                          <th className="text-left py-1">Note</th>
                        </tr>
                      </thead>
                      <tbody>
                        {audit.slice().reverse().map((e, i) => (
                          <tr key={i} className="border-b border-border/40 last:border-0">
                            <td className="py-1 pr-2">{e.ts}</td>
                            <td className="py-1 pr-2">{e.role}</td>
                            <td className="py-1 pr-2">{e.email}</td>
                            <td className="py-1 pr-2">{e.method}</td>
                            <td className="py-1 pr-2 break-all">{e.path}</td>
                            <td className={'py-1 pr-2 ' + (e.status.startsWith('2') ? 'text-success' : 'text-danger')}>{e.status}</td>
                            <td className="py-1 text-text-dim">{e.note}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  )}
                </div>
              )}

              <div className="text-xs text-text-dim border-t border-border pt-3">
                cloudflared status:{' '}
                {cf?.installed
                  ? <>installed at <span className="font-mono">{cf.path}</span>{cf.version && <> · v{cf.version}</>}</>
                  : <>not detected on PATH — see the setup guide for install steps.</>}
              </div>
            </>
          )}
        </div>
      )}
    </div>
  )
}
