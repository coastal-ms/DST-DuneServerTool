import { useCallback, useEffect, useState, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { api, ApiError } from '../api/client'
import { getPreflight, getSetupConfig, getHyperVLan, saveHyperVLan, testHyperVLan, getHyperVLanCredential, saveHyperVLanCredential, getHyperVLanHostResources, startHyperVLanInstall, getHyperVLanInstallStatus, type PreflightResult, type SetupConfigSummary, type HyperVLanTest, type HyperVLanHostResources, type HyperVLanInstallStatus } from '../api/setup'

// The wizard branches on a single up-front question: does the operator already
// have a Dune Awakening battlegroup running (their own VM, or one a previous
// install left behind), or do they need DST to provision one from scratch?
//   - 'existing' → skip the VM import entirely; just make sure DST can reach the
//                  server (locate or generate+authorize the SSH key).
//   - 'fresh'    → the original flow that runs Funcom's initial-setup.
//   - 'lan'      → the VM lives on a SEPARATE Hyper-V host on the LAN; point DST
//                  at that host, then connect to the guest over SSH as usual.
type SetupMode = 'existing' | 'fresh' | 'lan'

interface Step {
  title: string
  subtitle: string
  render: () => ReactNode
}

const FRESH_STEPS: Step[] = [
  { title: 'Pre-flight',    subtitle: 'Environment checks',     render: () => <Step1Preflight /> },
  { title: 'Configuration', subtitle: 'Confirm tool settings',  render: () => <Step2Config /> },
  { title: 'Install',       subtitle: 'Import Hyper-V VM',       render: () => <Step3Install /> },
  { title: 'Security',      subtitle: 'SSH + firewall',          render: () => <Step4Security /> },
  { title: 'Networking',    subtitle: 'Ports + DNS',             render: () => <Step5Networking /> },
  { title: 'Finalize',      subtitle: 'Wrap-up',                 render: () => <Step6Finalize /> },
]

const EXISTING_STEPS: Step[] = [
  { title: 'Pre-flight',  subtitle: 'Environment checks',       render: () => <Step1Preflight existing /> },
  { title: 'Connect',     subtitle: 'Point DST at your server', render: () => <StepConnectExisting /> },
  { title: 'Security',    subtitle: 'SSH + firewall',            render: () => <Step4Security /> },
  { title: 'Networking',  subtitle: 'Ports + DNS',               render: () => <Step5Networking /> },
  { title: 'Finalize',    subtitle: 'Wrap-up',                   render: () => <Step6Finalize /> },
]

const LAN_STEPS: Step[] = [
  { title: 'Pre-flight',  subtitle: 'Environment checks',       render: () => <Step1Preflight mode="lan" /> },
  { title: 'Hyper-V host',subtitle: 'Point DST at the LAN host',render: () => <StepConnectLan /> },
  { title: 'Install VM',  subtitle: 'Provision on the host',    render: () => <StepInstallLan /> },
  { title: 'Connect',     subtitle: 'SSH to the VM',            render: () => <StepConnectExisting /> },
  { title: 'Networking',  subtitle: 'Ports + DNS',               render: () => <Step5Networking /> },
  { title: 'Finalize',    subtitle: 'Wrap-up',                   render: () => <Step6Finalize /> },
]

function FixBlock({ fix }: { fix: string }) {
  const [copied, setCopied] = useState(false)
  const lines = fix.split('\n')
  const caption = lines.length > 1 ? lines.slice(0, -1).join(' ') : 'Run this command:'
  const command = lines[lines.length - 1]
  const copy = () => {
    void navigator.clipboard?.writeText(command).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    })
  }
  return (
    <div className="mt-2">
      <div className="text-xs text-text-dim mb-1">{caption}</div>
      <div className="flex items-stretch gap-2">
        <code className="flex-1 min-w-0 text-xs font-mono bg-surface border border-border rounded px-2 py-1.5 overflow-x-auto whitespace-pre">{command}</code>
        <button
          type="button"
          onClick={copy}
          className="btn-secondary shrink-0 !px-2 !py-1 text-xs"
          title="Copy to clipboard"
        >
          <Icon name={copied ? 'Check' : 'Copy'} size={14} /> {copied ? 'Copied' : 'Copy'}
        </button>
      </div>
    </div>
  )
}

export function SetupWizard() {
  const [mode, setMode]       = useState<SetupMode | null>(null)
  const [current, setCurrent] = useState(1)
  const [done, setDone]       = useState<Set<number>>(new Set())

  const steps = mode === 'existing' ? EXISTING_STEPS : mode === 'lan' ? LAN_STEPS : FRESH_STEPS

  const pick = useCallback((m: SetupMode) => { setMode(m); setCurrent(1); setDone(new Set()) }, [])
  const restart = useCallback(() => { setMode(null); setCurrent(1); setDone(new Set()) }, [])
  const goNext = useCallback(() => {
    setDone(d => new Set(d).add(current))
    setCurrent(c => Math.min(c + 1, steps.length))
  }, [current, steps.length])
  const goBack = useCallback(() => {
    if (current <= 1) { restart(); return }
    setCurrent(c => c - 1)
  }, [current, restart])
  const skip = useCallback(() => { setCurrent(c => Math.min(c + 1, steps.length)) }, [steps.length])

  return (
    <>
      <PageHeader
        title="Setup Wizard"
        icon="Wand2"
        description="Guided setup for your Dune Awakening server — whether you're installing fresh or already have one running."
      />
      {mode === null ? (
        <BranchChooser onPick={pick} />
      ) : (
        <>
          <StepIndicator steps={steps} current={current} done={done} />
          <div className="card p-6">
            {steps[current - 1].render()}
          </div>
          <div className="flex items-center justify-between mt-4 pt-3 border-t border-border">
            <button className="btn-secondary" onClick={goBack}>
              <Icon name="ArrowLeft" size={14} /> {current <= 1 ? 'Change path' : 'Back'}
            </button>
            <div className="text-xs text-text-dim">
              Step {current} of {steps.length}: {steps[current - 1].title}
            </div>
            <div className="flex gap-2">
              {current < steps.length && (
                <button className="btn-ghost" onClick={skip}>Skip step</button>
              )}
              <button className="btn-primary" onClick={goNext}>
                {current >= steps.length ? 'Finish' : (<>Next <Icon name="ArrowRight" size={14} /></>)}
              </button>
            </div>
          </div>
        </>
      )}
    </>
  )
}

