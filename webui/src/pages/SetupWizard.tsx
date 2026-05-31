import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { api, ApiError } from '../api/client'
import { getPreflight, getSetupConfig, type PreflightResult, type SetupConfigSummary } from '../api/setup'

interface Step {
  index: number
  title: string
  subtitle: string
}

const STEPS: Step[] = [
  { index: 1, title: 'Pre-flight',    subtitle: 'Environment checks' },
  { index: 2, title: 'Configuration', subtitle: 'Confirm tool settings' },
  { index: 3, title: 'Installing',    subtitle: 'Import Hyper-V VM' },
  { index: 4, title: 'Security',      subtitle: 'SSH + firewall' },
  { index: 5, title: 'Networking',    subtitle: 'Ports + DNS' },
  { index: 6, title: 'Finalize',      subtitle: 'Wrap-up' },
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
        <code className="flex-1 min-w-0 text-xs font-mono bg-surface-1 border border-border rounded px-2 py-1.5 overflow-x-auto whitespace-pre">{command}</code>
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
  const [current, setCurrent] = useState(1)
  const [done, setDone]       = useState<Set<number>>(new Set())

  const goNext = useCallback(() => {
    setDone(d => new Set(d).add(current))
    if (current < STEPS.length) setCurrent(c => c + 1)
  }, [current])
  const goBack = useCallback(() => { if (current > 1) setCurrent(c => c - 1) }, [current])
  const skip   = useCallback(() => { if (current < STEPS.length) setCurrent(c => c + 1) }, [current])

  return (
    <>
      <PageHeader
        title="Setup Wizard"
        icon="Wand2"
        description="One-time guided setup for a fresh Dune Awakening server."
      />
      <StepIndicator current={current} done={done} />
      <div className="card p-6">
        {current === 1 && <Step1Preflight />}
        {current === 2 && <Step2Config />}
        {current === 3 && <Step3Install />}
        {current === 4 && <Step4Security />}
        {current === 5 && <Step5Networking />}
        {current === 6 && <Step6Finalize />}
      </div>
      <div className="flex items-center justify-between mt-4 pt-3 border-t border-border">
        <button className="btn-secondary" onClick={goBack} disabled={current === 1}>
          <Icon name="ArrowLeft" size={14} /> Back
        </button>
        <div className="text-xs text-text-dim">
          Step {current} of {STEPS.length}: {STEPS[current - 1].title}
        </div>
        <div className="flex gap-2">
          {current < STEPS.length && (
            <button className="btn-ghost" onClick={skip}>Skip step</button>
          )}
          <button className="btn-primary" onClick={goNext}>
            {current >= STEPS.length ? 'Finish' : (<>Next <Icon name="ArrowRight" size={14} /></>)}
          </button>
        </div>
      </div>
    </>
  )
}

function StepIndicator({ current, done }: { current: number; done: Set<number> }) {
  return (
    <div className="card p-4 mb-6">
      <ol className="flex items-center justify-between gap-2">
        {STEPS.map((s, i) => {
          const isDone = done.has(s.index)
          const isCurrent = current === s.index
          return (
            <li key={s.index} className="flex items-center gap-2 flex-1 min-w-0">
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
                {isDone ? <Icon name="Check" size={14} /> : s.index}
              </div>
              <div className="min-w-0 hidden md:block">
                <div className={`text-xs font-semibold truncate ${isCurrent ? 'text-accent' : isDone ? 'text-success' : 'text-text-dim'}`}>
                  {s.title}
                </div>
                <div className="text-[10px] text-text-dim truncate">{s.subtitle}</div>
              </div>
              {i < STEPS.length - 1 && (
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

function Step1Preflight() {
  const [data, setData] = useState<PreflightResult | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const refresh = useCallback(async () => {
    setLoading(true); setError(null)
    try { setData(await getPreflight()) }
    catch (e) { setError(e instanceof ApiError ? e.message : String(e)) }
    finally { setLoading(false) }
  }, [])
  useEffect(() => { void refresh() }, [refresh])

  return (
    <>
      <SectionHeader title="Pre-flight checks" subtitle="Verify your machine can host the battlegroup." />
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
        <li>If you exposed dune-admin externally, gate it behind a reverse proxy with HTTPS.</li>
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
        <li><a href="http://localhost:8080/#/players" target="_blank" rel="noopener noreferrer" className="text-accent hover:underline">Characters</a> — edit players in dune-admin (launch it from the sidebar first)</li>
        <li><Link to="/database" className="text-accent hover:underline">Database</Link> — schedule backups, run SQL</li>
        <li><Link to="/settings" className="text-accent hover:underline">Settings</Link> — rotate SSH key, change password</li>
      </ul>
    </>
  )
}
