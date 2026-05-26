import { useMemo, useState } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { useStatus } from '../hooks/useStatus'
import { useApi } from '../hooks/useApi'
import { api } from '../api/client'
import type { Command, CommandsResponse } from '../api/types'

type LaunchResult = {
  ok: boolean
  name: string
  mode: string
  pid: number | null
  started: string
}

const SECTION_ORDER: Command['section'][] = ['VM', 'Battlegroup', 'Tools']
const SECTION_ICONS: Record<Command['section'], string> = {
  VM: 'HardDrive',
  Battlegroup: 'Activity',
  Tools: 'Wrench',
}

function CommandButton({
  cmd, onRun, busy,
}: { cmd: Command; onRun: (c: Command) => void; busy: boolean }) {
  const disabled = !cmd.available || busy
  return (
    <button
      type="button"
      disabled={disabled}
      onClick={() => onRun(cmd)}
      title={cmd.available ? cmd.desc : (cmd.reason || cmd.desc)}
      className="group w-full text-left card card-hover p-3 disabled:opacity-50 disabled:cursor-not-allowed
                 disabled:hover:border-border disabled:hover:bg-surface/80"
    >
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2 min-w-0">
          <kbd className="shrink-0 inline-flex items-center justify-center w-5 h-5 rounded
                          bg-surface-3 border border-border text-[10px] font-mono text-text-dim
                          group-hover:text-text-muted group-hover:border-border-bright">
            {cmd.key}
          </kbd>
          <span className="font-mono text-sm truncate text-text">{cmd.name}</span>
        </div>
        <span className={
          cmd.mode === 'Console' ? 'pill-info shrink-0' : 'pill-muted shrink-0'
        }>
          <Icon name={cmd.mode === 'Console' ? 'SquareTerminal' : 'Zap'} size={10} />
          {cmd.mode}
        </span>
      </div>
      <p className="mt-1.5 text-xs text-text-muted line-clamp-2">{cmd.desc}</p>
      {!cmd.available && cmd.reason && (
        <p className="mt-1 text-[11px] text-warning/80 flex items-center gap-1">
          <Icon name="AlertTriangle" size={10} /> {cmd.reason}
        </p>
      )}
    </button>
  )
}

export function Commands() {
  const { forceRefresh } = useStatus()
  const cmdsState = useApi<CommandsResponse>('/api/commands', { intervalMs: 30_000 })

  const [running, setRunning] = useState<Set<string>>(new Set())
  const [toast, setToast] = useState<{ kind: 'ok' | 'err'; msg: string } | null>(null)

  function showToast(kind: 'ok' | 'err', msg: string) {
    setToast({ kind, msg })
    window.setTimeout(() => setToast(t => (t?.msg === msg ? null : t)), 4000)
  }

  async function runCommand(c: Command) {
    setRunning(s => new Set(s).add(c.name))
    try {
      const r = await api<LaunchResult>(`/api/commands/run/${encodeURIComponent(c.name)}`, { method: 'POST' })
      showToast('ok', `Launched '${r.name}'${r.pid ? ` (PID ${r.pid})` : ''} in a new console window.`)
      window.setTimeout(() => { void forceRefresh(); void cmdsState.refresh() }, 1500)
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      showToast('err', `Launch failed: ${msg}`)
    } finally {
      setRunning(s => { const n = new Set(s); n.delete(c.name); return n })
    }
  }

  const ordered = useMemo(() => {
    const commands = cmdsState.data?.commands ?? []
    const order = cmdsState.data?.order
    if (!order || order.length === 0) return commands
    const byName = new Map(commands.map(c => [c.name, c]))
    const result: Command[] = []
    for (const n of order) { const c = byName.get(n); if (c) { result.push(c); byName.delete(n) } }
    return [...result, ...byName.values()]
  }, [cmdsState.data])

  const grouped = useMemo(() => {
    const g: Record<Command['section'], Command[]> = { VM: [], Battlegroup: [], Tools: [] }
    for (const c of ordered) g[c.section]?.push(c)
    return g
  }, [ordered])

  return (
    <>
      <PageHeader
        title="Commands"
        icon="Zap"
        description="Quick actions for the VM, battlegroup, and supporting tools. Each command launches in a new console window."
        actions={
          <button
            className="btn-secondary"
            onClick={() => { void cmdsState.refresh(); void forceRefresh() }}
            disabled={cmdsState.loading}
          >
            <Icon name="RefreshCw" size={15} className={cmdsState.loading ? 'animate-spin' : ''} /> Refresh
          </button>
        }
      />

      {toast && (
        <div className={`card p-3 mb-4 text-sm flex items-center gap-2 ${
          toast.kind === 'ok'
            ? 'border-success/40 bg-success/10 text-success'
            : 'border-danger/40 bg-danger/10 text-danger'
        }`}>
          <Icon name={toast.kind === 'ok' ? 'CheckCircle2' : 'AlertCircle'} size={14} />
          {toast.msg}
        </div>
      )}

      {cmdsState.error && (
        <div className="card p-3 mb-4 border-danger/40 bg-danger/10 text-danger text-sm flex items-center gap-2">
          <Icon name="AlertCircle" size={14} /> {cmdsState.error}
        </div>
      )}

      <section className="space-y-5">
        {SECTION_ORDER.map(section => {
          const items = grouped[section]
          if (!items || items.length === 0) return null
          return (
            <div key={section} className="card p-5">
              <div className="flex items-center justify-between mb-4">
                <h2 className="text-sm font-semibold uppercase tracking-wider text-text-muted flex items-center gap-2">
                  <Icon name={SECTION_ICONS[section]} size={14} className="text-accent" />
                  {section}
                </h2>
                <span className="text-xs text-text-dim">{items.length} {items.length === 1 ? 'command' : 'commands'}</span>
              </div>
              <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
                {items.map(c => (
                  <CommandButton key={c.name} cmd={c} onRun={runCommand} busy={running.has(c.name)} />
                ))}
              </div>
            </div>
          )
        })}

        {cmdsState.loading && !cmdsState.data && (
          <div className="card p-8 text-center text-text-muted">Loading commands…</div>
        )}
      </section>
    </>
  )
}
