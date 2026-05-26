import { useState, useEffect, type FormEvent } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { api } from '../api/client'
import type { ConfigResponse } from '../api/types'
import { checkForUpdate, installUpdate, type UpdateCheck } from '../api/update'

const FIELDS: { key: string; label: string; placeholder: string; help?: string; type?: 'text' | 'select' }[] = [
  { key: 'SteamPath',    label: 'Steam install path',
    placeholder: 'C:\\Program Files (x86)\\Steam\\steamapps\\common\\Dune Awakening Self-Hosted Server',
    help: 'Where Funcom installed the dedicated server.' },
  { key: 'SshKey',       label: 'SSH key path',
    placeholder: 'C:\\Users\\<you>\\AppData\\Local\\DuneAwakeningServer\\sshKey',
    help: 'Private key used to SSH into the dune-awakening VM.' },
  { key: 'DuneAdminExe', label: 'dune-admin.exe',
    placeholder: 'C:\\path\\to\\dune-admin.exe',
    help: 'Optional — only needed if you launch dune-admin from this tool.' },
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
  const [saved, setSaved] = useState<string | null>(null)

  // Update-check card state
  const [updCheck, setUpdCheck] = useState<UpdateCheck | null>(null)
  const [updChecking, setUpdChecking] = useState(false)
  const [updInstalling, setUpdInstalling] = useState(false)
  const [updMsg, setUpdMsg] = useState<string | null>(null)
  const [updErr, setUpdErr] = useState<string | null>(null)

  async function onCheckUpdate() {
    setUpdChecking(true)
    setUpdErr(null)
    setUpdMsg(null)
    try {
      setUpdCheck(await checkForUpdate({ force: true }))
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
        setUpdMsg(`Installer launched — upgrading to v${r.toVersion}. The portal will go offline briefly, then the new version will relaunch.`)
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
        setValues(out.values)
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e))
      } finally {
        setLoading(false)
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

      {/* --- Update check card -------------------------------------------- */}
      <div className="card p-6 mt-6 space-y-3">
        <div className="flex items-center justify-between">
          <div>
            <h2 className="text-lg font-semibold flex items-center gap-2">
              <Icon name="Download" size={18} className="text-text-muted" />
              Updates
            </h2>
            <p className="text-sm text-text-dim mt-0.5">
              Checks GitHub releases for newer versions. Installs silently — Start Menu icon keeps working, your config in <span className="font-mono">%APPDATA%\DuneServer</span> is preserved.
            </p>
          </div>
          <button type="button" onClick={onCheckUpdate} disabled={updChecking} className="btn-secondary">
            <Icon name={updChecking ? 'Loader2' : 'RefreshCw'} size={15} className={updChecking ? 'animate-spin' : ''} />
            {updChecking ? 'Checking…' : 'Check now'}
          </button>
        </div>

        {updCheck && (
          <div className="text-sm border-t border-border pt-3 flex flex-wrap items-center gap-3">
            <span className="pill-muted">Current · v{updCheck.currentVersion}</span>
            {updCheck.latestVersion && (
              <span className={updCheck.available ? 'pill-warning' : 'pill-success'}>
                Latest · v{updCheck.latestVersion}
              </span>
            )}
            {updCheck.releaseUrl && (
              <a href={updCheck.releaseUrl} target="_blank" rel="noreferrer" className="text-xs underline text-text-muted hover:text-text">
                release notes
              </a>
            )}
            {updCheck.available && (
              <button
                type="button"
                onClick={onInstallUpdate}
                disabled={updInstalling}
                className="btn-primary ml-auto"
              >
                <Icon name={updInstalling ? 'Loader2' : 'Download'} size={15} className={updInstalling ? 'animate-spin' : ''} />
                {updInstalling ? 'Installing…' : `Update to v${updCheck.latestVersion}`}
              </button>
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
    </>
  )
}
