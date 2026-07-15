import { useCallback, useEffect, useState, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { api, ApiError } from '../api/client'
import { getPreflight, getSetupConfig, getHyperVLan, saveHyperVLan, testHyperVLan, type PreflightResult, type SetupConfigSummary, type HyperVLanTest } from '../api/setup'

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

// LAN flow — point DST at a Hyper-V host on the network and flip the routing
// toggle so every VM command targets that host instead of local Hyper-V.
function StepConnectLan() {
  const [hostIp, setHostIp]   = useState('')
  const [enabled, setEnabled] = useState(false) // routing toggle == VmHostMode 'lan'
  const [loading, setLoading] = useState(true)
  const [testing, setTesting] = useState(false)
  const [saving, setSaving]   = useState(false)
  const [test, setTest]       = useState<HyperVLanTest | null>(null)
  const [msg, setMsg]         = useState<string | null>(null)
  const [error, setError]     = useState<string | null>(null)

  useEffect(() => {
    void (async () => {
      setLoading(true)
      try {
        const s = await getHyperVLan()
        setHostIp(s.hostIp ?? '')
        setEnabled(s.mode === 'lan')
      } catch (e) {
        setError(e instanceof ApiError ? e.message : String(e))
      } finally {
        setLoading(false)
      }
    })()
  }, [])

  // A candidate host must pass a live connectivity test before it can be enabled.
  const canEnable = !!test?.ok

  const runTest = useCallback(async () => {
    const ip = hostIp.trim()
    if (!ip) { setError('Enter the Hyper-V host IP first.'); return }
    setTesting(true); setError(null); setMsg(null); setTest(null)
    try {
      setTest(await testHyperVLan(ip))
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setTesting(false)
    }
  }, [hostIp])

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
          <span className="font-medium text-warning">Prerequisite:</span> remote Hyper-V management from this PC must
          already work — i.e. you can connect to that host in <strong>Hyper-V Manager</strong>. DST uses the same
          channel; it does not configure WinRM/permissions for you. The VM must already be installed on that host and
          named <span className="font-mono">dune-awakening</span>.
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
              onChange={e => { setHostIp(e.target.value); setTest(null) }}
              placeholder="192.168.1.50"
              className="flex-1 min-w-0 text-sm font-mono bg-surface border border-border rounded px-2 py-1.5"
            />
            <button type="button" className="btn-secondary shrink-0" onClick={() => { void runTest() }} disabled={testing}>
              <Icon name={testing ? 'Loader2' : 'Plug'} size={14} className={testing ? 'animate-spin' : ''} />
              {testing ? 'Testing…' : 'Test connection'}
            </button>
          </div>
          <p className="text-xs text-text-dim mb-3">
            This is the <strong>host</strong> address, not the VM's. DST discovers the VM's own IP through the host
            once connected.
          </p>

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
                When on, DST manages the remote VM (status, start/stop, RAM) over the LAN. Turn it off to go back to a
                local VM on this PC — this fully bypasses the LAN path. {!canEnable && !enabled && 'Run a successful test first.'}
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
