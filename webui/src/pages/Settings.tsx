import { useState, useEffect, type FormEvent } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { api } from '../api/client'
import type { ConfigResponse } from '../api/types'
import { checkForUpdate, installUpdate, listPreReleases, setUpdateChannel, setPreReleaseTag, type UpdateCheck, type PreReleaseInfo } from '../api/update'
import { publishUpdateCheck } from '../hooks/useUpdateCheck'
import { fmtToolVersion } from '../format'
import { AppearanceCard } from './settings/AppearanceCard'
import { PublicIpCard } from './settings/PublicIpCard'
import { RemoteAccessCard } from './settings/RemoteAccessCard'
import { MobileAppCard } from './settings/MobileAppCard'
import { FlsTokenCard } from './settings/FlsTokenCard'
import { SectionErrorBoundary } from '../components/SectionErrorBoundary'

const FIELDS: {
  key: string
  label: string
  placeholder: string
  help?: string
  type?: 'text' | 'select' | 'checkbox'
  browse?: { mode: 'folder' | 'file'; filter?: string }
  showWhen?: (values: Record<string, string>) => boolean
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
    help: 'Used when mode is "custom". Tokens: {ip} {port} {protocol}',
    showWhen: v => (v.PortCheckMode ?? '') === 'custom' },
  { key: 'ShowUdpPortStatus', label: 'Show UDP port status', placeholder: '',
    type: 'checkbox',
    help: 'Show the game-port (UDP 7777–7810) indicators on the dashboard and status bar. UDP can\'t be verified by the built-in/free TCP checkers, so these are hidden by default to avoid confusion — they only appear when Port-check mode is "custom" with a UDP-capable service AND this box is checked.',
    showWhen: v => (v.PortCheckMode ?? '') === 'custom' },
  { key: 'DbPort', label: 'Database port',
    placeholder: '15432',
    help: 'In-pod PostgreSQL port DST queries for Players / Bases / Storage. Funcom\'s default is 15432 — change it only if your server\'s database listens elsewhere (e.g. 15433). Use "Test connection" below after changing it.' },
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
  // "Remove passphrase (keep same key)" — strips the passphrase off the existing
  // key in place (no rotation, nothing to re-authorize on the VM), so background
  // checks that run non-interactively can use it.
  const [sshStripOpen, setSshStripOpen] = useState(false)
  const [sshStripPass, setSshStripPass] = useState('')
  const [sshStripping, setSshStripping] = useState(false)
  const [sshStripMsg, setSshStripMsg] = useState<string | null>(null)
  const [sshStripOk, setSshStripOk] = useState<boolean | null>(null)
  const [openingBat, setOpeningBat] = useState(false)
  const [batMsg, setBatMsg] = useState<string | null>(null)
  // Database connection test (issue #295): verify the configured in-pod
  // PostgreSQL port is reachable, and surface a clear message + suggested port
  // instead of silently showing empty Players / Bases / Storage.
  const [dbTesting, setDbTesting] = useState(false)
  const [dbTestMsg, setDbTestMsg] = useState<string | null>(null)
  const [dbTestOk, setDbTestOk] = useState<boolean | null>(null)
  const [dbSuggestedPort, setDbSuggestedPort] = useState<number | null>(null)
  // dune-admin VM cache: companion admin tool caches a stale BG snapshot
  // on the VM at ~/.dune/sh-<bg-id>*.yaml; clearing it forces its setup
  // wizard to re-discover the live DB password etc.
  const [daCache, setDaCache] = useState<{ count: number; totalBytes: number; files: { path: string; size: number }[] } | null>(null)
  const [daLoading, setDaLoading] = useState(false)
  const [daClearing, setDaClearing] = useState(false)
  const [daMsg, setDaMsg] = useState<string | null>(null)
  const [daErr, setDaErr] = useState<string | null>(null)
  async function loadDaCache() {
    setDaLoading(true)
    setDaErr(null)
    try {
      const r = await api<{ ok: boolean; count: number; totalBytes: number; files: { path: string; size: number }[]; message?: string }>(
        '/api/dune-admin-cache',
      )
      setDaCache({ count: r.count, totalBytes: r.totalBytes, files: r.files ?? [] })
    } catch (e) {
      setDaErr(e instanceof Error ? e.message : String(e))
      setDaCache(null)
    } finally {
      setDaLoading(false)
    }
  }
  async function onClearDaCache() {
    if (!window.confirm('Delete the Legacy Admin Tool cache on the VM?\n\nThis removes ~/.dune/sh-*.yaml on the VM. Nothing else is touched. The Legacy Admin Tool will re-run its setup discovery (and pick up the current DB password) the next time you launch it with -setup.')) return
    setDaClearing(true)
    setDaMsg(null)
    setDaErr(null)
    try {
      const r = await api<{ ok: boolean; cleared: number; message?: string }>(
        '/api/dune-admin-cache/clear',
        { method: 'POST' },
      )
      setDaMsg(r.message ?? (r.ok ? `Cleared ${r.cleared}.` : 'Clear did not complete.'))
      await loadDaCache()
    } catch (e) {
      setDaErr(e instanceof Error ? e.message : String(e))
    } finally {
      setDaClearing(false)
    }
  }
  useEffect(() => { void loadDaCache() }, [])

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
  async function onTestDbConnection() {
    setDbTesting(true)
    setDbTestMsg(null)
    setDbTestOk(null)
    setDbSuggestedPort(null)
    try {
      const raw = (values['DbPort'] ?? '').trim()
      const port = raw ? Number(raw) : undefined
      const r = await api<{ ok: boolean; port: number; message: string; suggestedPort?: number }>(
        '/api/db/test-connection',
        { method: 'POST', body: JSON.stringify({ port: Number.isFinite(port) ? port : undefined, probe: true }) },
      )
      setDbTestOk(r.ok)
      setDbTestMsg(r.message)
      if (r.suggestedPort) setDbSuggestedPort(r.suggestedPort)
    } catch (e) {
      setDbTestOk(false)
      setDbTestMsg(e instanceof Error ? e.message : String(e))
    } finally {
      setDbTesting(false)
    }
  }
  function applySuggestedPort() {
    if (dbSuggestedPort == null) return
    setValues(v => ({ ...v, DbPort: String(dbSuggestedPort) }))
    setDbSuggestedPort(null)
    setDbTestMsg('Database port updated — click "Save settings" below to persist it, then test again.')
    setDbTestOk(null)
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

  async function onStripSshPassphrase() {
    setSshStripping(true)
    setSshStripMsg(null)
    setSshStripOk(null)
    setError(null)
    try {
      const r = await api<{ ok: boolean; stripped: boolean; message?: string }>(
        '/api/config/strip-ssh-passphrase',
        { method: 'POST', body: JSON.stringify({ passphrase: sshStripPass }) },
      )
      setSshStripOk(r.ok)
      setSshStripMsg(r.message ?? (r.ok ? 'Passphrase removed.' : 'Could not remove the passphrase.'))
      if (r.ok) {
        setSshStripPass('')
        setSshStripOpen(false)
      }
    } catch (e) {
      setSshStripOk(false)
      setSshStripMsg(e instanceof Error ? e.message : String(e))
    } finally {
      setSshStripping(false)
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

  // Update channel + selectable pre-release (test channel). 'stable' follows
  // the newest non-prerelease release; 'test' opts into targeted pre-release
  // builds and reveals a dropdown to pick which one (default = newest).
  const [updChannel, setUpdChannel] = useState<'stable' | 'test'>('stable')
  const [preReleases, setPreReleases] = useState<PreReleaseInfo[]>([])
  const [selectedTag, setSelectedTag] = useState<string>('')   // '' = latest
  const [prLoading, setPrLoading] = useState(false)
  const [updSwitching, setUpdSwitching] = useState(false)

  async function loadPreReleases() {
    setPrLoading(true)
    try {
      const r = await listPreReleases({ force: true })
      setPreReleases(r.releases ?? [])
      return r.releases ?? []
    } catch (e) {
      setUpdErr(e instanceof Error ? e.message : String(e))
      return []
    } finally {
      setPrLoading(false)
    }
  }

  async function onChangeChannel(next: 'stable' | 'test') {
    if (next === updChannel || updSwitching) return
    setUpdSwitching(true)
    setUpdErr(null)
    setUpdMsg(null)
    try {
      // Switching to Test with no prior pin defaults to "latest" (empty tag);
      // the backend resolves that to the newest available pre-release.
      const tag = next === 'test' ? selectedTag : ''
      await setUpdateChannel(next, tag)
      setUpdChannel(next)
      if (next === 'test') {
        await loadPreReleases()
      } else {
        setSelectedTag('')
      }
      await onCheckUpdate()
    } catch (e) {
      setUpdErr(e instanceof Error ? e.message : String(e))
    } finally {
      setUpdSwitching(false)
    }
  }

  async function onSelectPreRelease(tag: string) {
    setUpdSwitching(true)
    setUpdErr(null)
    setUpdMsg(null)
    try {
      await setPreReleaseTag(tag)
      setSelectedTag(tag)
      await onCheckUpdate()
    } catch (e) {
      setUpdErr(e instanceof Error ? e.message : String(e))
    } finally {
      setUpdSwitching(false)
    }
  }

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

  // Reinstall the current version: re-download and re-run the installer for the
  // build that's already running (stable channel, up to date). Uses the same
  // interactive installer flow; the backend reinstall flag bypasses the
  // up-to-date gate. Useful for repairing a broken install or re-applying the
  // current release.
  async function onReinstall() {
    setUpdInstalling(true)
    setUpdErr(null)
    setUpdMsg(null)
    try {
      const r = await installUpdate({ reinstall: true })
      if (r.launched) {
        setUpdMsg(`Installer launched — reinstalling ${fmtToolVersion(r.toVersion)}. The portal will go offline briefly, then the app will relaunch.`)
      } else {
        setUpdErr(r.reason ?? 'Installer did not launch.')
      }
    } catch (e) {
      setUpdErr(e instanceof Error ? e.message : String(e))
    } finally {
      setUpdInstalling(false)
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

  // Return-to-live: a tester on a pre-release (Test) build gets back onto the
  // live release in one click. Force the Stable channel (clearing any pinned
  // pre-release) so the check resolves the live release, then install it. The
  // backend stable gate is relaxed for pre-release builds, so this works even
  // though the live release is not strictly "newer" (it's a downgrade or a
  // same-version reinstall that also clears the TEST BUILD indicator).
  async function onReturnToLive() {
    setUpdInstalling(true)
    setUpdErr(null)
    setUpdMsg(null)
    try {
      if (updChannel !== 'stable') {
        await setUpdateChannel('stable', '')
        setUpdChannel('stable')
        setSelectedTag('')
      }
      const res = await checkForUpdate({ force: true })
      setUpdCheck(res)
      publishUpdateCheck(res)
      if (!(res.installable ?? res.available)) {
        setUpdErr(res.error ?? 'The live release is not installable right now.')
        return
      }
      const r = await installUpdate()
      if (r.launched) {
        setUpdMsg(`Installer launched — returning to the live release ${fmtToolVersion(r.toVersion)}. The portal will go offline briefly, then relaunch.`)
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
        // Hydrate the update-channel toggle from persisted config.
        const ch = (out.values?.UpdateChannel ?? '').trim().toLowerCase()
        const isTest = ch === 'test' || ch === 'beta' || ch === 'prerelease' || ch === 'pre-release'
        const pin = (out.values?.UpdatePreReleaseTag ?? '').trim()
        setUpdChannel(isTest ? 'test' : 'stable')
        setSelectedTag(pin)
        if (isTest) { void loadPreReleases() }
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
    // Custom port-check mode is non-functional without a URL template (the
    // port check can't run, and it silently disables the working TCP check).
    // Block the save with a clear message instead of persisting a broken state.
    if ((values.PortCheckMode ?? '') === 'custom' && !(values.PortCheckUrlTemplate ?? '').trim()) {
      setError('A Port-check URL template is required when mode is "custom". Enter a UDP-capable check URL, or switch Port-check mode back to a built-in option.')
      return
    }
    // Confirm gate (issue #295): changing the database port silently breaks
    // Players/Bases/Storage if it's wrong, so make the user acknowledge it and
    // — importantly — show the OLD value so they can write it down before
    // changing it.
    const newDbPort = (values['DbPort'] ?? '').trim()
    const oldDbPortRaw = (cfg?.values?.DbPort ?? '').trim()
    const oldDbPort = oldDbPortRaw || '15432 (default)'
    if (newDbPort !== oldDbPortRaw) {
      const target = newDbPort || '15432 (default)'
      const ok = window.confirm(
        `Change the database port?\n\n`
        + `  Current port:  ${oldDbPort}\n`
        + `  New port:      ${target}\n\n`
        + `Write down the current port (${oldDbPort}) in case you need to switch back. `
        + `DST queries PostgreSQL on this port for Players, Bases and Storage — if it's `
        + `wrong, those pages show up empty. Use "Test connection" to verify the new port.\n\n`
        + `Save this change?`,
      )
      if (!ok) return
    }
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
      <SectionErrorBoundary name="Dune Server Tool updates">
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
            {updChannel === 'test' && (
              <span className="pill-warning text-xs flex items-center gap-1">
                <Icon name="FlaskConical" size={11} /> Test
              </span>
            )}
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
            {updCheck?.runningIsPrerelease && (
              <div className="rounded-md border border-warning/40 bg-warning/10 px-3 py-2.5 flex items-center gap-3 flex-wrap">
                <Icon name="FlaskConical" size={15} className="text-warning shrink-0" />
                <span className="text-sm">
                  You're running a <span className="font-semibold text-warning">TEST build</span>
                  {updCheck.currentVersion ? ` (${fmtToolVersion(updCheck.currentVersion)})` : ''}. Done testing? Return to the live release.
                </span>
                <button
                  type="button"
                  onClick={onReturnToLive}
                  disabled={updInstalling}
                  className="btn-secondary ml-auto shrink-0"
                >
                  <Icon name={updInstalling ? 'Loader2' : 'Undo2'} size={15} className={updInstalling ? 'animate-spin' : ''} />
                  {updInstalling ? 'Working…' : 'Return to live release'}
                </button>
              </div>
            )}
            <div className="flex items-center justify-between">
              <p className="text-sm text-text-dim">
                Checks GitHub releases for newer versions. Installs silently — Start Menu icon keeps working, your config in <span className="font-mono">%APPDATA%\DuneServer</span> is preserved.
              </p>
              <button type="button" onClick={onCheckUpdate} disabled={updChecking} className="btn-secondary ml-3 shrink-0">
                <Icon name={updChecking ? 'Loader2' : 'RefreshCw'} size={15} className={updChecking ? 'animate-spin' : ''} />
                {updChecking ? 'Checking…' : 'Check now'}
              </button>
            </div>

            {/* Update channel toggle + selectable pre-release (test channel) */}
            <div className="border-t border-border pt-3 space-y-2">
              <div className="flex items-center gap-3 flex-wrap">
                <span className="text-sm font-medium">Update channel</span>
                <div className="inline-flex rounded-md border border-border overflow-hidden" role="group" aria-label="Update channel">
                  <button
                    type="button"
                    onClick={() => onChangeChannel('stable')}
                    disabled={updSwitching}
                    className={`px-3 py-1.5 text-xs font-medium transition-colors ${updChannel === 'stable' ? 'bg-accent text-accent-fg' : 'bg-surface-2/40 text-text-muted hover:bg-surface-2'}`}
                    aria-pressed={updChannel === 'stable'}
                  >
                    Stable
                  </button>
                  <button
                    type="button"
                    onClick={() => onChangeChannel('test')}
                    disabled={updSwitching}
                    className={`px-3 py-1.5 text-xs font-medium transition-colors border-l border-border ${updChannel === 'test' ? 'bg-warning text-accent-fg' : 'bg-surface-2/40 text-text-muted hover:bg-surface-2'}`}
                    aria-pressed={updChannel === 'test'}
                  >
                    <Icon name="FlaskConical" size={12} className="inline -mt-0.5 mr-1" />
                    Test
                  </button>
                </div>
                {updSwitching && <Icon name="Loader2" size={14} className="animate-spin text-text-dim" />}
              </div>
              <p className="text-xs text-text-dim">
                {updChannel === 'stable'
                  ? 'Stable: receive the latest released version that everyone gets.'
                  : 'Test: receive pre-release builds shared for verification before they go live. Pick which build below — the newest is selected by default.'}
              </p>

              {updChannel === 'test' && (
                <div className="flex items-center gap-2 flex-wrap">
                  <span className="text-sm">Pre-release build</span>
                  {prLoading ? (
                    <span className="text-xs text-text-dim flex items-center gap-1.5">
                      <Icon name="Loader2" size={13} className="animate-spin" /> Loading…
                    </span>
                  ) : preReleases.length === 0 ? (
                    <span className="text-xs text-text-dim">No pre-release builds available right now.</span>
                  ) : (
                    <select
                      value={selectedTag || preReleases[0]?.tag || ''}
                      onChange={e => void onSelectPreRelease(e.target.value)}
                      disabled={updSwitching}
                      className="bg-surface-2 border border-border rounded-md px-2 py-1.5 text-sm"
                    >
                      {preReleases.map((pr, i) => (
                        <option key={pr.tag} value={pr.tag}>
                          {pr.name?.trim() ? `${pr.name} (${pr.tag})` : pr.tag}{i === 0 ? ' — newest' : ''}
                        </option>
                      ))}
                    </select>
                  )}
                </div>
              )}
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
                {(updCheck.installable ?? updCheck.available) && !(updCheck.channel !== 'test' && updCheck.runningIsPrerelease === true && !updCheck.available) && (
                  <button
                    type="button"
                    onClick={onInstallUpdate}
                    disabled={updInstalling}
                    className="btn-primary ml-auto"
                  >
                    <Icon name={updInstalling ? 'Loader2' : 'Download'} size={15} className={updInstalling ? 'animate-spin' : ''} />
                    {updInstalling
                      ? 'Installing…'
                      : updCheck.channel === 'test'
                        ? `Install ${fmtToolVersion(updCheck.latestVersion)}`
                        : `Update to ${fmtToolVersion(updCheck.latestVersion)}`}
                  </button>
                )}
                {updCheck.assetMissing && (
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
                {!(updCheck.installable ?? updCheck.available) && !updCheck.assetMissing && !updCheck.error && (
                  <span className="text-xs text-text-dim ml-auto flex items-center gap-2">
                    {updCheck.channel === 'test'
                      ? "You're on this test build."
                      : "You're on the latest version."}
                    {updCheck.channel !== 'test' && !!updCheck.assetName && (
                      <button
                        type="button"
                        onClick={onReinstall}
                        disabled={updInstalling}
                        className="btn-secondary"
                        title="Re-download and re-run the installer for the current version"
                      >
                        <Icon name={updInstalling ? 'Loader2' : 'RefreshCw'} size={14} className={updInstalling ? 'animate-spin' : ''} />
                        {updInstalling ? 'Reinstalling…' : 'Reinstall'}
                      </button>
                    )}
                  </span>
                )}
                {updCheck.error && (
                  <span className="text-xs text-danger ml-auto">Check failed: {String(updCheck.error)}</span>
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
      </SectionErrorBoundary>

      <SectionErrorBoundary name="Appearance"><AppearanceCard /></SectionErrorBoundary>

      <SectionErrorBoundary name="Remote Access"><RemoteAccessCard /></SectionErrorBoundary>

      <SectionErrorBoundary name="Public IP"><PublicIpCard /></SectionErrorBoundary>

      <SectionErrorBoundary name="Server Authorization Token"><FlsTokenCard /></SectionErrorBoundary>

      {/* --- Database connection (issue #295) --- */}
      <div className="card mb-4 p-6">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="flex items-center gap-2 mb-1">
              <Icon name="Database" size={18} className="text-text-muted" />
              <h2 className="text-lg font-semibold">Database connection</h2>
            </div>
            <p className="text-sm text-text-dim">
              DST reads Players, Bases and Storage from the server's PostgreSQL
              database on port <span className="font-mono">{(values['DbPort'] ?? '').trim() || '15432'}</span>.
              If those pages are empty, the database may be listening on a
              different port — set it in <span className="font-medium">Database port</span> below
              and test it here. The VM must be running.
            </p>
            {dbTestMsg && (
              <p className={`mt-2 text-xs flex items-center gap-1.5 ${dbTestOk === false ? 'text-danger' : dbTestOk === true ? 'text-success' : 'text-text-dim'}`}>
                <Icon name={dbTestOk === false ? 'AlertCircle' : dbTestOk === true ? 'CheckCircle2' : 'Info'} size={13} />
                {dbTestMsg}
              </p>
            )}
            {dbSuggestedPort != null && (
              <button
                type="button"
                onClick={applySuggestedPort}
                className="mt-2 btn-secondary"
              >
                <Icon name="ArrowRight" size={14} /> Use port {dbSuggestedPort}
              </button>
            )}
          </div>
          <div className="flex items-center gap-2 shrink-0">
            <button
              type="button"
              onClick={() => void onTestDbConnection()}
              disabled={dbTesting}
              title="Run SELECT 1 against the configured database port"
              className="btn-secondary"
            >
              <Icon name={dbTesting ? 'Loader2' : 'PlugZap'} size={15} className={dbTesting ? 'animate-spin' : ''} />
              {dbTesting ? 'Testing…' : 'Test connection'}
            </button>
          </div>
        </div>
      </div>

      {/* --- dune-admin VM cache (companion admin tool, decoupled in 12.x) --- */}
      <div className="card mb-4 p-6">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="flex items-center gap-2 mb-1">
              <Icon name="Trash2" size={18} className="text-text-muted" />
              <h2 className="text-lg font-semibold">Legacy Admin Cache</h2>
            </div>
            <p className="text-sm text-text-dim">
              The Legacy Admin Tool caches a per-battlegroup snapshot on the VM
              at <span className="font-mono">~/.dune/sh-&lt;bg-id&gt;*.yaml</span> and reads the DB password from it. After
              Funcom rotates the DB password on a reconcile, that cache goes stale and the tool keeps
              presenting the old password on its next <span className="font-mono">-setup</span> run. Clearing the cache forces
              a fresh discovery from the live cluster.
            </p>
            {daCache && (
              <p className="mt-2 text-xs text-text-dim">
                {daCache.count === 0 ? (
                  <span>No Legacy Admin Tool cache files present on the VM.</span>
                ) : (
                  <span>
                    {daCache.count} file{daCache.count === 1 ? '' : 's'} on the VM
                    {daCache.totalBytes > 0 && ` · ${(daCache.totalBytes / 1024).toFixed(0)} KB`}
                  </span>
                )}
              </p>
            )}
            {daMsg && (
              <p className="mt-2 text-xs text-success flex items-center gap-1.5">
                <Icon name="CheckCircle2" size={13} /> {daMsg}
              </p>
            )}
            {daErr && (
              <p className="mt-2 text-xs text-danger flex items-center gap-1.5">
                <Icon name="AlertCircle" size={13} /> {daErr}
              </p>
            )}
          </div>
          <div className="flex items-center gap-2 shrink-0">
            <button
              type="button"
              onClick={() => void loadDaCache()}
              disabled={daLoading || daClearing}
              title="Re-check the VM"
              className="btn-secondary"
            >
              <Icon name={daLoading ? 'Loader2' : 'RefreshCw'} size={15} className={daLoading ? 'animate-spin' : ''} />
              {daLoading ? 'Checking…' : 'Refresh'}
            </button>
            <button
              type="button"
              onClick={() => void onClearDaCache()}
              disabled={daClearing || daLoading || (daCache?.count ?? 0) === 0}
              title="Delete ~/.dune/sh-*.yaml on the VM"
              className="btn-danger"
            >
              <Icon name={daClearing ? 'Loader2' : 'Trash2'} size={15} className={daClearing ? 'animate-spin' : ''} />
              {daClearing ? 'Clearing…' : 'Clear cache'}
            </button>
          </div>
        </div>
      </div>

      <form onSubmit={onSubmit} className="card p-6 space-y-5">
        {FIELDS.filter(f => !f.showWhen || f.showWhen(values)).map(f => (
          <div key={f.key}>
            <label className="block text-sm font-medium mb-1.5">
              {f.label}
              <span className="ml-2 text-[10px] font-mono text-text-dim uppercase tracking-wider">{f.key}</span>
            </label>
            {f.type === 'checkbox' ? (
              <label className="flex items-center gap-2 cursor-pointer select-none">
                <input
                  type="checkbox"
                  checked={['1','true','yes','on'].includes((values[f.key] ?? '').trim().toLowerCase())}
                  onChange={e => setValues(v => ({ ...v, [f.key]: e.target.checked ? 'true' : 'false' }))}
                  className="h-4 w-4"
                />
                <span className="text-sm text-text-muted">Enabled</span>
              </label>
            ) : f.type === 'select' ? (
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
                {f.key === 'SshKey' && (
                  <button
                    type="button"
                    onClick={() => { setSshStripOpen(o => !o); setSshStripMsg(null) }}
                    title="Strip the passphrase off this key without rotating it (keeps the same key, no VM changes)"
                    className="btn-secondary shrink-0"
                  >
                    <Icon name="KeyRound" size={15} />
                    Remove passphrase
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
            {f.key === 'SshKey' && sshStripOpen && (
              <div className="mt-2 rounded-lg border border-border bg-surface-2 p-3 space-y-2">
                <p className="text-xs text-text-dim">
                  Removes the passphrase from this key <span className="text-text">without rotating it</span> — the key pair
                  stays the same, so it remains authorized on the VM and nothing needs re-adding. Background checks run
                  non-interactively and can't answer a passphrase prompt, which is why a passphrase-protected key shows the
                  dashboard as Unknown. Enter the key's current passphrase:
                </p>
                <div className="flex items-stretch gap-2">
                  <input
                    type="password"
                    autoComplete="off"
                    value={sshStripPass}
                    placeholder="Current passphrase"
                    onChange={e => setSshStripPass(e.target.value)}
                    onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); void onStripSshPassphrase() } }}
                    className="flex-1 min-w-0 px-3 py-2 rounded-lg bg-surface border border-border text-text text-sm
                               placeholder:text-text-dim focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
                  />
                  <button
                    type="button"
                    onClick={() => void onStripSshPassphrase()}
                    disabled={sshStripping}
                    className="btn-secondary shrink-0"
                  >
                    <Icon name={sshStripping ? 'Loader2' : 'KeyRound'} size={15} className={sshStripping ? 'animate-spin' : ''} />
                    {sshStripping ? 'Removing…' : 'Remove passphrase'}
                  </button>
                </div>
              </div>
            )}
            {f.key === 'SshKey' && sshStripMsg && (
              <p className={`mt-1 text-xs flex items-center gap-1.5 ${sshStripOk ? 'text-success' : 'text-danger'}`}>
                <Icon name={sshStripOk ? 'CheckCircle2' : 'AlertTriangle'} size={13} /> {sshStripMsg}
              </p>
            )}
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

      <SectionErrorBoundary name="Mobile App Pairing"><MobileAppCard /></SectionErrorBoundary>
    </>
  )
}