function BranchChooser({ onPick }: { onPick: (m: SetupMode) => void }) {
  return (
    <div className="card p-6">
      <SectionHeader
        title="Do you already have a Dune Awakening server?"
        subtitle="This picks the right path through setup."
      />
      <div className="grid gap-4 md:grid-cols-3 mt-2">
        <button
          type="button"
          onClick={() => onPick('existing')}
          className="text-left p-5 rounded-lg border border-border bg-surface-2 hover:border-accent hover:bg-surface transition"
        >
          <div className="flex items-center gap-2 mb-2">
            <Icon name="ServerCog" size={20} className="text-accent shrink-0" />
            <span className="font-semibold text-accent">Yes — I already have a server</span>
          </div>
          <p className="text-sm text-text-dim">
            DST connects to your existing battlegroup VM on this PC. Nothing is re-installed — we just make sure
            the tool can reach it by locating or generating the SSH key.
          </p>
        </button>
        <button
          type="button"
          onClick={() => onPick('fresh')}
          className="text-left p-5 rounded-lg border border-border bg-surface-2 hover:border-accent hover:bg-surface transition"
        >
          <div className="flex items-center gap-2 mb-2">
            <Icon name="Download" size={20} className="text-accent shrink-0" />
            <span className="font-semibold text-accent">No — set one up for me</span>
          </div>
          <p className="text-sm text-text-dim">
            Runs Funcom's <span className="font-mono">initial-setup</span> to download and import the Hyper-V VM,
            then brings the battlegroup online. Needs ~60&nbsp;GB free and 10–30&nbsp;min.
          </p>
        </button>
        <button
          type="button"
          onClick={() => onPick('lan')}
          className="text-left p-5 rounded-lg border border-border bg-surface-2 hover:border-accent hover:bg-surface transition"
        >
          <div className="flex items-center gap-2 mb-2">
            <Icon name="Network" size={20} className="text-accent shrink-0" />
            <span className="font-semibold text-accent">Hyper-V over LAN</span>
          </div>
          <p className="text-sm text-text-dim">
            The VM runs on a <strong>separate Hyper-V host</strong> on your network (e.g. a headless server).
            DST runs on this PC and manages that host over the LAN. The VM must already be installed there.
          </p>
        </button>
      </div>
    </div>
  )
}

function StepIndicator({ steps, current, done }: { steps: Step[]; current: number; done: Set<number> }) {
  return (
    <div className="card p-4 mb-6">
      <ol className="flex items-center justify-between gap-2">
        {steps.map((s, i) => {
          const idx = i + 1
          const isDone = done.has(idx)
          const isCurrent = current === idx
          return (
            <li key={s.title} className="flex items-center gap-2 flex-1 min-w-0">
              <div
                className={
                  'w-8 h-8 rounded-full flex items-center justify-center shrink-0 text-xs font-semibold border-2 transition ' +
                  (isCurrent
                    ? 'border-accent bg-accent/20 text-accent'
                    : isDone
                      ? 'border-success bg-success/20 text-success'
                      : 'border-border bg-surface-2 text-text-dim')
                }
              >
                {isDone ? <Icon name="Check" size={14} /> : idx}
              </div>
              <div className="min-w-0 hidden md:block">
                <div className={`text-xs font-semibold truncate ${isCurrent ? 'text-accent' : isDone ? 'text-success' : 'text-text-dim'}`}>
                  {s.title}
                </div>
                <div className="text-[10px] text-text-dim truncate">{s.subtitle}</div>
              </div>
              {i < steps.length - 1 && (
                <div className={`flex-1 h-px ${isDone ? 'bg-success/40' : 'bg-border'}`} />
              )}
            </li>
          )
        })}
      </ol>
    </div>
  )
}

function SectionHeader({ title, subtitle }: { title: string; subtitle: string }) {
  return (
    <div className="mb-4">
      <h2 className="text-lg font-semibold text-accent">{title}</h2>
      <p className="text-sm text-text-dim mt-1">{subtitle}</p>
    </div>
  )
}

