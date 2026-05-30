import { useState, useEffect, type FormEvent } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { api } from '../api/client'
import type { ConfigResponse } from '../api/types'
import { checkForUpdate, installUpdate, type UpdateCheck } from '../api/update'
import {
  checkDuneAdminUpdate,
  installDuneAdminUpdate,
  pricingPatchStatus,
  runDuneAdminSetup,
  getDuneAdminDotFolder,
  deleteDuneAdminDotFolder,
  type DuneAdminCheck,
  type DuneAdminPricingPatchStatus,
} from '../api/duneAdmin'
import {
  syncConfigFiles,
  type ConfigFilesSyncResult,
} from '../api/configFiles'
import { fmtToolVersion } from '../format'

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
  { key: 'DuneAdminExe', label: 'dune-admin folder',
    placeholder: 'C:\\Tools\\dune-admin',
    help: 'Optional — pick the folder where dune-admin should live. This tool installs dune-admin.exe there for you, so the folder can be empty / not exist yet.',
    browse: { mode: 'folder' } },
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
  const [cfSyncing, setCfSyncing] = useState(false)
  const [cfResult, setCfResult] = useState<ConfigFilesSyncResult | null>(null)

  async function onSyncConfigFiles() {
    setCfSyncing(true)
    setError(null)
    setCfResult(null)
    try {
      const r = await syncConfigFiles()
      setCfResult(r)
      if (!r.ok) setError(r.message || 'Some config files could not be collected.')
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setCfSyncing(false)
    }
  }

  // "Use local config files" toggle — when ON, DST reads the SSH key from its
  // local configFiles store (overriding the configured SshKey path). Persisted
  // immediately to dune-server.config as UseLocalConfigFiles ('true'/'false').
  const useLocalCfgFiles = (values.UseLocalConfigFiles ?? '').toLowerCase() === 'true'
  const [cfToggleSaving, setCfToggleSaving] = useState(false)
  async function onToggleUseLocalConfigFiles(next: boolean) {
    const msg = next
      ? 'Turn ON local config files?\n\nDST will read the SSH key from its local store (%APPDATA%\\DuneServer\\configFiles\\sshKey) instead of the configured "SSH key path". Make sure you have refreshed config files at least once so the local copy is current.'
      : 'Turn OFF local config files?\n\nDST will go back to using the configured "SSH key path" directly.'
    if (!window.confirm(msg)) return
    setCfToggleSaving(true)
    setError(null)
    try {
      const out = await api<{ ok: boolean; complete: boolean; values: Record<string, string> }>(
        '/api/config',
        { method: 'PUT', body: JSON.stringify({ values: { ...values, UseLocalConfigFiles: next ? 'true' : 'false' } }) },
      )
      setValues({ ...out.values, UseLocalConfigFiles: next ? 'true' : 'false' })
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setCfToggleSaving(false)
    }
  }

  // "Generate new SSH key" — runs the rotate-ssh-key command, waits for it to
  // finish, then propagates the fresh key everywhere DST uses it.
  const [sshRotating, setSshRotating] = useState(false)
  const [sshRotateMsg, setSshRotateMsg] = useState<string | null>(null)
  async function onRotateSshKey() {
    if (!window.confirm('Generate a NEW SSH key?\n\nThis regenerates the key, authorizes it on the dune-awakening VM, and copies it everywhere DST uses it (local config-files store + dune-admin folder). The VM must be running. A console window will open and may ask for admin approval.')) return
    setSshRotating(true)
    setSshRotateMsg(null)
    setError(null)
    try {
      const r = await api<{ ok: boolean; rotated: boolean; synced: boolean; message?: string }>(
        '/api/config/rotate-ssh-key',
        { method: 'POST' },
      )
      setSshRotateMsg(r.message ?? (r.ok ? 'SSH key rotated and propagated.' : 'Rotation did not complete.'))
      if (!r.ok && r.message) setError(r.message)
      // Reload config so the form reflects any path changes.
      try {
        const cfgOut = await api<ConfigResponse>('/api/config')
        setCfg(cfgOut)
        setValues({ ...cfgOut.values, UseLocalConfigFiles: cfgOut.useLocalConfigFiles ? 'true' : 'false' })
      } catch { /* non-fatal */ }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setSshRotating(false)
    }
  }


  // "Wipe all listings" — TESTING ONLY. Deletes every market-bot listing on
  // the VM so the bot re-lists from scratch with freshly-computed prices.
  const [wipeApprove, setWipeApprove] = useState(false)
  const [wiping, setWiping] = useState(false)
  const [wipeMsg, setWipeMsg] = useState<string | null>(null)
  const [wipeErr, setWipeErr] = useState<string | null>(null)
  async function onWipeListings() {
    if (!wipeApprove) return
    if (!window.confirm('FOR TESTING ONLY — this will WIPE ALL MARKET LISTINGS on the VM.\n\nThe market bot will re-list everything from scratch on its next listing tick. Continue?')) return
    setWiping(true)
    setWipeMsg(null)
    setWipeErr(null)
    try {
      const r = await api<{ ok: boolean; ordersDeleted?: number; itemsDeleted?: number; message?: string; error?: string }>(
        '/api/db/wipe-bot-listings',
        { method: 'POST', body: JSON.stringify({ approve: true }) },
      )
      if (r.ok) {
        setWipeMsg(r.message ?? `Wiped ${r.ordersDeleted ?? '?'} orders / ${r.itemsDeleted ?? '?'} items.`)
        setWipeApprove(false)
      } else {
        setWipeErr(r.error ?? 'Wipe failed.')
      }
    } catch (e) {
      setWipeErr(e instanceof Error ? e.message : String(e))
    } finally {
      setWiping(false)
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

  // dune-admin.exe update card state
  const [daCheck, setDaCheck] = useState<DuneAdminCheck | null>(null)
  const [daChecking, setDaChecking] = useState(false)
  const [daInstalling, setDaInstalling] = useState(false)
  const [daMsg, setDaMsg] = useState<string | null>(null)
  const [daErr, setDaErr] = useState<string | null>(null)

  // v6.1.25: pricing-patch rebuild runs detached in the background after
  // /install returns. We poll /api/dune-admin/pricing-patch-status every 2s
  // while status==='running' and show a separate "Patching..." chip with
  // elapsed time + log tail.
  const [daPatch, setDaPatch] = useState<DuneAdminPricingPatchStatus | null>(null)
  const [daPatchPolling, setDaPatchPolling] = useState(false)
  useEffect(() => {
    if (!daPatchPolling) return
    let cancelled = false
    const tick = async () => {
      try {
        const s = await pricingPatchStatus()
        if (cancelled) return
        setDaPatch(s)
        if (s.status !== 'running') {
          setDaPatchPolling(false)
          if (s.status === 'success') {
            setDaMsg(prev =>
              (prev ? prev + ' ' : '')
              + `Pricing patch rebuilt successfully${s.targetTag ? ` (${s.targetTag})` : ''}.`,
            )
            // Refresh installed-version display.
            try { setDaCheck(await checkDuneAdminUpdate({ force: false })) } catch { /* non-fatal */ }
          } else if (s.status === 'failed') {
            const msg = s.error ?? `Pricing rebuild failed (exit ${s.exitCode ?? 'n/a'}).`
            setDaErr(prev => (prev ? prev + ' ' : '') + msg + (s.logFile ? ` Log: ${s.logFile}` : ''))
          }
        }
      } catch { /* keep polling; transient server hiccup */ }
    }
    void tick()
    const id = window.setInterval(() => { void tick() }, 2000)
    return () => { cancelled = true; window.clearInterval(id) }
  }, [daPatchPolling])

  // Collapsible-card state — both update cards start minimized.
  const [updExpanded, setUpdExpanded] = useState(false)
  const [daExpanded, setDaExpanded] = useState(false)

  // Auto-apply pricing patch checkbox — saved to dune-server.config as
  // AutoApplyPricingPatch ('true'/'false'). Persisted immediately on toggle
  // so the user doesn't have to remember to hit Save below.
  const autoApply = (values.AutoApplyPricingPatch ?? '').toLowerCase() === 'true'
  const [autoApplySaving, setAutoApplySaving] = useState(false)
  async function onToggleAutoApply(next: boolean) {
    setAutoApplySaving(true)
    setDaErr(null)
    try {
      const out = await api<{ ok: boolean; complete: boolean; values: Record<string, string> }>(
        '/api/config',
        { method: 'PUT', body: JSON.stringify({ values: { ...values, AutoApplyPricingPatch: next ? 'true' : 'false' } }) },
      )
      setValues(out.values)
    } catch (e) {
      setDaErr(e instanceof Error ? e.message : String(e))
    } finally {
      setAutoApplySaving(false)
    }
  }

  // Gamble die config — saved to dune-server.config as GambleDieSize /
  // GambleTarget. The sane-pricing patch rolls a die per candidate listing and
  // buys only on the target number. Defaults (12 / 5) reproduce the original
  // patch behaviour. These take effect on the NEXT patch (re)apply — i.e. click
  // Install with "Keep ... pricing patch" checked to rebuild with new values.
  const dieSize = values.GambleDieSize?.trim() || '12'
  const dieTarget = values.GambleTarget?.trim() || '5'
  const [dieInput, setDieInput] = useState(dieSize)
  const [targetInput, setTargetInput] = useState(dieTarget)
  const [dieSaving, setDieSaving] = useState(false)
  // Reflect externally-loaded config into the inputs once it arrives.
  useEffect(() => { setDieInput(dieSize); setTargetInput(dieTarget) }, [dieSize, dieTarget])
  const dieNum = Number.parseInt(dieInput, 10)
  const targetNum = Number.parseInt(targetInput, 10)
  const dieValid = Number.isInteger(dieNum) && dieNum >= 2
  const targetValid = Number.isInteger(targetNum) && targetNum >= 1 && (dieValid ? targetNum <= dieNum : true)
  const dieDirty = dieInput !== dieSize || targetInput !== dieTarget
  async function onSaveDie() {
    if (!dieValid || !targetValid) return
    setDieSaving(true)
    setDaErr(null)
    try {
      const out = await api<{ ok: boolean; complete: boolean; values: Record<string, string> }>(
        '/api/config',
        { method: 'PUT', body: JSON.stringify({ values: { ...values, GambleDieSize: String(dieNum), GambleTarget: String(targetNum) } }) },
      )
      setValues(out.values)
    } catch (e) {
      setDaErr(e instanceof Error ? e.message : String(e))
    } finally {
      setDieSaving(false)
    }
  }

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

  async function onCheckDuneAdmin(force = true) {
    setDaChecking(true)
    setDaErr(null)
    setDaMsg(null)
    try {
      setDaCheck(await checkDuneAdminUpdate({ force }))
    } catch (e) {
      setDaErr(e instanceof Error ? e.message : String(e))
    } finally {
      setDaChecking(false)
    }
  }

  // Install/setup preflight: on first-time install, a folder change, OR a
  // same-folder reinstall, a %USERPROFILE%\.dune-admin config folder may hold
  // stale DB/host pointers that make the market bot fail. We ALWAYS ask before
  // deleting — never auto-delete. Returns true to proceed with the
  // install/setup regardless of the user's choice (declining just keeps it).
  async function preflightStaleDotFolder(): Promise<boolean> {
    try {
      // Detect first-time install, a folder change, or a same-folder reinstall.
      const installedExe = daCheck?.installed?.exists ? (daCheck.exePath ?? '') : ''
      const installedFolder = installedExe
        ? installedExe.replace(/[\\/]+$/, '').replace(/[\\/][^\\/]*$/, '')
        : ''
      const norm = (p: string) => p.trim().replace(/[\\/]+$/, '').toLowerCase()
      const chosenFolder = norm(values.DuneAdminExe ?? '')
      const isFirstTime = !installedFolder
      const folderChanged = !!installedFolder && norm(installedFolder) !== chosenFolder

      const pf = await getDuneAdminDotFolder()
      if (!pf.exists) return true

      const lead = isFirstTime
        ? `Preflight — you're setting up dune-admin.`
        : folderChanged
          ? `Preflight — you're changing the dune-admin install folder.`
          : `Preflight — you're reinstalling dune-admin.`
      const ok = window.confirm(
        `${lead}\n\n` +
        `An existing dune-admin config folder was found at:\n${pf.path}\n\n` +
        `WHY THIS MATTERS: dune-admin's market bot reads its config and database ` +
        `pointers from this folder. If it holds stale settings, the market bot ` +
        `can FAIL to start.\n\n` +
        `May I DELETE this folder now so dune-admin can regenerate a clean one ` +
        `during setup?\n\n` +
        `OK  = delete it and continue\n` +
        `Cancel = keep it and continue (market bot may fail)`,
      )
      if (ok) {
        const r = await deleteDuneAdminDotFolder()
        if (r.ok && r.deleted) {
          setDaMsg(`Removed stale config folder ${r.path}. dune-admin will create a fresh one during setup.`)
        }
      }
    } catch (e) {
      // Non-fatal — surface the issue but let the install proceed.
      setDaErr(`Stale-folder preflight failed: ${e instanceof Error ? e.message : String(e)}`)
    }
    return true
  }

  async function onInstallDuneAdmin() {
    setDaInstalling(true)
    setDaErr(null)
    setDaMsg(null)
    setDaPatch(null)
    setDaPatchPolling(false)
    try {
      await preflightStaleDotFolder()
      const r = await installDuneAdminUpdate()
      if (r.ok) {
        const sshNote = r.sshKeyCopy?.ok
          ? (r.sshKeyCopy.skipped
              ? ' SSH key already in place.'
              : ' SSH key copied next to dune-admin.exe.')
          : (r.sshKeyCopy
              ? ` WARNING: SSH key was NOT copied — dune-admin will not be able to reach the VM until you place sshKey in ${r.targetDir ?? 'the dune-admin folder'}. (${r.sshKeyCopy.message ?? 'no detail'})`
              : '')
        setDaMsg(`dune-admin.exe replaced with v${r.toVersion}. Restart any running instance.${sshNote}`)
        // v6.1.25: if the install kicked off the detached pricing-patch
        // rebuild, start polling its status. We DO NOT block on it here —
        // the binary install is already done.
        if (r.pricingPatch && r.pricingPatch.status === 'running') {
          setDaPatch(r.pricingPatch)
          setDaPatchPolling(true)
        } else if (r.pricingPatch && r.pricingPatch.status === 'failed') {
          setDaErr(`Pricing rebuild failed to start: ${r.pricingPatch.error ?? 'unknown error'}`)
        }
        // Re-check so the displayed installed version updates.
        try {
          setDaCheck(await checkDuneAdminUpdate({ force: false }))
        } catch { /* non-fatal */ }
      } else {
        setDaErr('Installer reported no action.')
      }
    } catch (e) {
      setDaErr(e instanceof Error ? e.message : String(e))
    } finally {
      setDaInstalling(false)
    }
  }

  const [daSettingUp, setDaSettingUp] = useState(false)
  async function onRunDuneAdminSetup() {
    setDaSettingUp(true)
    setDaErr(null)
    setDaMsg(null)
    try {
      await preflightStaleDotFolder()
      const r = await runDuneAdminSetup()
      if (r.ok) {
        const installedPart = r.didInstall ? 'Downloaded + installed dune-admin.exe, then ' : ''
        const sshNote = r.sshKeyCopy?.ok
          ? (r.sshKeyCopy.skipped ? ' SSH key already in place.' : ' SSH key copied next to dune-admin.exe.')
          : (r.sshKeyCopy
              ? ` WARNING: SSH key was NOT copied — dune-admin cannot reach the VM until you place sshKey in ${r.targetDir ?? 'the dune-admin folder'}. (${r.sshKeyCopy.message ?? 'no detail'})`
              : '')
        setDaMsg(`${installedPart}opened the dune-admin setup wizard in a console window. Answer the prompts there — dune-admin will auto-launch when the wizard finishes.${sshNote}`)
        // Re-check so the UI shows the new install + config.yaml state.
        try {
          setDaCheck(await checkDuneAdminUpdate({ force: false }))
        } catch { /* non-fatal */ }
      } else {
        setDaErr('Setup wizard could not be launched.')
      }
    } catch (e) {
      setDaErr(e instanceof Error ? e.message : String(e))
    } finally {
      setDaSettingUp(false)
    }
  }

  useEffect(() => {
    void (async () => {
      try {
        const out = await api<ConfigResponse>('/api/config')
        setCfg(out)
        setValues({ ...out.values, UseLocalConfigFiles: out.useLocalConfigFiles ? 'true' : 'false' })
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e))
      } finally {
        setLoading(false)
      }
    })()
    // Kick off a non-forced dune-admin check on mount so the card shows
    // current/latest immediately without requiring a button press. Uses
    // the 1h server-side cache so it does not hit the GitHub API every
    // time the user opens Settings.
    void (async () => {
      try {
        setDaChecking(true)
        setDaCheck(await checkDuneAdminUpdate({ force: false }))
      } catch (e) {
        setDaErr(e instanceof Error ? e.message : String(e))
      } finally {
        setDaChecking(false)
      }
    })()

    // v6.1.25: if a previous Settings session kicked off a pricing-patch
    // rebuild that's still running (or just terminated with the user
    // never seeing the result), pick it up on mount so the UI surfaces
    // it instead of silently ignoring an in-flight build.
    void (async () => {
      try {
        const s = await pricingPatchStatus()
        if (s && s.status && s.status !== 'idle') {
          setDaPatch(s)
          if (s.status === 'running') setDaPatchPolling(true)
        }
      } catch { /* non-fatal */ }
    })()
    // Same idea for the Dune Server self-updater — populate the collapsed
    // header pills (current/latest) without forcing a fresh GitHub hit.
    void (async () => {
      try {
        setUpdChecking(true)
        setUpdCheck(await checkForUpdate({ force: false }))
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

      {/* --- Config files store (top) ----------------------------------- */}
      <div className="card mb-4 p-4">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h3 className="font-semibold flex items-center gap-2">
              <Icon name="FolderSync" size={16} /> Local config files
            </h3>
            <p className="text-sm text-muted mt-1">
              DST keeps a local copy of everything it needs (SSH key, dune-server.config,
              dune-admin config) in <code>%APPDATA%\DuneServer\configFiles</code>. Repull if you've
              regenerated your SSH key or changed config — the refreshed key is also re-dumped into
              the dune-admin folder.
            </p>
          </div>
          <button
            type="button"
            onClick={onSyncConfigFiles}
            disabled={cfSyncing}
            className="btn btn-secondary shrink-0"
          >
            <Icon name={cfSyncing ? 'Loader2' : 'RefreshCw'} size={14} className={cfSyncing ? 'animate-spin' : ''} />
            {cfSyncing ? 'Refreshing…' : 'Refresh config files'}
          </button>
        </div>

        {cfResult && (
          <div className="mt-3 space-y-2">
            {cfResult.sshKeyDir && (
              <p className="text-xs text-muted">
                SSH key re-dumped into dune-admin folder: <code>{cfResult.sshKeyDir}</code>
              </p>
            )}
            <div className="text-sm border border-default/40 rounded overflow-hidden">
              {cfResult.files.map((f) => (
                <div key={f.name} className="flex items-center gap-2 px-3 py-1.5 border-b border-default/20 last:border-0">
                  <Icon
                    name={f.status === 'copied' ? 'CheckCircle2' : f.status === 'skipped' ? 'MinusCircle' : f.status === 'error' ? 'AlertCircle' : 'Circle'}
                    size={13}
                    className={f.status === 'copied' ? 'text-success' : f.status === 'error' ? 'text-danger' : 'text-muted'}
                  />
                  <span className="font-mono text-xs">{f.name}</span>
                  <span className="text-xs text-muted truncate flex-1">{f.message}</span>
                </div>
              ))}
            </div>
          </div>
        )}

        <label className="mt-4 flex items-start gap-3 cursor-pointer select-none">
          <input
            type="checkbox"
            className="mt-1"
            checked={useLocalCfgFiles}
            disabled={cfToggleSaving}
            onChange={e => onToggleUseLocalConfigFiles(e.target.checked)}
          />
          <span className="text-sm">
            <span className="font-medium flex items-center gap-2">
              Use local config files
              {cfToggleSaving && <Icon name="Loader2" size={13} className="animate-spin" />}
            </span>
            <span className="text-muted block mt-0.5">
              When on, DST reads the SSH key from its local store instead of the configured
              “SSH key path”. Refresh config files first so the local copy is current.
            </span>
          </span>
        </label>
      </div>

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
            <h2 className="text-lg font-semibold">Dune Server updates</h2>
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
                {updCheck.available && (
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

      {/* --- dune-admin.exe update card (collapsible) -------------------- */}
      <div className="card mb-6">
        <button
          type="button"
          onClick={() => setDaExpanded(v => !v)}
          className="w-full flex items-center justify-between px-6 py-4 text-left hover:bg-surface-2/40 rounded-lg transition-colors"
          aria-expanded={daExpanded}
        >
          <div className="flex items-center gap-3">
            <Icon name={daExpanded ? 'ChevronDown' : 'ChevronRight'} size={16} className="text-text-dim" />
            <Icon name="Package" size={18} className="text-text-muted" />
            <h2 className="text-lg font-semibold">dune-admin.exe</h2>
            <a
              href="https://github.com/Icehunter"
              target="_blank"
              rel="noopener noreferrer"
              onClick={(e) => e.stopPropagation()}
              title="dune-admin is built by Icehunter — visit GitHub profile"
              className="flex items-center gap-1 text-[10px] font-mono text-text-dim
                         hover:text-accent px-1.5 py-0.5 rounded bg-surface-3/60
                         border border-border/40 hover:border-accent/40 transition-colors"
            >
              <Icon name="Github" size={10} />
              <span>by Icehunter</span>
            </a>
          </div>
          <div className="flex items-center gap-2">
            {daCheck && (
              <>
                {daCheck.installed.exists && daCheck.installed.version ? (
                  <span className="pill-muted text-xs">v{daCheck.installed.version.replace(/^v/, '')}</span>
                ) : daCheck.configured && daCheck.installed.exists ? (
                  <span className="pill-muted text-xs">unknown</span>
                ) : daCheck.configured ? (
                  <span className="pill-warning text-xs">not installed</span>
                ) : (
                  <span className="pill-warning text-xs">path not set</span>
                )}
                {daCheck.available && daCheck.latestVersion && (
                  <span className="pill-warning text-xs">v{daCheck.latestVersion} available</span>
                )}
                {!daCheck.available && !daCheck.error && daCheck.installed.exists && daCheck.latestVersion && (
                  <span className="pill-success text-xs">up to date</span>
                )}
              </>
            )}
          </div>
        </button>

        {daExpanded && (
          <div className="px-6 pb-5 space-y-3">
            <div className="flex items-center justify-between">
              <p className="text-sm text-text-dim">
                Checks{' '}
                <a
                  href="https://github.com/Icehunter/dune-admin"
                  target="_blank"
                  rel="noopener noreferrer"
                  title="dune-admin is built by Icehunter — view the repo"
                  className="font-mono text-accent hover:underline"
                >
                  Icehunter/dune-admin
                </a>
                {' '}releases and replaces the EXE at the <span className="font-mono">DuneAdminExe</span> path below.
                {' '}Close any running dune-admin first.
              </p>
              <button
                type="button"
                onClick={() => onCheckDuneAdmin(true)}
                disabled={daChecking}
                className="btn-secondary ml-3 shrink-0"
              >
                <Icon name={daChecking ? 'Loader2' : 'RefreshCw'} size={15} className={daChecking ? 'animate-spin' : ''} />
                {daChecking ? 'Checking...' : 'Check now'}
              </button>
            </div>

            {daCheck && (
              <div className="text-sm border-t border-border pt-3 space-y-2">
                <div className="flex flex-wrap items-center gap-3">
                  {daCheck.installed.exists ? (
                    <span className="pill-muted">
                      Current &middot; {daCheck.installed.version
                        ? `v${daCheck.installed.version.replace(/^v/, '')}`
                        : 'unknown'}
                      {daCheck.installed.versionSource === 'unknown' && (
                        <span className="ml-1 text-text-dim">(no version metadata)</span>
                      )}
                    </span>
                  ) : daCheck.configured ? (
                    <span className="pill-warning">Not installed at configured path</span>
                  ) : (
                    <span className="pill-warning">DuneAdminExe path not set</span>
                  )}

                  {daCheck.latestVersion && (
                    <span className={daCheck.available ? 'pill-warning' : 'pill-success'}>
                      Latest &middot; v{daCheck.latestVersion}
                    </span>
                  )}

                  {daCheck.releaseUrl && (
                    <a
                      href={daCheck.releaseUrl}
                      target="_blank"
                      rel="noreferrer"
                      className="text-xs underline text-text-muted hover:text-text"
                    >
                      release notes
                    </a>
                  )}

                  {daCheck.configured && (
                    <button
                      type="button"
                      onClick={onInstallDuneAdmin}
                      disabled={daInstalling}
                      className="btn-primary ml-auto"
                    >
                      <Icon
                        name={daInstalling ? 'Loader2' : 'Download'}
                        size={15}
                        className={daInstalling ? 'animate-spin' : ''}
                      />
                      {daInstalling
                        ? 'Installing...'
                        : !daCheck.installed.exists
                          ? `Install${daCheck.latestVersion ? ` v${daCheck.latestVersion}` : ''}`
                          : daCheck.available
                            ? `Update to v${daCheck.latestVersion}`
                            : `Reinstall${daCheck.latestVersion ? ` v${daCheck.latestVersion}` : ''}`}
                    </button>
                  )}

                  {!daCheck.available && !daCheck.error && daCheck.installed.exists && (
                    <span className="text-xs text-text-dim">You're on the latest version.</span>
                  )}

                  {daCheck.error && (
                    <span className="text-xs text-danger ml-auto">Check failed: {daCheck.error}</span>
                  )}
                </div>

                {daCheck.exePath && (
                  <div className="text-xs text-text-dim font-mono break-all">
                    {daCheck.exePath}
                  </div>
                )}

                {/* v6.1.24: First-time setup — kicks off the interactive
                    dune-admin -setup wizard in a console window. If the
                    binary isn't installed yet the route downloads it first.
                    Shown whenever the binary is missing OR config.yaml has
                    never been written (i.e. wizard has never been completed). */}
                {daCheck.configured && (!daCheck.installed.exists || !daCheck.configYamlExists) && (
                  <div className="pt-3 border-t border-border space-y-2">
                    <div className="flex items-center gap-2">
                      <button
                        type="button"
                        onClick={onRunDuneAdminSetup}
                        disabled={daSettingUp}
                        className="btn-primary"
                      >
                        <Icon
                          name={daSettingUp ? 'Loader2' : 'Wand2'}
                          size={15}
                          className={daSettingUp ? 'animate-spin' : ''}
                        />
                        {daSettingUp
                          ? 'Launching wizard...'
                          : !daCheck.installed.exists
                            ? 'Install + run setup wizard'
                            : 'Run setup wizard'}
                      </button>
                      <span className="text-xs text-text-dim">
                        {!daCheck.installed.exists
                          ? 'Downloads dune-admin.exe, then opens the interactive setup wizard in a new console window.'
                          : 'Opens the interactive setup wizard in a new console window.'}
                      </span>
                    </div>
                    {daCheck.configYamlPath && (
                      <div className="text-xs text-text-dim">
                        Config will be written to{' '}
                        <span className="font-mono">{daCheck.configYamlPath}</span>
                        {daCheck.configYamlExists && (
                          <span className="ml-1 text-success">(already exists — running the wizard overwrites it)</span>
                        )}
                      </div>
                    )}
                  </div>
                )}

                {/* Auto-apply Coastal's sane-pricing patch on every update.
                    When checked, after each Install the tool re-downloads the
                    source tarball alongside the binary and rebuilds dune-admin
                    locally with the patch on top. Uncheck and click Install
                    again to revert to upstream. */}
                <label className="flex items-start gap-3 pt-3 border-t border-border cursor-pointer">
                  <input
                    type="checkbox"
                    className="mt-0.5 h-4 w-4 accent-accent"
                    checked={autoApply}
                    disabled={autoApplySaving}
                    onChange={e => void onToggleAutoApply(e.target.checked)}
                  />
                  <span className="text-xs">
                    <span className="font-medium text-text">
                      Keep Coastal's sane-pricing patch applied after each update
                    </span>
                    <span className="block text-text-dim mt-0.5">
                      When checked, the tool also downloads the source tarball with each
                      release and rebuilds <span className="font-mono">dune-admin.exe</span> locally
                      with the 100k-cap pricing patch. Uncheck and click Install again to revert
                      to the upstream binary. Requires <span className="font-mono">go</span> and
                      {' '}<span className="font-mono">git</span> on PATH.
                    </span>
                  </span>
                  {autoApplySaving && <Icon name="Loader2" size={14} className="animate-spin text-text-dim" />}
                </label>

                {/* v6.3.0: gamble die config for the sane-pricing patch. The
                    patch rolls a die per candidate listing and only buys on the
                    target number, throttling buys. Die size + target are baked
                    into the patched binary at build time, so changes take effect
                    on the NEXT (re)apply — click Install with the box above
                    checked to rebuild. */}
                <div className="pt-3 border-t border-border">
                  <div className="text-xs font-medium text-text mb-1">Pricing-patch buy odds (gamble die)</div>
                  <div className="text-xs text-text-dim mb-2">
                    The bot rolls a 1–N die per candidate listing and only buys when it
                    hits the target number — a roughly 1-in-N chance per listing. Higher
                    die size = fewer buys. Defaults (12 / 5) match the original patch.
                  </div>
                  <div className="flex flex-wrap items-end gap-3">
                    <label className="text-xs">
                      <span className="block text-text-dim mb-1">Die size (N)</span>
                      <input
                        type="number"
                        min={2}
                        className="w-24 px-2 py-1 rounded bg-bg border border-border text-text text-xs"
                        value={dieInput}
                        disabled={dieSaving}
                        onChange={e => setDieInput(e.target.value)}
                      />
                    </label>
                    <label className="text-xs">
                      <span className="block text-text-dim mb-1">Buy on roll</span>
                      <input
                        type="number"
                        min={1}
                        className="w-24 px-2 py-1 rounded bg-bg border border-border text-text text-xs"
                        value={targetInput}
                        disabled={dieSaving}
                        onChange={e => setTargetInput(e.target.value)}
                      />
                    </label>
                    <button
                      type="button"
                      className="px-3 py-1.5 rounded bg-accent text-bg text-xs font-medium disabled:opacity-50"
                      disabled={dieSaving || !dieValid || !targetValid || !dieDirty}
                      onClick={() => void onSaveDie()}
                    >
                      {dieSaving ? 'Saving...' : 'Save odds'}
                    </button>
                  </div>
                  {(!dieValid || !targetValid) && (
                    <div className="text-xs text-danger mt-1.5">
                      Die size must be ≥ 2, and buy-on-roll must be between 1 and the die size.
                    </div>
                  )}
                  {dieValid && targetValid && dieDirty && (
                    <div className="text-xs text-warning mt-1.5">
                      Save, then click Install (with the patch box above checked) to rebuild
                      <span className="font-mono"> dune-admin.exe</span> with the new odds.
                    </div>
                  )}
                </div>

                {/* v6.1.25: pricing-patch rebuild status panel. Shows when
                    /install kicks off the detached background rebuild. The
                    binary install is already complete by the time this card
                    appears — this is JUST the local Go build with the
                    sane-pricing patch on top. */}
                {daPatch && daPatch.status && daPatch.status !== 'idle' && (
                  <div className="pt-3 border-t border-border">
                    <div className="flex items-center gap-2 mb-1.5">
                      <Icon
                        name={daPatch.status === 'running' ? 'Loader2' : daPatch.status === 'success' ? 'CheckCircle2' : 'AlertCircle'}
                        size={14}
                        className={`${daPatch.status === 'running' ? 'animate-spin text-accent' : daPatch.status === 'success' ? 'text-success' : 'text-danger'}`}
                      />
                      <span className="text-xs font-medium">
                        {daPatch.status === 'running' && (
                          <>Rebuilding patched dune-admin{daPatch.targetTag ? ` (${daPatch.targetTag})` : ''}...</>
                        )}
                        {daPatch.status === 'success' && (
                          <>Patched build complete{daPatch.targetTag ? ` (${daPatch.targetTag})` : ''}.</>
                        )}
                        {daPatch.status === 'failed' && (
                          <>Patched build failed{daPatch.exitCode != null ? ` (exit ${daPatch.exitCode})` : ''}.</>
                        )}
                      </span>
                      {daPatch.status === 'running' && daPatch.startedAt && (
                        <span className="text-[10px] text-text-dim font-mono">
                          {(() => {
                            const started = new Date(daPatch.startedAt).getTime()
                            const secs = Math.max(0, Math.floor((Date.now() - started) / 1000))
                            const mm = Math.floor(secs / 60).toString().padStart(2, '0')
                            const ss = (secs % 60).toString().padStart(2, '0')
                            return `${mm}:${ss} elapsed`
                          })()}
                        </span>
                      )}
                    </div>
                    {daPatch.status === 'running' && (
                      <p className="text-[11px] text-text-dim mb-2">
                        Safe to leave this page open or navigate away — the build runs in a detached
                        background process. The Install button reactivates immediately so the rest of
                        the tool stays responsive.
                      </p>
                    )}
                    {daPatch.error && (
                      <p className="text-[11px] text-danger break-words">{daPatch.error}</p>
                    )}
                    {daPatch.logTail && (
                      <pre className="text-[10px] font-mono bg-bg-dim border border-border rounded p-2 mt-1 max-h-40 overflow-auto whitespace-pre-wrap">
                        {daPatch.logTail}
                      </pre>
                    )}
                    {daPatch.logFile && (
                      <div className="text-[10px] text-text-dim font-mono break-all mt-1">
                        Log: {daPatch.logFile}
                      </div>
                    )}
                  </div>
                )}
              </div>
            )}

            {daMsg && (
              <div className="text-sm border-t border-border pt-3 text-success flex items-center gap-2">
                <Icon name="CheckCircle2" size={14} /> {daMsg}
              </div>
            )}
            {daErr && (
              <div className="text-sm border-t border-border pt-3 text-danger flex items-center gap-2">
                <Icon name="AlertCircle" size={14} /> {daErr}
              </div>
            )}

            {/* Testing-only: wipe all market listings on the VM. */}
            <div className="border-t border-border pt-3 mt-1">
              <div className="rounded-lg border border-danger/40 bg-danger/5 p-3">
                <h4 className="text-sm font-semibold text-danger flex items-center gap-2">
                  <Icon name="TriangleAlert" size={14} /> For Testing Only — Will WIPE ALL LISTINGS
                </h4>
                <p className="text-xs text-muted mt-1">
                  Deletes every market-bot listing on the VM. The bot re-lists from scratch with
                  freshly-computed prices on its next listing tick. Requires the VM to be running.
                </p>
                <label className="mt-2 flex items-center gap-2 cursor-pointer select-none text-sm">
                  <input
                    type="checkbox"
                    checked={wipeApprove}
                    disabled={wiping}
                    onChange={e => setWipeApprove(e.target.checked)}
                  />
                  I approve — wipe all listings
                </label>
                <button
                  type="button"
                  onClick={() => void onWipeListings()}
                  disabled={!wipeApprove || wiping}
                  className="btn-danger mt-2 disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  <Icon name={wiping ? 'Loader2' : 'Trash2'} size={14} className={wiping ? 'animate-spin' : ''} />
                  {wiping ? 'Wiping…' : 'Wipe all listings'}
                </button>
                {wipeMsg && (
                  <p className="mt-2 text-xs text-success flex items-center gap-1.5">
                    <Icon name="CheckCircle2" size={13} /> {wipeMsg}
                  </p>
                )}
                {wipeErr && (
                  <p className="mt-2 text-xs text-danger flex items-center gap-1.5">
                    <Icon name="AlertCircle" size={13} /> {wipeErr}
                  </p>
                )}
              </div>
            </div>
          </div>
        )}
      </div>

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
