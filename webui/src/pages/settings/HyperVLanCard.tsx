// Settings card: Hyper-V over LAN — toggle whether DST manages a VM on a remote
// Hyper-V host on the local network, without re-running the Setup Wizard.
//
// This is the post-setup surface for the same routing toggle the wizard's
// "Hyper-V over LAN" step exposes. It reads/writes VmHostMode + HyperVHostIp via
// /api/setup/hyperv-lan and tests connectivity via /api/setup/hyperv-lan/test.
// Turning it OFF restores the local VM and fully bypasses the remote path.

import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { ApiError } from '../../api/client'
import { getHyperVLan, saveHyperVLan, testHyperVLan, getHyperVLanCredential, saveHyperVLanCredential, deleteHyperVLanCredential, type HyperVLanTest } from '../../api/setup'

export function HyperVLanCard() {
  const [open, setOpen] = useState(false)
  const [hostIp, setHostIp] = useState('')
  const [enabled, setEnabled] = useState(false)
  const [savedMode, setSavedMode] = useState<'local' | 'lan'>('local')
  const [loading, setLoading] = useState(false)
  const [testing, setTesting] = useState(false)
  const [saving, setSaving] = useState(false)
  const [test, setTest] = useState<HyperVLanTest | null>(null)
  const [msg, setMsg] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)

  // Credential: hidden behind "using saved credential for X" once one exists
  // and matches hostIp. "Change" reveals fields to replace it; "Remove"
  // deletes it outright (never done implicitly by disabling LAN mode).
  const [credUser, setCredUser] = useState('')
  const [credPassword, setCredPassword] = useState('')
  const [savedCredUser, setSavedCredUser] = useState<string | null>(null)
  const [editingCred, setEditingCred] = useState(false)
  const [removing, setRemoving] = useState(false)
  const [confirmRemove, setConfirmRemove] = useState(false)

  const loadCredInfo = useCallback(async (ip: string) => {
    if (!ip) { setSavedCredUser(null); setEditingCred(true); return }
    try {
      const info = await getHyperVLanCredential(ip)
      const matches = info.exists && info.matchesHost
      setSavedCredUser(matches ? info.user : null)
      setEditingCred(!matches)
    } catch {
      setSavedCredUser(null)
    }
  }, [])

  const load = useCallback(async () => {
    setLoading(true); setErr(null)
    try {
      const s = await getHyperVLan()
      setHostIp(s.hostIp ?? '')
      setEnabled(s.mode === 'lan')
      setSavedMode(s.mode)
      await loadCredInfo(s.hostIp ?? '')
    } catch (e) {
      setErr(e instanceof ApiError ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [loadCredInfo])

  useEffect(() => { if (open) void load() }, [open, load])

  // A candidate host must pass a live test before it can be enabled. An already-
  // enabled host stays enabled without re-testing (it was verified when saved).
  const canEnable = !!test?.ok || savedMode === 'lan'

  const runTest = useCallback(async () => {
    const ip = hostIp.trim()
    if (!ip) { setErr('Enter the Hyper-V host IP first.'); return }
    const usingNewCred = editingCred && credUser.trim() && credPassword
    if (editingCred && !usingNewCred) { setErr("Enter the host's administrator username and password first."); return }
    setTesting(true); setErr(null); setMsg(null); setTest(null)
    try {
      const result = usingNewCred
        ? await testHyperVLan(ip, credUser.trim(), credPassword)
        : await testHyperVLan(ip)
      setTest(result)
      if (result.ok && usingNewCred) {
        await saveHyperVLanCredential(ip, credUser.trim(), credPassword)
        setCredPassword('')
        await loadCredInfo(ip)
      }
    } catch (e) { setErr(e instanceof ApiError ? e.message : String(e)) }
    finally { setTesting(false) }
  }, [hostIp, editingCred, credUser, credPassword, loadCredInfo])

  const save = useCallback(async () => {
    const ip = hostIp.trim()
    if (enabled && !ip) { setErr('Enter the Hyper-V host IP first.'); return }
    if (enabled && !canEnable) { setErr('Test the connection successfully before enabling Hyper-V over LAN.'); return }
    setSaving(true); setErr(null); setMsg(null)
    try {
      const r = await saveHyperVLan(enabled ? 'lan' : 'local', ip)
      setSavedMode(r.mode === 'lan' ? 'lan' : 'local')
      setMsg(r.mode === 'lan'
        ? `Saved. DST will manage the VM on ${r.hostIp} over the LAN.`
        : 'Saved. DST is using the local Hyper-V VM (LAN routing off). The saved credential is kept in case you re-enable it.')
    } catch (e) {
      setErr(e instanceof ApiError ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }, [hostIp, enabled, canEnable])

  const removeCredential = useCallback(async () => {
    setRemoving(true); setErr(null); setMsg(null)
    try {
      await deleteHyperVLanCredential()
      setSavedCredUser(null)
      setEditingCred(true)
      setConfirmRemove(false)
      setMsg('Saved Hyper-V host credential removed.')
    } catch (e) {
      setErr(e instanceof ApiError ? e.message : String(e))
    } finally {
      setRemoving(false)
    }
  }, [])

  const tone = test == null ? 'text-text-dim' : test.ok ? 'text-success' : 'text-danger'
  const tIcon = test == null ? 'Info' : test.ok ? 'CheckCircle2' : 'AlertTriangle'

  return (
    <div className="card mb-4">
      <button
        type="button"
        onClick={() => setOpen(o => !o)}
        className="w-full flex items-center justify-between gap-3 p-6 text-left"
      >
        <div className="flex items-center gap-2 min-w-0">
          <Icon name="Network" size={18} className="text-text-muted shrink-0" />
          <div className="min-w-0">
            <div className="font-medium">Hyper-V over LAN</div>
            <div className="text-sm text-text-muted truncate">
              {savedMode === 'lan'
                ? `Managing the VM on ${hostIp || 'a LAN host'} over the network.`
                : 'Manage a VM that runs on a separate Hyper-V host on your network.'}
            </div>
          </div>
        </div>
        <Icon name={open ? 'ChevronUp' : 'ChevronDown'} size={18} className="text-text-muted shrink-0" />
      </button>

      {open && (
        <div className="px-6 pb-6 space-y-4">
          <div className="rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm text-text-dim flex items-start gap-2">
            <Icon name="AlertTriangle" size={16} className="text-warning mt-0.5 shrink-0" />
            <span>
              <span className="font-medium text-warning">Prerequisite:</span> the host's Hyper-V PowerShell Remoting
              (WinRM) must be reachable from this PC. DST uses an explicit administrator credential for that host
              below — it does not need to match the Windows account DST itself runs as. The VM must already be
              installed on that host and named <span className="font-mono">dune-awakening</span>.
            </span>
          </div>

          {err && (
            <div className="rounded-lg border border-danger/40 bg-danger/10 p-3 text-sm text-danger flex items-start gap-2">
              <Icon name="CircleX" size={16} className="mt-0.5 shrink-0" />
              <span>{err}</span>
            </div>
          )}

          {loading ? (
            <p className="text-sm text-text-dim italic">Loading…</p>
          ) : (
            <>
              <label className="flex flex-col gap-1 text-sm">
                <span className="font-medium">Hyper-V host IP (or name)</span>
                <input
                  type="text"
                  value={hostIp}
                  onChange={e => { setHostIp(e.target.value); setTest(null); void loadCredInfo(e.target.value.trim()) }}
                  disabled={saving}
                  spellCheck={false}
                  placeholder="192.168.1.50"
                  className="px-3 py-2 rounded-lg bg-surface-2 border border-border text-text font-mono text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
                />
                <span className="text-xs text-text-dim">
                  The <strong>host</strong> address, not the VM's — DST finds the VM's own IP through the host.
                </span>
              </label>

              <div>
                <span className="font-medium text-sm">Host administrator credential</span>
                {!editingCred && savedCredUser ? (
                  <div className="mt-1 flex items-center justify-between gap-2 rounded-lg border border-border bg-surface-2 p-3">
                    <span className="text-sm text-text-dim">
                      Using saved credential for <span className="font-mono text-text">{savedCredUser}</span>
                    </span>
                    <div className="flex gap-2 shrink-0">
                      <button type="button" className="btn-secondary" onClick={() => { setEditingCred(true); setTest(null) }}>Change</button>
                      {!confirmRemove ? (
                        <button type="button" className="btn-secondary" onClick={() => setConfirmRemove(true)}>Remove</button>
                      ) : (
                        <>
                          <button type="button" className="btn-secondary text-danger" onClick={() => void removeCredential()} disabled={removing}>
                            {removing ? 'Removing…' : 'Confirm remove'}
                          </button>
                          <button type="button" className="btn-secondary" onClick={() => setConfirmRemove(false)}>Cancel</button>
                        </>
                      )}
                    </div>
                  </div>
                ) : (
                  <div className="mt-1 grid grid-cols-1 md:grid-cols-2 gap-2">
                    <input
                      type="text"
                      value={credUser}
                      onChange={e => { setCredUser(e.target.value); setTest(null) }}
                      spellCheck={false}
                      placeholder="HOST\Administrator"
                      className="px-3 py-2 rounded-lg bg-surface-2 border border-border text-text font-mono text-sm"
                    />
                    <input
                      type="password"
                      value={credPassword}
                      onChange={e => { setCredPassword(e.target.value); setTest(null) }}
                      placeholder="Password"
                      className="px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm"
                    />
                    <p className="md:col-span-2 text-xs text-text-dim">
                      The host's own administrator account — in a workgroup this is routinely a <strong>different</strong>{' '}
                      account than the one DST itself runs as. Use <span className="font-mono">HOST\username</span>.
                    </p>
                  </div>
                )}
              </div>

              <div className="flex flex-wrap gap-2">
                <button type="button" className="btn-secondary" onClick={() => void runTest()} disabled={testing || saving}>
                  <Icon name={testing ? 'Loader2' : 'Plug'} size={14} className={testing ? 'animate-spin' : ''} />
                  {testing ? 'Testing…' : 'Test'}
                </button>
              </div>

              {test && (
                <div className="rounded-lg border border-border bg-surface-2 p-3 text-sm flex items-start gap-2">
                  <Icon name={tIcon} size={16} className={`${tone} mt-0.5 shrink-0`} />
                  <div className="min-w-0">
                    <div className={`font-medium ${tone}`}>
                      {test.ok ? (test.vmFound ? 'Connected — VM found' : 'Connected — VM not installed yet') : 'Could not connect'}
                    </div>
                    <div className="text-xs text-text-dim mt-0.5 break-words">{test.reason}</div>
                  </div>
                </div>
              )}

              <label className={`flex items-start gap-2 rounded-lg border p-3 ${canEnable ? 'border-border bg-surface-2 cursor-pointer' : 'border-border/60 bg-surface-2/50 opacity-60 cursor-not-allowed'}`}>
                <input
                  type="checkbox"
                  className="mt-0.5"
                  checked={enabled}
                  disabled={saving || (!canEnable && !enabled)}
                  onChange={e => setEnabled(e.target.checked)}
                />
                <span className="text-sm text-text">
                  Route all VM commands to this LAN host
                  <span className="block text-xs text-text-dim mt-0.5">
                    On: DST manages the remote VM (status, start/stop, RAM) over the LAN using the credential above.
                    Off: back to the local VM on this PC — fully bypasses the LAN path, but keeps the saved credential
                    for next time. {!canEnable && !enabled && 'Run a successful test first.'}
                  </span>
                </span>
              </label>

              <div className="flex flex-wrap gap-2">
                <button type="button" onClick={() => void load()} disabled={loading || saving} className="btn-secondary">
                  <Icon name={loading ? 'Loader2' : 'RefreshCw'} size={14} className={loading ? 'animate-spin' : ''} />
                  Refresh
                </button>
                <button type="button" onClick={() => void save()} disabled={loading || saving} className="btn-primary">
                  <Icon name={saving ? 'Loader2' : 'Save'} size={14} className={saving ? 'animate-spin' : ''} />
                  {saving ? 'Saving…' : 'Save'}
                </button>
              </div>

              {msg && (
                <div className="rounded-lg border border-success/40 bg-success/10 p-3 text-sm text-success flex items-start gap-2">
                  <Icon name="CircleCheck" size={16} className="mt-0.5 shrink-0" />
                  <span>{msg}</span>
                </div>
              )}
            </>
          )}
        </div>
      )}
    </div>
  )
}