function Step1Preflight({ existing = false, mode }: { existing?: boolean; mode?: 'existing' | 'fresh' | 'lan' }) {
  // `existing` is kept for the existing-VM flow's call sites; `mode` is the
  // explicit selector used by the LAN flow. Resolve one effective mode.
  const effMode: 'existing' | 'fresh' | 'lan' = mode ?? (existing ? 'existing' : 'fresh')
  const isLan = effMode === 'lan'
  const [data, setData] = useState<PreflightResult | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const refresh = useCallback(async () => {
    setLoading(true); setError(null)
    try { setData(await getPreflight(effMode)) }
    catch (e) { setError(e instanceof ApiError ? e.message : String(e)) }
    finally { setLoading(false) }
  }, [effMode])
  useEffect(() => { void refresh() }, [refresh])

  return (
    <>
      <SectionHeader
        title="Pre-flight checks"
        subtitle={isLan
          ? 'Confirm DST is elevated and has the Hyper-V tools to manage a host over the LAN.'
          : existing
            ? 'Confirm DST is elevated and can see Hyper-V before connecting.'
            : 'Verify your machine can host the battlegroup.'}
      />
      {isLan && (
        <p className="text-sm text-text-dim mb-3">
          The VM will live on a <strong>separate Hyper-V host</strong> on your network. This PC still needs the
          Hyper-V PowerShell module (to drive that host remotely) and the OpenSSH client (to reach the VM). The
          next step points DST at the host's IP and tests the connection.
        </p>
      )}
      {existing && !isLan && (
        <p className="text-sm text-text-dim mb-3">
          You already have a server, so the disk check only covers what DST itself needs (app + local
          backups) — it won't import a new VM. The next step locates or generates the SSH key it needs to
          reach your battlegroup.
        </p>
      )}
      {error && <p className="text-sm text-danger mb-3">{error}</p>}
      {!data ? (
        <p className="text-sm text-text-dim italic">{loading ? 'Checking…' : 'No data.'}</p>
      ) : (
        <ul className="space-y-2">
          {data.checks.map(c => {
            const tone = c.severity === 'error' ? 'text-danger'
              : c.severity === 'warning' ? 'text-warning'
              : c.severity === 'info' ? 'text-text-dim'
              : 'text-success'
            const icon = c.severity === 'error' ? 'XCircle'
              : c.severity === 'warning' ? 'AlertTriangle'
              : c.severity === 'info' ? 'Info'
              : 'CheckCircle2'
            return (
              <li key={c.key} className="flex items-start gap-3 p-3 rounded border border-border bg-surface-2">
                <Icon name={icon} size={18} className={`${tone} shrink-0 mt-0.5`} />
                <div className="min-w-0 flex-1">
                  <div className={`text-sm font-medium ${tone}`}>{c.label}</div>
                  <div className="text-xs text-text-dim mt-0.5 break-words">{c.detail}</div>
                  {!c.ok && c.fix && <FixBlock fix={c.fix} />}
                </div>
              </li>
            )
          })}
        </ul>
      )}
      <div className="mt-4">
        <button className="btn-secondary" onClick={() => { void refresh() }} disabled={loading}>
          <Icon name="RefreshCw" size={14} className={loading ? 'animate-spin' : ''} /> Re-run checks
        </button>
      </div>
    </>
  )
}

function Step2Config() {
  const [cfg, setCfg] = useState<SetupConfigSummary | null>(null)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => {
    getSetupConfig().then(setCfg).catch(e => setError(e instanceof ApiError ? e.message : String(e)))
  }, [])

  return (
    <>
      <SectionHeader title="Configuration" subtitle="Confirm tool settings before installing the VM." />
      <p className="text-sm text-text-dim mb-3">
        These values come from <span className="font-mono">dune-server.config</span>. Edit them on the{' '}
        <Link to="/settings" className="text-accent hover:underline">Settings</Link> page.
      </p>
      {error && <p className="text-sm text-danger mb-3">{error}</p>}
      {!cfg ? (
        <p className="text-sm text-text-dim italic">Loading…</p>
      ) : (
        <dl className="grid grid-cols-[200px_1fr] gap-y-2 text-sm">
          <dt className="text-text-dim">Windows user</dt>
          <dd className="font-mono">{cfg.windowsUser ?? '(unset)'}</dd>
          <dt className="text-text-dim">SSH key path</dt>
          <dd className="font-mono break-all">
            {cfg.sshKey ?? '(unset)'}
            {cfg.sshKey && !cfg.sshKeyExists && (
              <span className="ml-2 text-danger">— file not found</span>
            )}
          </dd>
          <dt className="text-text-dim">Steam path</dt>
          <dd className="font-mono break-all">{cfg.steamPath ?? '(unset)'}</dd>
          <dt className="text-text-dim">Port check mode</dt>
          <dd className="font-mono">{cfg.portCheckMode ?? 'builtin'}</dd>
          <dt className="text-text-dim">VM name</dt>
          <dd className="font-mono">{cfg.vmName}</dd>
          <dt className="text-text-dim">SSH port</dt>
          <dd className="font-mono">{cfg.sshPort}</dd>
        </dl>
      )}
    </>
  )
}

