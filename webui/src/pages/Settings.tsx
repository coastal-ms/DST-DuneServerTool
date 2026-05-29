import { useState, useEffect, type FormEvent } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { api } from '../api/client'
import type { ConfigResponse } from '../api/types'
import { checkForUpdate, installUpdate, type UpdateCheck } from '../api/update'
import {
  checkDuneAdminUpdate,
  installDuneAdminUpdate,
  runDuneAdminSetup,
  type DuneAdminCheck,
} from '../api/duneAdmin'

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

  // dune-admin.exe update card state
  const [daCheck, setDaCheck] = useState<DuneAdminCheck | null>(null)
  const [daChecking, setDaChecking] = useState(false)
  const [daInstalling, setDaInstalling] = useState(false)
  const [daMsg, setDaMsg] = useState<string | null>(null)
  const [daErr, setDaErr] = useState<string | null>(null)

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

  async function onInstallDuneAdmin() {
    setDaInstalling(true)
    setDaErr(null)
    setDaMsg(null)
    try {
      const r = await installDuneAdminUpdate()
      if (r.ok) {
        setDaMsg(`dune-admin.exe replaced with v${r.toVersion}. Restart any running instance.`)
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
      const r = await runDuneAdminSetup()
      if (r.ok) {
        const installedPart = r.didInstall ? 'Downloaded + installed dune-admin.exe, then ' : ''
        setDaMsg(`${installedPart}opened the dune-admin setup wizard in a console window. Answer the prompts there — dune-admin will auto-launch when the wizard finishes.`)
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
        setValues(out.values)
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
            <h2 className="text-lg font-semibold">Dune Server updates</h2>
          </div>
          <div className="flex items-center gap-2">
            {updCheck && (
              <>
                <span className="pill-muted text-xs">v{updCheck.currentVersion}</span>
                {updCheck.available && updCheck.latestVersion && (
                  <span className="pill-warning text-xs">v{updCheck.latestVersion} available</span>
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
                Checks <span className="font-mono">Icehunter/dune-admin</span> releases and replaces the EXE at the <span className="font-mono">DuneAdminExe</span> path below.
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
    </>
  )
}
