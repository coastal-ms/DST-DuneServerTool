import { useState, useEffect, type FormEvent } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { api } from '../api/client'
import type { ConfigResponse } from '../api/types'
import { checkForUpdate, installUpdate, type UpdateCheck } from '../api/update'
import { publishUpdateCheck } from '../hooks/useUpdateCheck'
import { fmtToolVersion } from '../format'
import { AppearanceCard } from './settings/AppearanceCard'
import { RemoteAccessCard } from './settings/RemoteAccessCard'

const FIELDS: {
  key: string
  label: string
  placeholder: string
  help?: string
  type?: 'text' | 'select'
  browse?: { mode: 'folder' | 'file'; filter?: string }
}[] = [
  { key: 'SteamPath',    label: 'Steam install path',
    placeholder: 'C:\\Program Files (x86)\\Steam\\steamapps\\common\\Dune Awakening Self-Hosted Server',
    help: 'Where Funcom installed the dedicated server.',
    browse: { mode: 'folder' } },
  { key: 'SshKey',       label: 'SSH key path',
    placeholder: 'C:\\Users\\<you>\\AppData\\Local\\DuneAwakeningServer\\sshKey',
    help: 'Private key used to SSH into the dune-awakening VM.',
    browse: { mode: 'file', filter: 'SSH key (sshKey;*.pem;*.key)|sshKey;*.pem;*.key|All files (*.*)|*.*' } },
  { key: 'WindowsUser',  label: 'Windows username',
    placeholder: 'your-windows-username',
    help: 'Used for desktop shortcut creation.' },
  { key: 'PortCheckMode',label: 'Port-check mode', placeholder: 'builtin',
    type: 'select',
    help: 'builtin = yougetsignal.com w/ canyouseeme.org fallback · yougetsignal = primary only (no fallback) · canyouseeme = canyouseeme.org only · custom = your own URL · disabled = off' },
  { key: 'PortCheckUrlTemplate', label: 'Port-check URL template',
    placeholder: 'https://example.com/check?ip={ip}&port={port}&protocol={protocol}',
    help: 'Used when mode is "custom". Tokens: {ip} {port} {protocol}' },
]