function StepConnectExisting() {
  const [values, setValues]   = useState<Record<string, string>>({})
  const [pf, setPf]           = useState<PreflightResult | null>(null)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving]   = useState(false)
  const [browsing, setBrowsing] = useState(false)
  const [rotating, setRotating] = useState(false)
  const [msg, setMsg]         = useState<string | null>(null)
  const [error, setError]     = useState<string | null>(null)

  const loadCfg = useCallback(async () => {
    const out = await api<{ values: Record<string, string> }>('/api/config')
    setValues({ ...out.values })
  }, [])
  const loadPf = useCallback(async () => {
    try { setPf(await getPreflight('existing')) } catch { /* surfaced below via missing check */ }
  }, [])
  useEffect(() => {
    void (async () => {
      setLoading(true)
      try { await Promise.all([loadCfg(), loadPf()]) }
      catch (e) { setError(e instanceof ApiError ? e.message : String(e)) }
      finally { setLoading(false) }
    })()
  }, [loadCfg, loadPf])

  const sshCheck = pf?.checks.find(c => c.key === 'sshkey')

  const browseKey = useCallback(async () => {
    setBrowsing(true); setError(null)
    try {
      const r = await api<{ ok: boolean; cancelled: boolean; path: string }>('/api/browse-path', {
        method: 'POST',
        body: JSON.stringify({
          mode: 'file',
          current: values.SshKey ?? '',
          title: 'Select your SSH private key',
          filter: 'SSH key (sshKey;*.pem;*.key)|sshKey;*.pem;*.key|All files (*.*)|*.*',
        }),
      })
      if (r.ok && !r.cancelled && r.path) setValues(v => ({ ...v, SshKey: r.path }))
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setBrowsing(false)
    }
  }, [values.SshKey])

  const save = useCallback(async () => {
    const key = (values.SshKey ?? '').trim()
    if (!key) { setError('Enter or browse to your SSH private key first.'); return }
    setSaving(true); setError(null); setMsg(null)
    try {
      await api<{ ok: boolean; complete: boolean }>('/api/config', {
        method: 'PUT',
        body: JSON.stringify({ values: { SshKey: key } }),
      })
      setMsg('Saved. Re-checking the connection…')
      await loadPf()
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }, [values.SshKey, loadPf])

  const recheck = useCallback(async () => {
    setMsg(null); setError(null)
    await loadPf()
  }, [loadPf])

  const generate = useCallback(async () => {
    if (!window.confirm('Generate a NEW SSH key and authorize it on the VM?\n\nThe VM must be running. A console window opens and asks for the \'dune\' user\'s password — you MUST type it there to authorize the new key. If you close it without entering the password, DST stays locked out until you re-run this.')) return
    setRotating(true); setMsg(null); setError(null)
    try {
      const r = await api<{ ok: boolean; rotated: boolean; message?: string }>('/api/config/rotate-ssh-key', { method: 'POST' })
      setMsg(r.message ?? (r.ok ? 'SSH key generated and authorized.' : 'Rotation did not complete.'))
      if (!r.ok && r.message) setError(r.message)
      await loadCfg()
      await loadPf()
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setRotating(false)
    }
  }, [loadCfg, loadPf])

  const tone = sshCheck?.ok ? 'text-success'
    : sshCheck?.severity === 'warning' ? 'text-warning'
    : 'text-text-dim'
  const icon = sshCheck?.ok ? 'CheckCircle2'
    : sshCheck?.severity === 'warning' ? 'AlertTriangle'
    : 'Info'

  return (
    <>
      <SectionHeader title="Connect to your server" subtitle="Point DST at your existing battlegroup." />
      <p className="text-sm text-text-dim mb-4">
        DST reaches the <span className="font-mono">dune-awakening</span> VM over SSH. Tell it which private
        key to use — either <strong>locate the key</strong> you already have, or <strong>generate a new one</strong>{' '}
        and authorize it on the running VM.
      </p>

      {loading ? (
        <p className="text-sm text-text-dim italic">Loading…</p>
      ) : (
        <>
          <label className="block text-sm font-medium text-text mb-1">SSH private key path</label>
          <div className="flex items-stretch gap-2 mb-2">
            <input
              type="text"
              value={values.SshKey ?? ''}
              onChange={e => setValues(v => ({ ...v, SshKey: e.target.value }))}
              placeholder="C:\Users\<you>\AppData\Local\DuneAwakeningServer\sshKey"
              className="flex-1 min-w-0 text-sm font-mono bg-surface border border-border rounded px-2 py-1.5"
            />
            <button type="button" className="btn-secondary shrink-0" onClick={() => { void browseKey() }} disabled={browsing}>
              <Icon name="FolderOpen" size={14} /> {browsing ? 'Browsing…' : 'Locate'}
            </button>
          </div>

          <div className="flex flex-wrap gap-2 mb-4">
            <button type="button" className="btn-primary" onClick={() => { void save() }} disabled={saving}>
              <Icon name={saving ? 'Loader2' : 'Save'} size={14} className={saving ? 'animate-spin' : ''} />
              {saving ? 'Saving…' : 'Save & verify'}
            </button>
            <button type="button" className="btn-secondary" onClick={() => { void generate() }} disabled={rotating}>
              <Icon name={rotating ? 'Loader2' : 'KeyRound'} size={14} className={rotating ? 'animate-spin' : ''} />
              {rotating ? 'Generating…' : 'Generate & authorize new key'}
            </button>
            <button type="button" className="btn-ghost" onClick={() => { void recheck() }}>
              <Icon name="RefreshCw" size={14} /> Re-check connection
            </button>
          </div>

          {sshCheck && (
            <div className="flex items-start gap-3 p-3 rounded border border-border bg-surface-2 mb-2">
              <Icon name={icon} size={18} className={`${tone} shrink-0 mt-0.5`} />
              <div className="min-w-0 flex-1">
                <div className={`text-sm font-medium ${tone}`}>
                  {sshCheck.ok ? 'DST can reach your server' : 'Connection not verified yet'}
                </div>
                <div className="text-xs text-text-dim mt-0.5 break-words">{sshCheck.detail}</div>
                {!sshCheck.ok && sshCheck.fix && <FixBlock fix={sshCheck.fix} />}
              </div>
            </div>
          )}

          {msg   && <p className="mt-2 text-xs text-text-muted border-l-2 border-accent pl-2 break-words">{msg}</p>}
          {error && <p className="mt-2 text-xs text-danger break-words">{error}</p>}

          <p className="mt-4 text-xs text-text-dim">
            The <span className="font-mono">Steam install path</span> is only needed for fresh installs and a few
            client-config helpers — set it later on the{' '}
            <Link to="/settings" className="text-accent hover:underline">Settings</Link> page if you want those.
          </p>
        </>
      )}
    </>
  )
}

