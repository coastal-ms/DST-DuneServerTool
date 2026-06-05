import { useState, useEffect, useRef, useCallback, type FormEvent } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { api } from '../api/client'
import type { ConfigResponse } from '../api/types'
import { checkForUpdate, installUpdate, type UpdateCheck } from '../api/update'
import {
  checkDuneAdminUpdate,
  installDuneAdminUpdate,
  pricingPatchStatus,
  pricingPatchPending,
  applyPendingPricingPatch,
  runDuneAdminSetup,
  getDuneAdminDotFolder,
  deleteDuneAdminDotFolder,
  getDuneAdminDiagnostics,
  type DuneAdminCheck,
  type DuneAdminPricingPatchStatus,
  type DuneAdminDiagnostics,
} from '../api/duneAdmin'
import { fmtToolVersion } from '../format'
import { DependencyInstallModal } from '../components/DependencyInstallModal'
import { getDependencies, type SystemDependency } from '../api/dependencies'
import { AppearanceCard } from './settings/AppearanceCard'

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

  // "Generate new SSH key" — runs the rotate-ssh-key command, waits for it to
  // finish, then propagates the fresh key everywhere DST uses it.
  const [sshRotating, setSshRotating] = useState(false)
  const [sshRotateMsg, setSshRotateMsg] = useState<string | null>(null)
  async function onRotateSshKey() {
    if (!window.confirm('Generate a NEW SSH key?\n\nThis regenerates the key, authorizes it on the dune-awakening VM, and copies it into the dune-admin folder. The VM must be running. A console window will open and may ask for admin approval.')) return
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

  // dune-admin.exe update card state
  const [daCheck, setDaCheck] = useState<DuneAdminCheck | null>(null)
  const [daChecking, setDaChecking] = useState(false)
  const [daInstalling, setDaInstalling] = useState(false)
  const [daMsg, setDaMsg] = useState<string | null>(null)
  const [daErr, setDaErr] = useState<string | null>(null)

  // dune-admin diagnostics panel state
  const [daDiag, setDaDiag] = useState<DuneAdminDiagnostics | null>(null)
  const [daDiagRunning, setDaDiagRunning] = useState(false)
  const [daDiagErr, setDaDiagErr] = useState<string | null>(null)
  const [daDiagCopied, setDaDiagCopied] = useState(false)

  // In-app confirmation modal for the stale .dune-admin folder preflight.
  // We DO NOT use window.confirm() here: it is fired after an `await` (the
  // folder-existence fetch), at which point the browser's user-activation from
  // the button click has expired. Chrome/Edge then suppress the dialog and
  // return TRUE silently — which auto-deleted the folder without ever asking.
  // A React modal needs no user activation, so it always renders.
  const [dotPrompt, setDotPrompt] = useState<{
    path: string
    lead: string
    resolve: (choice: 'delete' | 'keep' | 'cancel') => void
  } | null>(null)

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
          // If a reinstall deleted the stale .dune-admin folder, open dune-admin
          // now that the rebuild has finished so the running exe didn't lock it.
          if (pendingDaLaunchRef.current) {
            pendingDaLaunchRef.current = false
            void launchDuneAdminApp()
          }
        }
      } catch { /* keep polling; transient server hiccup */ }
    }
    void tick()
    const id = window.setInterval(() => { void tick() }, 2000)
    return () => { cancelled = true; window.clearInterval(id) }
  }, [daPatchPolling])

  // Deferred pricing patch: when a reinstall deletes ~/.dune-admin, the rebuild
  // is held until dune-admin is reconfigured (config.yaml gone + setup wizard
  // locks the exe). We poll /pricing-patch-pending; once dune-admin is
  // configured AND listening (after setup it goes straight to a working
  // console), we apply the pending patch — which stops the exe, rebuilds, and
  // relaunches — then hand off to the normal status poll.
  const [daPatchPendingPolling, setDaPatchPendingPolling] = useState(false)
  useEffect(() => {
    if (!daPatchPendingPolling) return
    let cancelled = false
    const tick = async () => {
      try {
        const p = await pricingPatchPending()
        if (cancelled) return
        if (!p.pending) { setDaPatchPendingPolling(false); return }
        if (p.configured && p.listening) {
          setDaPatchPendingPolling(false)
          setDaMsg(prev => (prev ? prev + ' ' : '') + 'dune-admin setup detected — applying the sane-pricing patch now…')
          try {
            const r = await applyPendingPricingPatch()
            const pp = r.pricingPatch
            if (r.applied && pp && pp.status === 'running') {
              setDaPatch(pp)
              setDaPatchPolling(true)
            } else if (pp && pp.status === 'failed') {
              setDaErr(prev => (prev ? prev + ' ' : '') + `Pricing rebuild failed to start: ${pp.error ?? 'unknown error'}`)
            } else if (!r.applied) {
              // Not ready after all — resume polling.
              setDaPatchPendingPolling(true)
            }
          } catch (e) {
            setDaErr(prev => (prev ? prev + ' ' : '') + `Could not apply deferred pricing patch: ${e instanceof Error ? e.message : String(e)}`)
          }
        }
      } catch { /* keep polling; transient server hiccup */ }
    }
    void tick()
    const id = window.setInterval(() => { void tick() }, 3000)
    return () => { cancelled = true; window.clearInterval(id) }
  }, [daPatchPendingPolling])

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

  async function onRunDuneAdminDiagnostics() {
    setDaDiagRunning(true)
    setDaDiagErr(null)
    setDaDiagCopied(false)
    try {
      setDaDiag(await getDuneAdminDiagnostics())
    } catch (e) {
      setDaDiagErr(e instanceof Error ? e.message : String(e))
    } finally {
      setDaDiagRunning(false)
    }
  }

  async function onCopyDiagnostics() {
    if (!daDiag) return
    try {
      await navigator.clipboard.writeText(JSON.stringify(daDiag, null, 2))
      setDaDiagCopied(true)
      window.setTimeout(() => setDaDiagCopied(false), 2500)
    } catch {
      setDaDiagErr('Could not copy to clipboard — select the report text manually.')
    }
  }

  // Install/setup preflight: on first-time install, a folder change, OR a
  // same-folder reinstall, a %USERPROFILE%\.dune-admin config folder may hold
  // stale DB/host pointers that make the market bot fail. We ALWAYS ask before
  // deleting — never auto-delete. Returns true to proceed with the
  // install/setup regardless of the user's choice (declining just keeps it).
  async function preflightStaleDotFolder(): Promise<{ proceed: boolean; deleted: boolean }> {
    let deleted = false
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
      if (!pf.exists) return { proceed: true, deleted }

      const lead = isFirstTime
        ? `You're setting up dune-admin.`
        : folderChanged
          ? `You're changing the dune-admin install folder.`
          : `You're reinstalling dune-admin.`

      const choice = await new Promise<'delete' | 'keep' | 'cancel'>((resolve) => {
        setDotPrompt({ path: pf.path, lead, resolve })
      })
      setDotPrompt(null)

      if (choice === 'cancel') return { proceed: false, deleted }
      if (choice === 'delete') {
        const r = await deleteDuneAdminDotFolder()
        if (r.ok && r.deleted) {
          deleted = true
          const patchNote = autoApply
            ? ' Heads-up: the sane-pricing patch won\u2019t deploy until dune-admin is reconfigured \u2014 it\u2019ll apply automatically once you finish setup.'
            : ''
          setDaMsg(`Removed stale config folder ${r.path}. dune-admin will create a fresh one during setup.${patchNote}`)
        }
      }
    } catch (e) {
      // Non-fatal — surface the issue but let the install proceed.
      setDaErr(`Stale-folder preflight failed: ${e instanceof Error ? e.message : String(e)}`)
    }
    return { proceed: true, deleted }
  }

  // After the user confirms deleting the stale .dune-admin config folder during
  // a reinstall, the market bot's config + DB pointers are gone — so we open
  // dune-admin afterward to let them re-run market-bot setup. Deferred until any
  // pricing-patch rebuild finishes so the running exe doesn't lock the rebuild's
  // output. Tracked via a ref so the patch-poll effect can fire it.
  // Reusable dependency-install popup. When a feature needs go/git/node and
  // they're missing, we surface this instead of letting the build fail; the
  // user can install them via winget and we then continue automatically.
  const [depPrompt, setDepPrompt] = useState<{
    deps: SystemDependency[]
    wingetAvailable: boolean
    context: string
    onResolved: () => void
  } | null>(null)

  const pendingDaLaunchRef = useRef(false)
  const launchDuneAdminApp = useCallback(async () => {
    try {
      await api('/api/commands/run/dune-admin', { method: 'POST' })
      setDaMsg(prev => (prev ? prev + ' ' : '') + 'Opened dune-admin so you can re-setup the market bot.')
    } catch (e) {
      setDaErr(prev => (prev ? prev + ' ' : '') + `Could not open dune-admin automatically: ${e instanceof Error ? e.message : String(e)}`)
    }
  }, [])

  async function onInstallDuneAdmin(skipDepCheck = false) {
    setDaInstalling(true)
    setDaErr(null)
    setDaMsg(null)
    setDaPatch(null)
    setDaPatchPolling(false)
    try {
      // When the sane-pricing patch is kept, /install triggers a local rebuild
      // that needs go + git + node. Detect missing tools UP FRONT and offer to
      // install them, rather than letting the background build fail with a
      // "X was not found" log the user has to decipher. Once installed, we
      // continue the install automatically (skipDepCheck avoids re-prompting).
      if (autoApply && !skipDepCheck) {
        try {
          const dc = await getDependencies(['go', 'git', 'node'])
          const missing = dc.dependencies.filter(d => !d.found)
          if (missing.length > 0) {
            setDaInstalling(false)
            setDepPrompt({
              deps: missing,
              wingetAvailable: dc.wingetAvailable,
              context: 'Keeping the sane-pricing patch rebuilds dune-admin locally (with its web UI), which needs these tools.',
              onResolved: () => { setDepPrompt(null); void onInstallDuneAdmin(true) },
            })
            return
          }
        } catch { /* dependency probe failed — fall through and let the build surface it */ }
      }
      const { proceed, deleted } = await preflightStaleDotFolder()
      if (!proceed) { setDaMsg('Reinstall cancelled — nothing was changed.'); return }
      const r = await installDuneAdminUpdate()
      if (r.ok) {
        if (r.skipped) {
          // Idea 7: already the patched build for this version + gamble config.
          // Nothing was downloaded, overwritten, or rebuilt.
          setDaMsg(r.note ?? `dune-admin is already up to date and patched (v${r.toVersion}). Nothing to do.`)
          try { setDaCheck(await checkDuneAdminUpdate({ force: false })) } catch { /* non-fatal */ }
          return
        }
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
        const patchRunning = !!(r.pricingPatch && r.pricingPatch.status === 'running')
        const patchDeferred = !!(r.pricingPatch && r.pricingPatch.status === 'deferred')
        if (patchRunning) {
          setDaPatch(r.pricingPatch!)
          setDaPatchPolling(true)
        } else if (patchDeferred) {
          // User deleted ~/.dune-admin, so dune-admin isn't configured yet. The
          // patch is held until they finish setup; poll until dune-admin comes
          // up, then apply it automatically.
          setDaPatch(r.pricingPatch!)
          setDaPatchPendingPolling(true)
          setDaMsg(prev => (prev ? prev + ' ' : '')
            + 'The sane-pricing patch will deploy automatically once you finish dune-admin setup (it can\u2019t rebuild while setup is running). Leave this page open.')
        } else if (r.pricingPatch && r.pricingPatch.status === 'failed') {
          setDaErr(`Pricing rebuild failed to start: ${r.pricingPatch.error ?? 'unknown error'}`)
        }
        // Re-check so the displayed installed version updates.
        try {
          setDaCheck(await checkDuneAdminUpdate({ force: false }))
        } catch { /* non-fatal */ }
        // The user deleted the stale config folder, so the market bot needs to
        // be set up again — open dune-admin for them. If a pricing-patch rebuild
        // is still running, defer the launch (the patch-poll effect fires it)
        // so the running exe doesn't lock the rebuild's output file.
        if (deleted) {
          if (patchRunning) pendingDaLaunchRef.current = true
          else await launchDuneAdminApp()
        }
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
      const { proceed } = await preflightStaleDotFolder()
      if (!proceed) { setDaMsg('Setup cancelled — nothing was changed.'); return }
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
        setValues({ ...out.values })
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
    // Resume a deferred pricing patch left waiting from a prior session: if a
    // pending marker still exists, keep polling until dune-admin is configured
    // and then apply it. Survives a server/UI restart mid-setup.
    void (async () => {
      try {
        const p = await pricingPatchPending()
        if (p && p.pending) setDaPatchPendingPolling(true)
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
                      onClick={() => onInstallDuneAdmin()}
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
                      to the upstream binary. Requires <span className="font-mono">go</span>,
                      {' '}<span className="font-mono">git</span>, and
                      {' '}<span className="font-mono">node</span> (with{' '}
                      <span className="font-mono">pnpm</span>, auto-enabled via corepack) on PATH —
                      node builds the embedded web UI so the dune-admin portal and Market Bot panel load.
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
                        name={daPatch.status === 'running' ? 'Loader2' : daPatch.status === 'success' ? 'CheckCircle2' : daPatch.status === 'deferred' ? 'Clock' : 'AlertCircle'}
                        size={14}
                        className={`${daPatch.status === 'running' ? 'animate-spin text-accent' : daPatch.status === 'success' ? 'text-success' : daPatch.status === 'deferred' ? 'text-accent' : 'text-danger'}`}
                      />
                      <span className="text-xs font-medium">
                        {daPatch.status === 'running' && (
                          <>Rebuilding patched dune-admin{daPatch.targetTag ? ` (${daPatch.targetTag})` : ''}...</>
                        )}
                        {daPatch.status === 'success' && (
                          <>Patched build complete{daPatch.targetTag ? ` (${daPatch.targetTag})` : ''}.</>
                        )}
                        {daPatch.status === 'deferred' && (
                          <>Sane-pricing patch waiting for dune-admin setup…</>
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
                    {daPatch.status === 'deferred' && (
                      <p className="text-[11px] text-text-dim mb-2">
                        {daPatch.reason ?? 'The patch can\u2019t rebuild while dune-admin setup is running.'} Keep
                        this page open — once setup finishes and dune-admin is up, the patch applies
                        automatically (it briefly stops dune-admin to swap in the patched build).
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

            {/* --- Troubleshooting / diagnostics ------------------------------
                One-shot health report: backend reachability, config.yaml vs
                env precedence, sidecar shadowing, duplicate instances (market-
                bot DB lock), and pricing-patch state. The Copy button lets a
                user paste the full report back for support. */}
            <div className="border-t border-border pt-3 mt-1">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                  <Icon name="Stethoscope" size={16} className="text-text-muted" />
                  <h4 className="text-sm font-semibold">Troubleshoot dune-admin</h4>
                </div>
                <button
                  type="button"
                  onClick={() => void onRunDuneAdminDiagnostics()}
                  disabled={daDiagRunning}
                  className="btn-secondary shrink-0"
                >
                  <Icon name={daDiagRunning ? 'Loader2' : 'Activity'} size={15} className={daDiagRunning ? 'animate-spin' : ''} />
                  {daDiagRunning ? 'Running…' : 'Run diagnostics'}
                </button>
              </div>
              <p className="text-xs text-text-dim mt-1">
                Checks whether the dune-admin backend is actually running and reachable, and flags
                the usual causes of <span className="font-mono">Failed to fetch</span> — wrong listen
                port, stale <span className="font-mono">~/.dune-admin</span> config, env-var overrides,
                duplicate instances (which lock the market-bot DB), and pricing-patch build problems.
              </p>

              {daDiagErr && (
                <p className="mt-2 text-xs text-danger flex items-center gap-1.5">
                  <Icon name="AlertCircle" size={13} /> {daDiagErr}
                </p>
              )}

              {daDiag && (
                <div className="mt-3 space-y-3">
                  <div className="flex items-center gap-2">
                    <span className={
                      daDiag.verdict === 'error' ? 'pill-warning' : daDiag.verdict === 'warn' ? 'pill-warning' : 'pill-success'
                    }>
                      {daDiag.verdict === 'error' ? 'Problems found' : daDiag.verdict === 'warn' ? 'Warnings' : 'All good'}
                    </span>
                    <span className="text-[10px] text-text-dim font-mono">
                      {daDiag.machine ? `${daDiag.machine} · ` : ''}{new Date(daDiag.generatedAt).toLocaleString()}
                    </span>
                    <button
                      type="button"
                      onClick={() => void onCopyDiagnostics()}
                      className="btn-secondary ml-auto"
                      title="Copy the full JSON report to share for support"
                    >
                      <Icon name={daDiagCopied ? 'ClipboardCheck' : 'Copy'} size={14} className={daDiagCopied ? 'text-success' : ''} />
                      {daDiagCopied ? 'Copied' : 'Copy report'}
                    </button>
                  </div>

                  <ul className="space-y-1.5">
                    {daDiag.findings.map((f, i) => {
                      const iconName = f.level === 'error' ? 'AlertCircle'
                        : f.level === 'warn' ? 'TriangleAlert'
                        : f.level === 'ok' ? 'CheckCircle2' : 'Info'
                      const color = f.level === 'error' ? 'text-danger'
                        : f.level === 'warn' ? 'text-warning'
                        : f.level === 'ok' ? 'text-success' : 'text-text-muted'
                      return (
                        <li key={i} className="text-xs flex items-start gap-2">
                          <Icon name={iconName} size={13} className={`mt-0.5 shrink-0 ${color}`} />
                          <span>
                            <span className={color}>{f.message}</span>
                            {f.hint && <span className="block text-text-dim mt-0.5">{f.hint}</span>}
                          </span>
                        </li>
                      )
                    })}
                  </ul>

                  <div className="grid grid-cols-2 gap-x-4 gap-y-1 text-[11px] font-mono text-text-dim border-t border-border pt-2">
                    <span>backend listening</span>
                    <span className={daDiag.listener.listening ? 'text-success' : 'text-danger'}>
                      {daDiag.listener.listening ? `yes (:${daDiag.listener.port})` : `no (:${daDiag.listener.port})`}
                    </span>
                    <span>http probe</span>
                    <span className={daDiag.httpProbe.ok ? (daDiag.httpProbe.statusCode === 404 ? 'text-warning' : 'text-success') : 'text-danger'}>
                      {daDiag.httpProbe.ok
                        ? (daDiag.httpProbe.statusCode === 404
                            ? 'HTTP 404 · no web UI embedded'
                            : `up${daDiag.httpProbe.statusCode ? ` (HTTP ${daDiag.httpProbe.statusCode})` : ''}`)
                        : (daDiag.httpProbe.error ?? 'failed')}
                    </span>
                    <span>instances running</span>
                    <span className={daDiag.processes.multipleInstances ? 'text-danger' : 'text-text'}>
                      {daDiag.processes.count}{daDiag.processes.multipleInstances ? ' (too many)' : ''}
                    </span>
                    <span>config.yaml</span>
                    <span className={daDiag.config.exists ? 'text-text' : 'text-warning'}>
                      {daDiag.config.exists ? (daDiag.config.dbPassSet ? 'present' : 'present, db_pass empty') : 'missing'}
                    </span>
                    <span>listen_addr</span>
                    <span className="text-text">{daDiag.effective.listenAddr || ':8080 (default)'}</span>
                    <span>market bot</span>
                    {(() => {
                      // Prefer the backend's derived status (trusts the cache-DB
                      // lock as proof the bot is running, regardless of the
                      // legacy config.yaml proxy keys). Fall back to the old
                      // key-based label for older backends.
                      const running = daDiag.marketBot.running ?? (daDiag.marketBot.cacheDbExists && daDiag.marketBot.cacheDbLocked)
                      const status = daDiag.marketBot.status
                        ?? (running ? 'running' : (daDiag.marketBot.addrConfigured || daDiag.marketBot.containerConfigured ? 'configured' : 'not configured'))
                      const cls = status === 'running' ? 'text-success' : status === 'configured' ? 'text-text' : 'text-text-dim'
                      return (
                        <span className={cls}>
                          {status}
                          {daDiag.marketBot.cacheDbLocked && status !== 'running' ? ' · cache locked' : ''}
                        </span>
                      )
                    })()}
                    <span>pricing patch</span>
                    <span className="text-text">
                      {daDiag.pricing.status}
                      {daDiag.pricing.autoApply ? ` · auto (go ${daDiag.pricing.goAvailable ? 'ok' : 'missing'})` : ''}
                    </span>
                  </div>

                  {daDiag.pricing.logTail && (
                    <pre className="text-[10px] font-mono bg-bg-dim border border-border rounded p-2 max-h-32 overflow-auto whitespace-pre-wrap">
                      {daDiag.pricing.logTail}
                    </pre>
                  )}
                </div>
              )}
            </div>
          </div>
        )}
      </div>

      <AppearanceCard />

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

      {depPrompt && (
        <DependencyInstallModal
          deps={depPrompt.deps}
          wingetAvailable={depPrompt.wingetAvailable}
          context={depPrompt.context}
          onCancel={() => setDepPrompt(null)}
          onAllResolved={depPrompt.onResolved}
        />
      )}

      {dotPrompt && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4"
          onClick={() => dotPrompt.resolve('keep')}
        >
          <div className="card p-0 max-w-md w-full" onClick={e => e.stopPropagation()}>
            <div className="px-5 py-4 border-b border-border flex items-center justify-between">
              <h3 className="font-semibold text-text flex items-center gap-2">
                <Icon name="AlertTriangle" size={16} className="text-warning" />
                Stale dune-admin config folder
              </h3>
              <button type="button" className="btn-ghost px-2 py-1" onClick={() => dotPrompt.resolve('cancel')}>
                <Icon name="X" size={16} />
              </button>
            </div>

            <div className="px-5 py-4 space-y-3 text-sm text-text leading-relaxed">
              <div>{dotPrompt.lead}</div>
              <div>
                An existing dune-admin config folder was found at:
                <div className="mt-1 font-mono text-xs text-text-muted break-all">{dotPrompt.path}</div>
              </div>
              <div className="text-text-muted">
                dune-admin's market bot reads its config and database pointers from this
                folder. If it holds stale settings, the market bot can{' '}
                <span className="font-semibold text-warning">fail to start</span>. Deleting it
                lets dune-admin regenerate a clean one during setup.
              </div>
            </div>

            <div className="px-5 py-4 border-t border-border flex items-center justify-end gap-2">
              <button type="button" className="btn-ghost" onClick={() => dotPrompt.resolve('cancel')}>
                Cancel
              </button>
              <button type="button" className="btn-ghost" onClick={() => dotPrompt.resolve('keep')}>
                Keep &amp; continue
              </button>
              <button
                type="button"
                className="btn-primary !bg-danger hover:!bg-danger/90"
                onClick={() => dotPrompt.resolve('delete')}
              >
                <Icon name="Trash2" size={15} />
                Delete &amp; continue
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  )
}