export function Settings() {
  const [cfg, setCfg] = useState<ConfigResponse | null>(null)
  const [values, setValues] = useState<Record<string, string>>({})
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [browsing, setBrowsing] = useState<string | null>(null)

  // "Generate new SSH key" — runs the rotate-ssh-key command, waits for it to
  // finish, then propagates the fresh key everywhere DST uses it.
  const [sshRotating, setSshRotating] = useState(false)
  const [sshRotateMsg, setSshRotateMsg] = useState<string | null>(null)
  const [openingBat, setOpeningBat] = useState(false)
  const [batMsg, setBatMsg] = useState<string | null>(null)
  async function onOpenBattlegroupBat() {
    if (!window.confirm('Open Funcom\'s original battlegroup.bat?\n\nThis launches the battlegroup.bat in the root of your Steam install folder in an ELEVATED (administrator) window. Approve the Windows UAC prompt if it appears.')) return
    setOpeningBat(true)
    setBatMsg(null)
    setError(null)
    try {
      const r = await api<{ ok: boolean; path?: string; message?: string }>(
        '/api/config/open-battlegroup-bat',
        { method: 'POST' },
      )
      setBatMsg(r.message ?? (r.ok ? 'Opened battlegroup.bat.' : 'Could not open battlegroup.bat.'))
      if (!r.ok && r.message) setError(r.message)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setOpeningBat(false)
    }
  }
  async function onRotateSshKey() {
    if (!window.confirm('Generate a NEW SSH key?\n\nThis regenerates the key and authorizes it on the dune-awakening VM. The VM must be running.\n\nA console window will open and ask for the \'dune\' user\'s password — you MUST type it there to authorize the new key on the VM. If you close that prompt without entering the password, DST will be locked out of the server until you re-run this. The console will tell you if authorization succeeded.')) return
    setSshRotating(true)
    setSshRotateMsg(null)
    setError(null)
    try {
      const r = await api<{ ok: boolean; rotated: boolean; message?: string }>(
        '/api/config/rotate-ssh-key',
        { method: 'POST' },
      )
      setSshRotateMsg(r.message ?? (r.ok ? 'SSH key rotated.' : 'Rotation did not complete.'))
      if (!r.ok && r.message) setError(r.message)
      // Reload config so the form reflects any path changes.
      try {
        const cfgOut = await api<ConfigResponse>('/api/config')
        setCfg(cfgOut)
        setValues({ ...cfgOut.values })
      } catch { /* non-fatal */ }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setSshRotating(false)
    }
  }


  async function onBrowse(field: { key: string; label: string; browse?: { mode: 'folder' | 'file'; filter?: string } }) {
    if (!field.browse) return
    setBrowsing(field.key)
    setError(null)
    try {
      const r = await api<{ ok: boolean; cancelled: boolean; path: string }>('/api/browse-path', {
        method: 'POST',
        body: JSON.stringify({
          mode: field.browse.mode,
          current: values[field.key] ?? '',
          title: field.browse.mode === 'folder' ? `Select ${field.label}` : `Select ${field.label} file`,
          filter: field.browse.filter ?? 'All files (*.*)|*.*',
        }),
      })
      if (r.ok && !r.cancelled && r.path) {
        setValues(v => ({ ...v, [field.key]: r.path }))
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBrowsing(null)
    }
  }

  const [saved, setSaved] = useState<string | null>(null)

  // Update-check card state
  const [updCheck, setUpdCheck] = useState<UpdateCheck | null>(null)
  const [updChecking, setUpdChecking] = useState(false)
  const [updInstalling, setUpdInstalling] = useState(false)
  const [updMsg, setUpdMsg] = useState<string | null>(null)
  const [updErr, setUpdErr] = useState<string | null>(null)

  // Collapsible-card state — both update cards start minimized.
  const [updExpanded, setUpdExpanded] = useState(false)

  async function onCheckUpdate() {
    setUpdChecking(true)
    setUpdErr(null)
    setUpdMsg(null)
    try {
      const res = await checkForUpdate({ force: true })
      setUpdCheck(res)
      // Share the result so the global UpdateBanner reflects it immediately.
      publishUpdateCheck(res)
    } catch (e) {
      setUpdErr(e instanceof Error ? e.message : String(e))
    } finally {
      setUpdChecking(false)
    }
  }

  async function onInstallUpdate() {
    setUpdInstalling(true)
    setUpdErr(null)
    setUpdMsg(null)
    try {
      const r = await installUpdate()
      if (r.launched) {
        setUpdMsg(`Installer launched — upgrading to ${fmtToolVersion(r.toVersion)}. The portal will go offline briefly, then the new version will relaunch.`)
      } else {
        setUpdErr(r.reason ?? 'Installer did not launch.')
      }
    } catch (e) {
      setUpdErr(e instanceof Error ? e.message : String(e))
    } finally {
      setUpdInstalling(false)
    }
  }

  useEffect(() => {
    void (async () => {
      try {
        const out = await api<ConfigResponse>('/api/config')
        setCfg(out)
        setValues({ ...out.values })
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e))
      } finally {
        setLoading(false)
      }
    })()
    // Same idea for the Dune Server self-updater — populate the collapsed
    // header pills (current/latest) without forcing a fresh GitHub hit.
    void (async () => {
      try {
        setUpdChecking(true)
        const res = await checkForUpdate({ force: false })
        setUpdCheck(res)
        publishUpdateCheck(res)
      } catch (e) {
        setUpdErr(e instanceof Error ? e.message : String(e))
      } finally {
        setUpdChecking(false)
      }
    })()
  }, [])

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setSaving(true)
    setError(null)
    setSaved(null)
    try {
      const out = await api<{ ok: boolean; complete: boolean; values: Record<string, string> }>(
        '/api/config',
        { method: 'PUT', body: JSON.stringify({ values }) },
      )
      setValues(out.values)
      setCfg(c => c ? { ...c, complete: out.complete, values: out.values, exists: true } : c)
      setSaved('Saved.')
      window.setTimeout(() => setSaved(null), 3000)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setSaving(false)
    }
  }

  if (loading) {
    return (
      <>
        <PageHeader title="Settings" icon="Settings" description="Tool configuration (dune-server.config)." />
        <div className="card p-8 text-text-muted">Loading…</div>
      </>
    )
  }

  return (
    <>
      <PageHeader
        title="Settings"
        icon="Settings"
        description="Tool configuration — written to dune-server.config next to dune-server.bat."
        actions={
          cfg && (
            <span className={cfg.complete ? 'pill-success' : 'pill-warning'}>
              <Icon name={cfg.complete ? 'CheckCircle2' : 'AlertTriangle'} size={12} />
              {cfg.complete ? 'Complete' : 'Incomplete'}
            </span>
          )
        }
      />

      {error && (
        <div className="card p-3 mb-4 border-danger/40 bg-danger/10 text-danger text-sm flex items-center gap-2">
          <Icon name="AlertCircle" size={14} /> {error}
        </div>
      )}
      {saved && (
        <div className="card p-3 mb-4 border-success/40 bg-success/10 text-success text-sm flex items-center gap-2">
          <Icon name="CheckCircle2" size={14} /> {saved}
        </div>
      )}

      {/* --- Update check card (top, collapsible) ------------------------ */}
      <div className="card mb-4">
        <button
          type="button"
          onClick={() => setUpdExpanded(v => !v)}
          className="w-full flex items-center justify-between px-6 py-4 text-left hover:bg-surface-2/40 rounded-lg transition-colors"
          aria-expanded={updExpanded}
        >
          <div className="flex items-center gap-3">
            <Icon name={updExpanded ? 'ChevronDown' : 'ChevronRight'} size={16} className="text-text-dim" />
            <Icon name="Download" size={18} className="text-text-muted" />
            <h2 className="text-lg font-semibold">Dune Server Tool updates</h2>
          </div>
          <div className="flex items-center gap-2">
            {updCheck && (
              <>
                <span className="pill-muted text-xs">{fmtToolVersion(updCheck.currentVersion)}</span>
                {updCheck.available && updCheck.latestVersion && (
                  <span className="pill-warning text-xs">{fmtToolVersion(updCheck.latestVersion)} available</span>
                )}
                {!updCheck.available && !updCheck.error && updCheck.latestVersion && (
                  <span className="pill-success text-xs">up to date</span>
                )}
              </>
            )}
          </div>
        </button>

        {updExpanded && (
          <div className="px-6 pb-5 space-y-3">
            <div className="flex items-center justify-between">
              <p className="text-sm text-text-dim">
                Checks GitHub releases for newer versions. Installs silently — Start Menu icon keeps working, your config in <span className="font-mono">%APPDATA%\DuneServer</span> is preserved.
              </p>
              <button type="button" onClick={onCheckUpdate} disabled={updChecking} className="btn-secondary ml-3 shrink-0">
                <Icon name={updChecking ? 'Loader2' : 'RefreshCw'} size={15} className={updChecking ? 'animate-spin' : ''} />
                {updChecking ? 'Checking…' : 'Check now'}
              </button>
            </div>

            {updCheck && (
              <div className="text-sm border-t border-border pt-3 flex flex-wrap items-center gap-3">
                <span className="pill-muted">Current · {fmtToolVersion(updCheck.currentVersion)}</span>
                {updCheck.latestVersion && (
                  <span className={updCheck.available ? 'pill-warning' : 'pill-success'}>
                    Latest · {fmtToolVersion(updCheck.latestVersion)}
                  </span>
                )}
                {updCheck.releaseUrl && (
                  <a href={updCheck.releaseUrl} target="_blank" rel="noreferrer" className="text-xs underline text-text-muted hover:text-text">
                    release notes
                  </a>
                )}
                {updCheck.available && (updCheck.installable ?? true) && (
                  <button
                    type="button"
                    onClick={onInstallUpdate}
                    disabled={updInstalling}
                    className="btn-primary ml-auto"
                  >
                    <Icon name={updInstalling ? 'Loader2' : 'Download'} size={15} className={updInstalling ? 'animate-spin' : ''} />
                    {updInstalling ? 'Installing…' : `Update to ${fmtToolVersion(updCheck.latestVersion)}`}
                  </button>
                )}
                {updCheck.available && updCheck.installable === false && (
                  <span className="text-xs text-warning ml-auto flex items-center gap-1.5">
                    <Icon name="AlertCircle" size={14} />
                    Newer version available, but this release has no installer attached. Use the{' '}
                    <a
                      href={updCheck.releaseUrl ?? `https://github.com/coastal-ms/DST-DuneServerTool/releases/tag/${updCheck.tagName ?? ''}`}
                      target="_blank"
                      rel="noreferrer"
                      className="underline hover:text-text"
                    >
                      release page
                    </a>
                    .
                  </span>
                )}
                {!updCheck.available && !updCheck.error && (
                  <span className="text-xs text-text-dim ml-auto">You're on the latest version.</span>
                )}
                {updCheck.error && (
                  <span className="text-xs text-danger ml-auto">Check failed: {updCheck.error}</span>
                )}
              </div>
            )}

            {updMsg && (
              <div className="text-sm border-t border-border pt-3 text-success flex items-center gap-2">
                <Icon name="CheckCircle2" size={14} /> {updMsg}
              </div>
            )}
            {updErr && (
              <div className="text-sm border-t border-border pt-3 text-danger flex items-center gap-2">
                <Icon name="AlertCircle" size={14} /> {updErr}
              </div>
            )}
          </div>
        )}
      </div>

      <AppearanceCard />

      <RemoteAccessCard />

      <form onSubmit={onSubmit} className="card p-6 space-y-5">
        {FIELDS.map(f => (
          <div key={f.key}>
            <label className="block text-sm font-medium mb-1.5">
              {f.label}
              <span className="ml-2 text-[10px] font-mono text-text-dim uppercase tracking-wider">{f.key}</span>
            </label>
            {f.type === 'select' ? (
              <select
                value={values[f.key] ?? ''}
                onChange={e => setValues(v => ({ ...v, [f.key]: e.target.value }))}
                className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
              >
                <option value="">(default: builtin)</option>
                <option value="builtin">builtin — yougetsignal + canyouseeme fallback (TCP only)</option>
                <option value="yougetsignal">yougetsignal.com — primary only, no fallback (TCP only)</option>
                <option value="canyouseeme">canyouseeme.org — alternate provider (TCP only)</option>
                <option value="custom">custom — your own URL template</option>
                <option value="disabled">disabled — no port checks</option>
              </select>
            ) : f.browse ? (
              <>
                {f.key === 'SteamPath' && (
                  <button
                    type="button"
                    onClick={() => void onOpenBattlegroupBat()}
                    disabled={openingBat}
                    title="Open Funcom's battlegroup.bat (in the Steam install root) in an elevated window"
                    className="btn-secondary mb-2"
                  >
                    <Icon name={openingBat ? 'Loader2' : 'SquareTerminal'} size={15} className={openingBat ? 'animate-spin' : ''} />
                    {openingBat ? 'Opening…' : 'Funcom BattleGroup.bat'}
                  </button>
                )}
                <div className="flex items-stretch gap-2">
                <input
                  type="text"
                  value={values[f.key] ?? ''}
                  placeholder={f.placeholder}
                  onChange={e => setValues(v => ({ ...v, [f.key]: e.target.value }))}
                  className="flex-1 min-w-0 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text font-mono text-sm
                             placeholder:text-text-dim focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
                />
                <button
                  type="button"
                  onClick={() => void onBrowse(f)}
                  disabled={browsing !== null}
                  title={f.browse.mode === 'folder' ? 'Browse for folder…' : 'Browse for file…'}
                  className="btn-secondary shrink-0"
                >
                  <Icon
                    name={browsing === f.key ? 'Loader2' : (f.browse.mode === 'folder' ? 'FolderOpen' : 'FileSearch')}
                    size={15}
                    className={browsing === f.key ? 'animate-spin' : ''}
                  />
                  Browse
                </button>
                {f.key === 'SshKey' && (
                  <button
                    type="button"
                    onClick={() => void onRotateSshKey()}
                    disabled={sshRotating}
                    title="Generate a new SSH key and copy it everywhere DST uses it"
                    className="btn-secondary shrink-0"
                  >
                    <Icon name={sshRotating ? 'Loader2' : 'KeyRound'} size={15} className={sshRotating ? 'animate-spin' : ''} />
                    {sshRotating ? 'Rotating…' : 'Generate new'}
                  </button>
                )}
                </div>
              </>
            ) : (
              <input
                type="text"
                value={values[f.key] ?? ''}
                placeholder={f.placeholder}
                onChange={e => setValues(v => ({ ...v, [f.key]: e.target.value }))}
                className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text font-mono text-sm
                           placeholder:text-text-dim focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
              />
            )}
            {f.help && <p className="mt-1 text-xs text-text-dim">{f.help}</p>}
            {f.key === 'SshKey' && sshRotateMsg && (
              <p className="mt-1 text-xs text-success flex items-center gap-1.5">
                <Icon name="CheckCircle2" size={13} /> {sshRotateMsg}
              </p>
            )}
            {f.key === 'SteamPath' && batMsg && (
              <p className="mt-1 text-xs text-success flex items-center gap-1.5">
                <Icon name="CheckCircle2" size={13} /> {batMsg}
              </p>
            )}
          </div>
        ))}

        <div className="pt-2 flex items-center justify-between border-t border-border">
          <div className="text-xs text-text-dim font-mono break-all">
            {cfg?.path}
          </div>
          <button type="submit" disabled={saving} className="btn-primary">
            <Icon name={saving ? 'Loader2' : 'Save'} size={15} className={saving ? 'animate-spin' : ''} />
            {saving ? 'Saving…' : 'Save'}
          </button>
        </div>
      </form>

    </>
  )
}