// LAN flow — point DST at a Hyper-V host on the network, collect + persist the
// host administrator credential, and flip the routing toggle so every VM
// command targets that host (with that credential) instead of local Hyper-V.
function StepConnectLan() {
  const [hostIp, setHostIp]   = useState('')
  const [enabled, setEnabled] = useState(false) // routing toggle == VmHostMode 'lan'
  const [loading, setLoading] = useState(true)
  const [testing, setTesting] = useState(false)
  const [saving, setSaving]   = useState(false)
  const [test, setTest]       = useState<HyperVLanTest | null>(null)
  const [msg, setMsg]         = useState<string | null>(null)
  const [error, setError]     = useState<string | null>(null)

  // Credential: hidden behind "using saved credential for X" once one exists
  // and matches hostIp, so re-opening this step never re-prompts. "Change
  // credential" reveals the fields to replace it.
  const [credUser, setCredUser] = useState('')
  const [credPassword, setCredPassword] = useState('')
  const [savedUser, setSavedUser] = useState<string | null>(null)
  const [editingCred, setEditingCred] = useState(false)

  const loadCredInfo = useCallback(async (ip: string) => {
    if (!ip) { setSavedUser(null); return }
    try {
      const info = await getHyperVLanCredential(ip)
      setSavedUser(info.exists && info.matchesHost ? info.user : null)
      setEditingCred(!(info.exists && info.matchesHost))
    } catch {
      setSavedUser(null)
    }
  }, [])

  useEffect(() => {
    void (async () => {
      setLoading(true)
      try {
        const s = await getHyperVLan()
        setHostIp(s.hostIp ?? '')
        setEnabled(s.mode === 'lan')
        await loadCredInfo(s.hostIp ?? '')
      } catch (e) {
        setError(e instanceof ApiError ? e.message : String(e))
      } finally {
        setLoading(false)
      }
    })()
  }, [loadCredInfo])

  // A candidate host must pass a live connectivity test before it can be enabled.
  const canEnable = !!test?.ok

  const runTest = useCallback(async () => {
    const ip = hostIp.trim()
    if (!ip) { setError('Enter the Hyper-V host IP first.'); return }
    const usingNewCred = editingCred && credUser.trim() && credPassword
    if (editingCred && !usingNewCred) { setError("Enter the host's administrator username and password first."); return }
    setTesting(true); setError(null); setMsg(null); setTest(null)
    try {
      const result = usingNewCred
        ? await testHyperVLan(ip, credUser.trim(), credPassword)
        : await testHyperVLan(ip)
      setTest(result)
      if (result.ok && usingNewCred) {
        // Persist the credential that just proved it works, then collapse
        // back to the "using saved credential" view.
        await saveHyperVLanCredential(ip, credUser.trim(), credPassword)
        setCredPassword('')
        await loadCredInfo(ip)
      }
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setTesting(false)
    }
  }, [hostIp, editingCred, credUser, credPassword, loadCredInfo])

  const save = useCallback(async () => {
    const ip = hostIp.trim()
    if (enabled && !ip) { setError('Enter the Hyper-V host IP first.'); return }
    if (enabled && !canEnable) { setError('Test the connection successfully before enabling Hyper-V over LAN.'); return }
    setSaving(true); setError(null); setMsg(null)
    try {
      const r = await saveHyperVLan(enabled ? 'lan' : 'local', ip)
      setMsg(r.mode === 'lan'
        ? `Saved. DST will manage the VM on ${r.hostIp} over the LAN.`
        : 'Saved. DST is using the local Hyper-V VM (LAN routing off).')
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }, [hostIp, enabled, canEnable])

  const tone = test == null ? 'text-text-dim' : test.ok ? 'text-success' : 'text-danger'
  const tIcon = test == null ? 'Info' : test.ok ? 'CheckCircle2' : 'AlertTriangle'

  return (
    <>
      <SectionHeader title="Point DST at the Hyper-V host" subtitle="The VM lives on another machine on your LAN." />

      <div className="flex items-start gap-3 p-3 rounded border border-warning/40 bg-warning/10 mb-4">
        <Icon name="AlertTriangle" size={18} className="text-warning shrink-0 mt-0.5" />
        <div className="text-xs text-text-dim">
          <span className="font-medium text-warning">Prerequisite:</span> the host's Hyper-V PowerShell Remoting
          (WinRM) must be reachable from this PC (in a workgroup: the host trusted from this PC via
          <span className="font-mono"> TrustedHosts</span>). DST uses an explicit administrator credential for that
          host below — it does not need to match the Windows account DST itself runs as. The VM must already be
          installed on that host and named <span className="font-mono">dune-awakening</span>.
        </div>
      </div>

      {loading ? (
        <p className="text-sm text-text-dim italic">Loading…</p>
      ) : (
        <>
          <label className="block text-sm font-medium text-text mb-1">Hyper-V host IP (or name)</label>
          <div className="flex items-stretch gap-2 mb-2">
            <input
              type="text"
              value={hostIp}
              onChange={e => { setHostIp(e.target.value); setTest(null); void loadCredInfo(e.target.value.trim()) }}
              placeholder="192.168.1.50"
              className="flex-1 min-w-0 text-sm font-mono bg-surface border border-border rounded px-2 py-1.5"
            />
          </div>
          <p className="text-xs text-text-dim mb-3">
            This is the <strong>host</strong> address, not the VM's. DST discovers the VM's own IP through the host
            once connected.
          </p>

          <label className="block text-sm font-medium text-text mb-1">Host administrator credential</label>
          {!editingCred && savedUser ? (
            <div className="flex items-center justify-between gap-2 p-3 rounded border border-border bg-surface-2 mb-3">
              <span className="text-sm text-text-dim">
                Using saved credential for <span className="font-mono text-text">{savedUser}</span>
              </span>
              <button type="button" className="btn-secondary shrink-0" onClick={() => { setEditingCred(true); setTest(null) }}>
                Change
              </button>
            </div>
          ) : (
            <div className="grid grid-cols-1 md:grid-cols-2 gap-3 mb-3">
              <label className="flex flex-col gap-1 text-sm">
                <span className="text-text-dim">Administrator username</span>
                <input type="text" value={credUser} onChange={e => { setCredUser(e.target.value); setTest(null) }} spellCheck={false}
                  placeholder="HOST\Administrator" className="px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm font-mono" />
              </label>
              <label className="flex flex-col gap-1 text-sm">
                <span className="text-text-dim">Password</span>
                <input type="password" value={credPassword} onChange={e => { setCredPassword(e.target.value); setTest(null) }}
                  className="px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm" />
              </label>
              <p className="md:col-span-2 text-xs text-text-dim -mt-1">
                The host's own administrator account. In a workgroup this is routinely a <strong>different</strong>{' '}
                account than the one DST itself runs as on this PC — use <span className="font-mono">HOST\username</span>.
              </p>
            </div>
          )}

          <div className="mb-3">
            <button type="button" className="btn-secondary" onClick={() => { void runTest() }} disabled={testing}>
              <Icon name={testing ? 'Loader2' : 'Plug'} size={14} className={testing ? 'animate-spin' : ''} />
              {testing ? 'Testing…' : 'Test connection'}
            </button>
          </div>

          {test && (
            <div className="flex items-start gap-3 p-3 rounded border border-border bg-surface-2 mb-3">
              <Icon name={tIcon} size={18} className={`${tone} shrink-0 mt-0.5`} />
              <div className="min-w-0 flex-1">
                <div className={`text-sm font-medium ${tone}`}>
                  {test.ok ? (test.vmFound ? 'Connected — VM found' : 'Connected — VM not installed yet') : 'Could not connect'}
                </div>
                <div className="text-xs text-text-dim mt-0.5 break-words">{test.reason}</div>
              </div>
            </div>
          )}

          <label className={`flex items-start gap-2 p-3 rounded border mb-4 ${canEnable ? 'border-border bg-surface-2 cursor-pointer' : 'border-border/60 bg-surface-2/50 opacity-60 cursor-not-allowed'}`}>
            <input
              type="checkbox"
              className="mt-0.5"
              checked={enabled}
              disabled={!canEnable && !enabled}
              onChange={e => setEnabled(e.target.checked)}
            />
            <span className="text-sm text-text">
              Route all VM commands to this LAN host
              <span className="block text-xs text-text-dim mt-0.5">
                When on, DST manages the remote VM (status, start/stop, RAM) over the LAN using the credential above.
                Turn it off to go back to a local VM on this PC — this fully bypasses the LAN path, but keeps the
                saved credential for next time. {!canEnable && !enabled && 'Run a successful test first.'}
              </span>
            </span>
          </label>

          <div className="flex flex-wrap gap-2">
            <button type="button" className="btn-primary" onClick={() => { void save() }} disabled={saving}>
              <Icon name={saving ? 'Loader2' : 'Save'} size={14} className={saving ? 'animate-spin' : ''} />
              {saving ? 'Saving…' : 'Save'}
            </button>
          </div>

          {msg   && <p className="mt-2 text-xs text-text-muted border-l-2 border-accent pl-2 break-words">{msg}</p>}
          {error && <p className="mt-2 text-xs text-danger break-words">{error}</p>}
        </>
      )}
    </>
  )
}

// LAN install — provision the VM onto the remote headless host. Reads the host
// IP saved in the previous step, collects a WinRM admin credential, probes the
// host, and (if the VM isn't there) runs the streamed remote install.
function StepInstallLan() {
  const [hostIp, setHostIp] = useState('')
  const [user, setUser] = useState('')
  const [password, setPassword] = useState('')
  const [savedCredUser, setSavedCredUser] = useState<string | null>(null)
  const [res, setRes] = useState<HyperVLanHostResources | null>(null)
  const [checking, setChecking] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // Install form
  const [destDrive, setDestDrive] = useState('')
  const [memoryGB, setMemoryGB] = useState(20)
  const [switchName, setSwitchName] = useState('')
  const [vmPassword, setVmPassword] = useState('')

  const [status, setStatus] = useState<HyperVLanInstallStatus | null>(null)
  const [installing, setInstalling] = useState(false)
  const [elapsed, setElapsed] = useState(0)

  useEffect(() => {
    void (async () => {
      let ip = ''
      try { const s = await getHyperVLan(); ip = s.hostIp ?? ''; setHostIp(ip) } catch { /* set in prior step */ }
      // The Hyper-V host step already collected + saved a credential for this
      // host; reuse it here instead of asking again. The fields below stay
      // available in case a different (e.g. install-only) credential is
      // needed for this one-off WinRM session.
      try {
        const info = await getHyperVLanCredential(ip)
        if (info.exists && info.matchesHost) setSavedCredUser(info.user)
      } catch { /* fields stay editable */ }
      // If an install is already running (e.g. page reopened), resume polling.
      try {
        const st = await getHyperVLanInstallStatus()
        if (st && st.running) { setStatus(st); setInstalling(true) }
      } catch { /* none */ }
    })()
  }, [])

  // Elapsed timer while installing.
  useEffect(() => {
    if (!installing) { setElapsed(0); return }
    const start = Date.now()
    const iv = window.setInterval(() => setElapsed(Math.floor((Date.now() - start) / 1000)), 1000)
    return () => window.clearInterval(iv)
  }, [installing])

  // Poll install status while running.
  useEffect(() => {
    if (!installing) return
    let alive = true
    const tick = async () => {
      try {
        const st = await getHyperVLanInstallStatus()
        if (!alive) return
        setStatus(st)
        if (!st.running) { setInstalling(false) }
      } catch { /* keep polling */ }
    }
    const iv = window.setInterval(() => { void tick() }, 3000)
    void tick()
    return () => { alive = false; window.clearInterval(iv) }
  }, [installing])

  const check = useCallback(async () => {
    if (!hostIp.trim()) { setError('Set the Hyper-V host IP in the previous step first.'); return }
    if (!savedCredUser && (!user.trim() || !password)) { setError("Enter the host's administrator username and password."); return }
    setChecking(true); setError(null); setRes(null)
    try {
      const r = await getHyperVLanHostResources(hostIp.trim(), user.trim() || undefined, password || undefined)
      setRes(r)
      if (r.ok) {
        if (r.drives && r.drives[0]) setDestDrive(r.drives[0].drive)
        if (r.switches && r.switches[0]) setSwitchName(r.switches[0])
      } else {
        setError(r.error ?? 'Could not read the host.')
      }
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setChecking(false)
    }
  }, [hostIp, user, password, savedCredUser])

  const install = useCallback(async () => {
    if (!destDrive) { setError('Pick a destination drive.'); return }
    if (!switchName) { setError('Pick an external switch (create one on the host if the list is empty).'); return }
    if (memoryGB < 1) { setError('Enter a memory size in GB.'); return }
    setError(null)
    try {
      const r = await startHyperVLanInstall({
        hostIp: hostIp.trim(), user: user.trim() || undefined, password: password || undefined,
        destDrive, memoryGB, switchName, vmPassword, replaceExisting: false,
      })
      if (!r.ok) { setError(r.error ?? 'Could not start the install.'); return }
      setInstalling(true)
      setStatus({ running: true, phase: 'starting', steps: [], ip: '', error: '' })
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    }
  }, [hostIp, user, password, destDrive, switchName, memoryGB, vmPassword])

  const done = status && !status.running && status.phase === 'done'
  const failed = status && !status.running && status.phase === 'error'
  const noSwitches = res?.ok && (res.switches?.length ?? 0) === 0

  return (
    <>
      <SectionHeader title="Install the VM on the host" subtitle="DST provisions the Dune VM onto the remote Hyper-V host." />

      <div className="rounded-lg border border-info/40 bg-info/10 p-3 text-sm text-text-dim mb-4">
        DST connects to <span className="font-mono">{hostIp || '(host set in previous step)'}</span> over PowerShell Remoting,
        downloads the server image there with SteamCMD (anonymous — no Steam login), imports and starts the VM, then sets up the
        battlegroup over the LAN. If the VM already exists on the host, you can skip this step.
      </div>

      {/* Credentials + probe */}
      {savedCredUser && (
        <p className="text-xs text-text-dim mb-2">
          Using the saved credential for <span className="font-mono text-text">{savedCredUser}</span> from the previous
          step unless you enter a different one below.
        </p>
      )}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-3 mb-3">
        <label className="flex flex-col gap-1 text-sm">
          <span className="font-medium">Host administrator username {savedCredUser && <span className="text-text-dim font-normal">(optional)</span>}</span>
          <input type="text" value={user} onChange={e => setUser(e.target.value)} disabled={installing} spellCheck={false}
            placeholder={savedCredUser ?? 'HOST\\Administrator'} className="px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm" />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          <span className="font-medium">Host administrator password {savedCredUser && <span className="text-text-dim font-normal">(optional)</span>}</span>
          <input type="password" value={password} onChange={e => setPassword(e.target.value)} disabled={installing}
            className="px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm" />
        </label>
      </div>
      <div className="flex flex-wrap gap-2 mb-3">
        <button type="button" className="btn-secondary" onClick={() => void check()} disabled={checking || installing}>
          <Icon name={checking ? 'Loader2' : 'Search'} size={14} className={checking ? 'animate-spin' : ''} />
          {checking ? 'Checking host…' : 'Check host'}
        </button>
      </div>

      {error && <p className="text-xs text-danger break-words mb-3">{error}</p>}

      {res?.ok && res.vmExists && !installing && (
        <div className="rounded-lg border border-success/40 bg-success/10 p-3 text-sm text-success flex items-start gap-2">
          <Icon name="CircleCheck" size={16} className="mt-0.5 shrink-0" />
          <span>A <span className="font-mono">dune-awakening</span> VM already exists on this host — nothing to install. Continue to the next step; it's managed over the LAN.</span>
        </div>
      )}

      {res?.ok && !res.vmExists && !done && (
        <div className="space-y-3">
          {noSwitches && (
            <div className="rounded-lg border border-warning/40 bg-warning/10 p-3 text-xs text-text-dim">
              No external virtual switch found on the host. Create one once on the host, then re-check:
              <code className="block mt-1 font-mono text-text">New-VMSwitch -Name DuneExternal -NetAdapterName &lt;nic&gt; -AllowManagementOS $true</code>
            </div>
          )}
          <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
            <label className="flex flex-col gap-1 text-sm">
              <span className="font-medium">Install drive (host)</span>
              <select value={destDrive} onChange={e => setDestDrive(e.target.value)} disabled={installing}
                className="px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm">
                {(res.drives ?? []).map(d => <option key={d.drive} value={d.drive}>{d.drive} ({d.freeGB} GB free)</option>)}
              </select>
              <span className="text-xs text-text-dim">Needs 100 GB+ free.</span>
            </label>
            <label className="flex flex-col gap-1 text-sm">
              <span className="font-medium">External switch (host)</span>
              <select value={switchName} onChange={e => setSwitchName(e.target.value)} disabled={installing || noSwitches}
                className="px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm">
                {(res.switches ?? []).map(s => <option key={s} value={s}>{s}</option>)}
              </select>
            </label>
            <label className="flex flex-col gap-1 text-sm">
              <span className="font-medium">VM memory (GB)</span>
              <input type="number" min={8} value={memoryGB} onChange={e => setMemoryGB(parseInt(e.target.value || '0', 10))}
                disabled={installing} className="px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm" />
              <span className="text-xs text-text-dim">Host RAM: {res.hostRamGB ?? '?'} GB. 20 GB recommended for one Hagga Basin.</span>
            </label>
            <label className="flex flex-col gap-1 text-sm">
              <span className="font-medium">New VM password <span className="text-text-dim font-normal">(optional)</span></span>
              <input type="password" value={vmPassword} onChange={e => setVmPassword(e.target.value)} disabled={installing}
                placeholder="leave blank to keep default" className="px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm" />
            </label>
          </div>
          <button type="button" className="btn-primary" onClick={() => void install()} disabled={installing || noSwitches}>
            <Icon name={installing ? 'Loader2' : 'HardDriveDownload'} size={14} className={installing ? 'animate-spin' : ''} />
            {installing ? 'Installing…' : 'Install VM on host'}
          </button>
        </div>
      )}

      {/* Progress */}
      {status && (installing || done || failed) && (
        <div className="mt-4 rounded-lg border border-border bg-surface-2 p-3 space-y-2">
          <div className="flex items-center gap-2 text-sm font-medium">
            {done ? <Icon name="CircleCheck" size={16} className="text-success" />
              : failed ? <Icon name="CircleX" size={16} className="text-danger" />
              : <Icon name="Loader2" size={16} className="animate-spin text-info" />}
            {done ? 'Install complete' : failed ? 'Install failed' : `Installing… ${Math.floor(elapsed / 60)}m ${(elapsed % 60).toString().padStart(2, '0')}s`}
          </div>
          {installing && (
            <div className="text-xs text-text-dim">
              The image download and battlegroup setup can take <strong>several minutes</strong>. Safe to leave this open — it runs on the server.
            </div>
          )}
          <ul className="space-y-1">
            {(status.steps ?? []).map(s => (
              <li key={s.id} className="flex items-start gap-2 text-xs">
                <Icon
                  name={s.status === 'done' ? 'CheckCircle2' : s.status === 'failed' ? 'CircleX' : s.status === 'running' ? 'Loader2' : 'Circle'}
                  size={13}
                  className={`mt-0.5 shrink-0 ${s.status === 'done' ? 'text-success' : s.status === 'failed' ? 'text-danger' : s.status === 'running' ? 'text-info animate-spin' : 'text-text-dim'}`}
                />
                <span className="min-w-0"><span className="text-text">{s.label}</span>{s.detail ? <span className="text-text-dim"> — {s.detail}</span> : null}</span>
              </li>
            ))}
          </ul>
          {done && <p className="text-xs text-success">VM installed at {status.ip} and DST is now managing it over the LAN. Continue to finish setup.</p>}
          {failed && <p className="text-xs text-danger break-words">{status.error}</p>}
        </div>
      )}
    </>
  )
}

function Step3Install() {
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const run = useCallback(async () => {
    setBusy(true); setMessage(null); setError(null)
    try {
      await api('/api/commands/run/initial-setup', { method: 'POST' })
      setMessage('initial-setup launched in a console window. Watch the script output there.')
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }, [])
  return (
    <>
      <SectionHeader title="Installing" subtitle="Run the initial VM setup script." />
      <p className="text-sm text-text mb-2">
        This dispatches the <span className="font-mono text-accent">initial-setup</span> command, which:
      </p>
      <ul className="text-sm text-text-dim list-disc ml-6 mb-4 space-y-1">
        <li>Downloads the prebuilt Dune Awakening Hyper-V image (~few GB)</li>
        <li>Imports the VM and configures networking</li>
        <li>Starts the VM and waits for K8s + battlegroup to come up</li>
      </ul>
      <p className="text-sm text-text-dim mb-4">
        Expect 10–30 minutes depending on bandwidth. Each launch opens a console window — you can leave
        it running and come back to press <span className="text-accent">Next</span> when it finishes.
      </p>
      <button className="btn-primary" onClick={() => { void run() }} disabled={busy}>
        <Icon name={busy ? 'Loader2' : 'Play'} size={14} className={busy ? 'animate-spin' : ''} />
        {busy ? 'Launching…' : 'Run initial-setup'}
      </button>
      {message && <p className="mt-3 text-xs text-text-muted border-l-2 border-accent pl-2">{message}</p>}
      {error   && <p className="mt-3 text-xs text-danger break-words">{error}</p>}
    </>
  )
}

function Step4Security() {
  return (
    <>
      <SectionHeader title="Security" subtitle="Lock down access to your battlegroup." />
      <p className="text-sm text-text mb-2">
        The VM is configured with a default SSH keypair generated during install. Best practice:
      </p>
      <ul className="text-sm text-text-dim list-disc ml-6 space-y-1">
        <li>
          Rotate the SSH key from the <Link to="/commands" className="text-accent hover:underline">Commands</Link> page
          (<span className="font-mono">rotate-ssh-key</span>).
        </li>
        <li>Limit inbound traffic in Windows Defender Firewall to the battlegroup ports only.</li>
      </ul>
    </>
  )
}

function Step5Networking() {
  return (
    <>
      <SectionHeader title="Networking" subtitle="Expose your server to the internet." />
      <p className="text-sm text-text mb-3">
        If players will connect over the public internet, forward these ports on your router:
      </p>
      <dl className="grid grid-cols-[200px_1fr] gap-y-2 text-sm mb-3">
        <dt className="text-text-dim">Game port</dt>
        <dd className="font-mono">7777/UDP → VM IP</dd>
        <dt className="text-text-dim">Query port</dt>
        <dd className="font-mono">27015/UDP → VM IP (optional)</dd>
        <dt className="text-text-dim">SSH (admin only)</dt>
        <dd className="font-mono">Leave closed; reach via LAN or VPN</dd>
      </dl>
      <p className="text-sm text-text-dim">
        A dynamic DNS service (DuckDNS, No-IP, Cloudflare) is highly recommended if your ISP rotates
        your public IP.
      </p>
    </>
  )
}

function Step6Finalize() {
  return (
    <>
      <SectionHeader title="You're done!" subtitle="Setup is complete." />
      <p className="text-sm text-text mb-4">
        Head to <Link to="/" className="text-accent hover:underline">Server Health</Link> to start
        the battlegroup with one click, or jump straight to a specific area:
      </p>
      <ul className="text-sm text-text-dim space-y-2">
        <li><Link to="/" className="text-accent hover:underline">Server Health</Link> — start/stop the battlegroup, view logs</li>
        <li><Link to="/database" className="text-accent hover:underline">Database</Link> — schedule backups, run SQL</li>
        <li><Link to="/settings" className="text-accent hover:underline">Settings</Link> — rotate SSH key, change password</li>
      </ul>
    </>
  )
}
