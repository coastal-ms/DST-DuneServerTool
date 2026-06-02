import { useState, useEffect, useMemo, useCallback, useRef } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { useStatus } from '../hooks/useStatus'
import { api } from '../api/client'
import {
  getDbInfo,
  runSql,
  getBackupSchedule,
  putBackupSchedule,
  getBackupHistory,
} from '../api/database'
import type {
  DbInfo,
  SqlResult,
  SqlOkResult,
  BackupSchedule,
  BackupHistory,
} from '../api/types'
import Editor, { type OnMount } from '@monaco-editor/react'

type CmdLaunch = { ok: boolean; name: string; pid?: number; mode: string }
type FixMapsResult = { ok: boolean; output?: string; logTail?: string; message?: string }

const DEFAULT_SQL = `-- Read-only by default. Toggle the switch to allow writes.
SELECT current_database(), current_user, version();`

export function Database() {
  const { status, forceRefresh } = useStatus()
  const vmRunning = status?.vm?.running === true
  const bgState = status?.bg?.state ?? 'unknown'

  // ---------- Backup / Restore (delegates to /api/commands/run) ------------
  // Availability is derived from the LIVE status poll (vmRunning + bgState),
  // mirroring the server gate in Commands.ps1. We deliberately do NOT read a
  // one-shot /api/commands snapshot here: that fetch only re-ran when bgState
  // changed, so a single transient/empty reading could latch the buttons
  // disabled with no recovery while the dashboard still showed the BG running.
  // The server re-checks availability on POST /api/commands/run, so deriving
  // client-side here is safe.
  const backupAvailable  = vmRunning && bgState !== 'stopped'   // backup dumps the live DB
  const restoreAvailable = vmRunning && bgState !== 'running'   // restore needs BG stopped
  const [launching, setLaunching] = useState<string | null>(null)
  const [toast, setToast] = useState<{ kind: 'ok' | 'err'; msg: string } | null>(null)

  const showToast = useCallback((kind: 'ok' | 'err', msg: string) => {
    setToast({ kind, msg })
    window.setTimeout(() => setToast(t => (t?.msg === msg ? null : t)), 4000)
  }, [])

  async function runMaint(name: 'backup' | 'import') {
    setLaunching(name)
    try {
      const r = await api<CmdLaunch>(`/api/commands/run/${name}`, { method: 'POST' })
      showToast('ok', `Launched '${r.name}'${r.pid ? ` (PID ${r.pid})` : ''} in a new console window.`)
      window.setTimeout(() => { void forceRefresh() }, 1500)
    } catch (e) {
      showToast('err', `Launch failed: ${e instanceof Error ? e.message : String(e)}`)
    } finally {
      setLaunching(null)
    }
  }

  // ---------- Fix on-demand maps (captured output) -------------------------
  // Re-runs the remote partition-cleanup script and tails its log into the
  // pane below. Unlike backup/restore this runs server-side and returns the
  // captured output instead of opening a console window.
  const fixMapsAvailable = vmRunning && bgState === 'running'
  const [fixingMaps, setFixingMaps] = useState(false)
  const [fixMapsOut, setFixMapsOut] = useState<FixMapsResult | null>(null)

  async function runFixMaps() {
    setFixingMaps(true)
    setFixMapsOut(null)
    try {
      const r = await api<FixMapsResult>('/api/maps/fix-partitions', { method: 'POST' })
      setFixMapsOut(r)
      showToast('ok', 'Partition cleanup ran — see the output below.')
      window.setTimeout(() => { void forceRefresh() }, 1500)
    } catch (e) {
      showToast('err', `Fix failed: ${e instanceof Error ? e.message : String(e)}`)
    } finally {
      setFixingMaps(false)
    }
  }

  // ---------- DB info (version, table list) --------------------------------
  const [dbInfo, setDbInfo] = useState<DbInfo | null>(null)
  const [dbInfoErr, setDbInfoErr] = useState<string | null>(null)
  const [dbInfoLoading, setDbInfoLoading] = useState(false)

  const loadDbInfo = useCallback(async () => {
    if (!vmRunning) {
      setDbInfo(null)
      setDbInfoErr('VM is not running.')
      return
    }
    setDbInfoLoading(true)
    setDbInfoErr(null)
    try {
      const info = await getDbInfo()
      setDbInfo(info)
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      setDbInfoErr(msg)
      setDbInfo(null)
    } finally {
      setDbInfoLoading(false)
    }
  }, [vmRunning])

  useEffect(() => { void loadDbInfo() }, [loadDbInfo])

  // ---------- SQL editor ----------------------------------------------------
  const [sql, setSql] = useState<string>(DEFAULT_SQL)
  const [readOnly, setReadOnly] = useState<boolean>(true)
  const [maxRows, setMaxRows] = useState<number>(1000)
  const [running, setRunning] = useState(false)
  const [result, setResult] = useState<SqlResult | null>(null)
  const [confirmWrite, setConfirmWrite] = useState<boolean>(false)
  const editorRef = useRef<{ getValue?: () => string } | null>(null)

  const onEditorMount: OnMount = (editor) => {
    editorRef.current = editor
    // Ctrl+Enter to run
    editor.addCommand(
      // monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter
      // We can't import monaco at top level without bundling — use the magic numbers.
      // Ctrl = 2048, Enter = 3
      2048 | 3,
      () => { void executeQuery() }
    )
  }

  async function executeQuery() {
    const current = editorRef.current?.getValue?.() ?? sql
    if (!current.trim()) return
    if (!readOnly && !confirmWrite) {
      const ok = window.confirm(
        'Read-only mode is OFF. This SQL will execute against the live database and changes are PERMANENT.\n\nProceed?'
      )
      if (!ok) return
      setConfirmWrite(true)
    }
    setRunning(true)
    setResult(null)
    try {
      const r = await runSql({ sql: current, readOnly, maxRows })
      setResult(r)
    } catch (e) {
      setResult({
        ok: false,
        error: e instanceof Error ? e.message : String(e),
        durationMs: 0,
        readOnly,
      })
    } finally {
      setRunning(false)
    }
  }

  function downloadCsv() {
    if (!result || !result.ok || result.rows.length === 0) return
    const esc = (v: string | null | undefined) => {
      if (v == null) return ''
      const s = String(v)
      if (/[",\n]/.test(s)) return `"${s.replace(/"/g, '""')}"`
      return s
    }
    const lines = [
      result.columns.map(esc).join(','),
      ...result.rows.map(r => r.map(esc).join(',')),
    ]
    const blob = new Blob([lines.join('\n')], { type: 'text/csv;charset=utf-8' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `query-${new Date().toISOString().replace(/[:.]/g, '-')}.csv`
    a.click()
    URL.revokeObjectURL(url)
  }

  // ---------- Render -------------------------------------------------------
  const showStopBanner = vmRunning && bgState === 'running'

  return (
    <>
      <PageHeader
        title="Database"
        icon="Database"
        description="Backup / restore the BG database and run ad-hoc SQL queries."
        actions={
          <button
            type="button"
            onClick={() => { void loadDbInfo(); void forceRefresh() }}
            disabled={!vmRunning || dbInfoLoading}
            className="btn-secondary"
          >
            <Icon name={dbInfoLoading ? 'Loader2' : 'RefreshCw'} size={14} className={dbInfoLoading ? 'animate-spin' : ''} />
            Refresh
          </button>
        }
      />

      {toast && (
        <div className={`card p-3 mb-4 text-sm flex items-center gap-2 ${toast.kind === 'ok'
          ? 'border-success/40 bg-success/10 text-success'
          : 'border-danger/40 bg-danger/10 text-danger'}`}>
          <Icon name={toast.kind === 'ok' ? 'CheckCircle2' : 'AlertCircle'} size={14} />
          {toast.msg}
        </div>
      )}

      {showStopBanner && (
        <div className="card p-3 mb-4 border-warning/40 bg-warning/10 text-warning text-sm flex items-start gap-2">
          <Icon name="AlertTriangle" size={16} className="mt-0.5 shrink-0" />
          <div>
            <span className="font-medium">Stop the battlegroup first</span> — backups taken while running may be inconsistent, and restores require the BG stopped.
          </div>
        </div>
      )}

      {/* Maintenance cards: Backup + Restore */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mb-6">
        <MaintCard
          title="Take Backup"
          icon="Download"
          tone="success"
          description="Snapshot the BG's PostgreSQL database to a timestamped file on the VM. Recommended before any character or game-config change."
          hint={
            !vmRunning ? 'VM must be running to take a backup.'
            : bgState !== 'running' ? 'Start the battlegroup first; backup queries the live database.'
            : 'Battlegroup is running — backup will open in a new console window.'
          }
          buttonLabel="Take Backup"
          available={backupAvailable}
          busy={launching === 'backup'}
          onClick={() => void runMaint('backup')}
        />
        <MaintCard
          title="Restore Backup"
          icon="Upload"
          tone="ibad"
          description="Replace the BG database with a previously taken backup. The battlegroup must be stopped, and this operation cannot be undone."
          hint={
            !vmRunning ? 'VM must be running to restore a backup.'
            : bgState === 'running' ? 'Stop the battlegroup first to avoid database corruption.'
            : 'Battlegroup is stopped — choose the backup file in the console window.'
          }
          buttonLabel="Restore Backup"
          available={restoreAvailable}
          busy={launching === 'import'}
          onClick={() => void runMaint('import')}
        />
      </div>

      {/* Configurable backup schedule (writes the VM's root crontab) */}
      <BackupScheduleCard vmRunning={vmRunning} showToast={showToast} />

      {/* Fix on-demand maps — captured output */}
      <div className="card p-5 flex flex-col mb-6">
        <div className="flex items-center gap-3 mb-3">
          <Icon name="Wrench" size={22} className="text-warning" />
          <h2 className="text-base font-semibold tracking-tight text-warning">Fix on-demand maps</h2>
        </div>
        <p className="text-sm text-text-muted mb-3">
          Clears the drifted partition pin that stops DeepDesert, Arrakeen and Harko Village from launching on demand.
          Runs on the VM, then shows the last 10 lines of the cleanup log below. Idempotent — it skips any map that already
          has a running pod, so it's safe to run again whenever a map refuses to start.
        </p>
        <p className="text-xs text-text-dim mb-4">
          {!vmRunning ? 'VM must be running to run the cleanup.'
            : bgState !== 'running' ? 'Start the battlegroup first; the cleanup targets the live deployment.'
            : 'Battlegroup is running — click to clear the pinned partitions.'}
        </p>
        <div>
          <button
            type="button"
            onClick={() => void runFixMaps()}
            disabled={!fixMapsAvailable || fixingMaps}
            className="btn-primary"
          >
            <Icon name={fixingMaps ? 'Loader2' : 'Wrench'} size={14} className={fixingMaps ? 'animate-spin' : ''} />
            {fixingMaps ? 'Running…' : 'Fix on-demand maps'}
          </button>
        </div>
        {fixMapsOut && (
          <div className="mt-4 space-y-3">
            {fixMapsOut.output && (
              <div>
                <div className="text-xs font-semibold text-text-muted mb-1">Script output</div>
                <pre className="text-xs font-mono bg-surface-2 border border-border rounded p-3 overflow-x-auto whitespace-pre-wrap">{fixMapsOut.output}</pre>
              </div>
            )}
            {fixMapsOut.logTail && (
              <div>
                <div className="text-xs font-semibold text-text-muted mb-1">/var/log/dune-clear-partitions.log (last 10 lines)</div>
                <pre className="text-xs font-mono bg-surface-2 border border-border rounded p-3 overflow-x-auto whitespace-pre-wrap">{fixMapsOut.logTail}</pre>
              </div>
            )}
            {!fixMapsOut.output && !fixMapsOut.logTail && (
              <p className="text-xs text-text-dim">{fixMapsOut.message ?? 'Cleanup ran (no output captured).'}</p>
            )}
          </div>
        )}
      </div>

      {/* SQL editor card */}
      <div className="card overflow-hidden mb-4">
        <div className="px-4 py-3 border-b border-border flex items-center justify-between gap-3">
          <div className="flex items-center gap-2 text-sm">
            <Icon name="Terminal" size={14} className="text-accent-bright" />
            <span className="font-semibold">SQL Editor</span>
            {dbInfo && (
              <span className="text-xs text-text-muted font-mono ml-2 truncate" title={dbInfo.version}>
                {dbInfo.database} · {dbInfo.user}
              </span>
            )}
          </div>
          <div className="flex items-center gap-3">
            <label className="flex items-center gap-2 text-xs cursor-pointer select-none">
              <input
                type="checkbox"
                checked={readOnly}
                onChange={e => { setReadOnly(e.target.checked); if (e.target.checked) setConfirmWrite(false) }}
                className="accent-ibad"
              />
              <span className={readOnly ? 'text-success' : 'text-warning'}>
                {readOnly ? 'Read-only' : 'Writes ALLOWED'}
              </span>
            </label>
            <label className="flex items-center gap-1.5 text-xs text-text-muted">
              max rows
              <input
                type="number"
                value={maxRows}
                min={1}
                max={50000}
                step={100}
                onChange={e => setMaxRows(Math.max(1, parseInt(e.target.value || '1000', 10)))}
                className="w-20 px-2 py-1 rounded bg-surface-2 border border-border text-text text-xs font-mono"
              />
            </label>
            <button
              type="button"
              onClick={() => void executeQuery()}
              disabled={running || !vmRunning}
              className="btn-primary"
              title="Run (Ctrl+Enter)"
            >
              <Icon name={running ? 'Loader2' : 'Play'} size={14} className={running ? 'animate-spin' : ''} />
              {running ? 'Running…' : 'Run'}
            </button>
          </div>
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-[1fr_220px]">
          <div className="border-r border-border" style={{ minHeight: 280 }}>
            <Editor
              height="280px"
              defaultLanguage="sql"
              defaultValue={DEFAULT_SQL}
              theme="vs-dark"
              onMount={onEditorMount}
              onChange={(v) => setSql(v ?? '')}
              options={{
                minimap: { enabled: false },
                fontSize: 13,
                fontFamily: 'ui-monospace, Menlo, Consolas, monospace',
                scrollBeyondLastLine: false,
                lineNumbers: 'on',
                wordWrap: 'on',
                tabSize: 2,
                automaticLayout: true,
              }}
            />
          </div>
          <TableList tables={dbInfo?.tables ?? []} loading={dbInfoLoading} err={dbInfoErr} onInsertName={(s, n) => {
            const v = editorRef.current?.getValue?.() ?? sql
            const insertion = s === 'public' ? n : `${s}.${n}`
            setSql(v + (v.endsWith('\n') || v === '' ? '' : '\n') + `SELECT * FROM ${insertion} LIMIT 100;`)
          }} />
        </div>
      </div>

      {/* Results panel */}
      <ResultsPanel result={result} onExportCsv={downloadCsv} />
    </>
  )
}

// -----------------------------------------------------------------------------
// Maintenance card
// -----------------------------------------------------------------------------
type MaintCardProps = {
  title: string
  icon: string
  tone: 'success' | 'ibad'
  description: string
  hint: string
  buttonLabel: string
  available: boolean
  busy: boolean
  onClick: () => void
}
function MaintCard(p: MaintCardProps) {
  const accent = p.tone === 'success' ? 'text-success' : 'text-accent-bright'
  return (
    <div className="card p-5 flex flex-col">
      <div className="flex items-center gap-3 mb-3">
        <Icon name={p.icon} size={22} className={accent} />
        <h2 className={'text-base font-semibold tracking-tight ' + accent}>{p.title}</h2>
      </div>
      <p className="text-sm text-text-muted mb-3 flex-1">{p.description}</p>
      <p className="text-xs text-text-dim mb-4">{p.hint}</p>
      <div>
        <button
          type="button"
          onClick={p.onClick}
          disabled={!p.available || p.busy}
          className={p.tone === 'success' ? 'btn-secondary' : 'btn-primary'}
        >
          <Icon name={p.busy ? 'Loader2' : p.icon} size={14} className={p.busy ? 'animate-spin' : ''} />
          {p.busy ? 'Launching…' : p.buttonLabel}
        </button>
      </div>
    </div>
  )
}

// -----------------------------------------------------------------------------
// Table list sidebar
// -----------------------------------------------------------------------------
function TableList({
  tables, loading, err, onInsertName,
}: {
  tables: { schema: string; name: string; kind: string }[]
  loading: boolean
  err: string | null
  onInsertName: (schema: string, name: string) => void
}) {
  const [filter, setFilter] = useState('')
  const filtered = useMemo(() => {
    if (!filter) return tables
    const lc = filter.toLowerCase()
    return tables.filter(t => t.name.toLowerCase().includes(lc) || t.schema.toLowerCase().includes(lc))
  }, [tables, filter])

  return (
    <div className="bg-surface flex flex-col" style={{ maxHeight: 280 }}>
      <div className="p-2 border-b border-border">
        <input
          type="text"
          value={filter}
          onChange={e => setFilter(e.target.value)}
          placeholder="Filter tables…"
          className="w-full px-2 py-1 text-xs rounded bg-surface-2 border border-border text-text placeholder:text-text-dim"
        />
      </div>
      <div className="overflow-auto flex-1 text-xs font-mono">
        {loading && <div className="p-3 text-text-muted flex items-center gap-2"><Icon name="Loader2" size={12} className="animate-spin" /> Loading…</div>}
        {err && !loading && <div className="p-3 text-warning">{err}</div>}
        {!loading && !err && filtered.length === 0 && <div className="p-3 text-text-dim italic">No tables.</div>}
        {filtered.map(t => (
          <button
            key={`${t.schema}.${t.name}`}
            type="button"
            onClick={() => onInsertName(t.schema, t.name)}
            className="w-full px-3 py-1 text-left hover:bg-surface-2 flex items-center gap-2 border-b border-border/30 last:border-0"
            title={`${t.schema}.${t.name} (${kindLabel(t.kind)}) — click to insert SELECT`}
          >
            <span className={kindColor(t.kind)}>●</span>
            {t.schema !== 'public' && <span className="text-text-dim">{t.schema}.</span>}
            <span className="text-text truncate">{t.name}</span>
          </button>
        ))}
      </div>
    </div>
  )
}

function kindLabel(k: string): string {
  switch (k) {
    case 'r': return 'table'
    case 'v': return 'view'
    case 'm': return 'mat-view'
    case 'f': return 'foreign'
    case 'p': return 'partitioned'
    default:  return k
  }
}
function kindColor(k: string): string {
  switch (k) {
    case 'r': return 'text-ibad'
    case 'v': return 'text-info'
    case 'm': return 'text-success'
    case 'p': return 'text-warning'
    default:  return 'text-text-dim'
  }
}

// -----------------------------------------------------------------------------
// Results panel
// -----------------------------------------------------------------------------
function ResultsPanel({ result, onExportCsv }: { result: SqlResult | null; onExportCsv: () => void }) {
  if (!result) {
    return (
      <div className="card p-6 text-center text-text-muted text-sm">
        Press <kbd className="px-1.5 py-0.5 text-xs font-mono bg-surface-2 border border-border rounded">Ctrl+Enter</kbd> or click <strong>Run</strong> to execute the SQL above.
      </div>
    )
  }
  if (!result.ok) {
    return (
      <div className="card p-4 border-danger/40">
        <div className="flex items-center gap-2 text-danger text-sm font-semibold mb-2">
          <Icon name="AlertCircle" size={14} /> Query failed
          <span className="text-xs text-text-muted font-normal ml-auto">{result.durationMs} ms</span>
        </div>
        <pre className="text-xs font-mono whitespace-pre-wrap text-danger/90 bg-surface-2 p-3 rounded border border-border">
          {result.error}
        </pre>
      </div>
    )
  }
  const ok = result as SqlOkResult
  const hasRows = ok.rows.length > 0
  return (
    <div className="card overflow-hidden">
      <div className="px-4 py-2 border-b border-border flex items-center justify-between text-xs">
        <div className="flex items-center gap-3 text-text-muted">
          <span className="flex items-center gap-1.5 text-success">
            <Icon name="CircleCheck" size={12} /> OK
          </span>
          {ok.message && <span className="font-mono text-text">{ok.message}</span>}
          {hasRows && <span><strong className="text-text">{ok.rowCount}</strong> rows</span>}
          {ok.truncated && <span className="pill-warning"><Icon name="AlertTriangle" size={10} /> truncated at {ok.maxRows}</span>}
          <span>{ok.durationMs} ms</span>
          {ok.readOnly && <span className="pill-info"><Icon name="Lock" size={10} /> RO</span>}
        </div>
        {hasRows && (
          <button type="button" onClick={onExportCsv} className="btn-secondary text-xs">
            <Icon name="Download" size={12} /> CSV
          </button>
        )}
      </div>
      {hasRows ? (
        <div className="overflow-auto" style={{ maxHeight: 500 }}>
          <table className="w-full text-xs font-mono">
            <thead className="bg-surface-2 sticky top-0">
              <tr>
                {ok.columns.map(c => (
                  <th key={c} className="px-3 py-2 text-left border-b border-border font-semibold text-accent-bright whitespace-nowrap">
                    {c}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {ok.rows.map((row, i) => (
                <tr key={i} className="hover:bg-surface-2/50 border-b border-border/30">
                  {row.map((v, j) => (
                    <td key={j} className="px-3 py-1.5 text-text align-top whitespace-pre-wrap break-words max-w-md">
                      {v == null ? <span className="text-text-dim italic">NULL</span> : String(v)}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <div className="p-4 text-sm text-text-muted">
          {ok.message ? <span className="font-mono">{ok.message}</span> : 'No rows returned.'}
        </div>
      )}
    </div>
  )
}

// -----------------------------------------------------------------------------
// Backup schedule card — read/edit the managed crontab block on the VM.
// -----------------------------------------------------------------------------
type BackupScheduleCardProps = {
  vmRunning: boolean
  showToast: (kind: 'ok' | 'err', msg: string) => void
}

function BackupScheduleCard({ vmRunning, showToast }: BackupScheduleCardProps) {
  const [schedule, setSchedule] = useState<BackupSchedule | null>(null)
  const [history, setHistory]   = useState<BackupHistory  | null>(null)
  const [loading, setLoading]   = useState(false)
  const [saving, setSaving]     = useState(false)
  const [err, setErr]           = useState<string | null>(null)
  const [showLog, setShowLog]   = useState(false)

  // Draft state — initialised from `schedule` when it loads, then locally
  // editable so the user can preview their choice before clicking Save.
  const [draftPreset, setDraftPreset]       = useState<string>('Off')
  const [draftRetention, setDraftRetention] = useState<number>(30)

  const loadAll = useCallback(async () => {
    if (!vmRunning) {
      setSchedule(null); setHistory(null); setErr('VM is not running.')
      return
    }
    setLoading(true); setErr(null)
    try {
      const [sched, hist] = await Promise.all([getBackupSchedule(), getBackupHistory({ recent: 5, logLines: 50 })])
      setSchedule(sched)
      setHistory(hist)
      setDraftPreset(sched.preset === 'Custom' ? 'Off' : sched.preset)
      setDraftRetention(sched.retentionDays)
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
      setSchedule(null); setHistory(null)
    } finally {
      setLoading(false)
    }
  }, [vmRunning])

  useEffect(() => { void loadAll() }, [loadAll])

  const dirty = useMemo(() => {
    if (!schedule) return false
    return draftPreset !== schedule.preset || draftRetention !== schedule.retentionDays
  }, [schedule, draftPreset, draftRetention])

  async function save() {
    if (!schedule) return
    setSaving(true)
    try {
      const updated = await putBackupSchedule({ preset: draftPreset, retentionDays: draftRetention })
      setSchedule(updated)
      setDraftPreset(updated.preset === 'Custom' ? 'Off' : updated.preset)
      setDraftRetention(updated.retentionDays)
      showToast('ok', draftPreset === 'Off' ? 'Schedule disabled.' : `Schedule saved (${draftPreset}, retention ${draftRetention}d).`)
      // Refresh history in the background so the user sees the new schedule
      // reflected immediately when the next cron run lands.
      void getBackupHistory({ recent: 5, logLines: 50 }).then(setHistory).catch(() => {})
    } catch (e) {
      showToast('err', `Save failed: ${e instanceof Error ? e.message : String(e)}`)
    } finally {
      setSaving(false)
    }
  }

  const presetChoices = schedule?.presets ?? [
    { id: 'Off',            label: 'Disabled' },
    { id: 'Hourly',         label: 'Every hour' },
    { id: 'Every6Hours',    label: 'Every 6 hours' },
    { id: 'DailyUtc04',     label: 'Daily at 04:00' },
    { id: 'TwiceDailyUtc',  label: 'Twice daily (04:00 and 16:00)' },
    { id: 'WeeklyMonUtc04', label: 'Weekly, Monday 04:00' },
  ]

  const tzLabel = schedule?.vmTimezone || 'UTC'
  const lastBackup = history?.recent?.[0]

  return (
    <div className="card p-5 flex flex-col mb-6">
      <div className="flex items-center gap-3 mb-3">
        <Icon name="Clock" size={22} className="text-info" />
        <h2 className="text-base font-semibold tracking-tight text-info">Backup Schedule</h2>
        <span className="ml-auto text-xs text-text-muted">
          Runs on the VM via root crontab. Edits write to <span className="font-mono">/etc/crontabs/root</span>.
        </span>
      </div>
      <p className="text-sm text-text-muted mb-3">
        Run <span className="font-mono">battlegroup backup</span> on a recurring schedule. Times are in the VM's
        timezone (<span className="font-mono">{tzLabel}</span>). Backups land in{' '}
        <span className="font-mono">{history?.dumpDirPath ?? '/funcom/artifacts/database-dumps'}</span> alongside
        Funcom's own ~3-hourly auto-backups.
      </p>

      {!vmRunning && (
        <p className="text-xs text-warning mb-3 flex items-center gap-1.5">
          <Icon name="AlertTriangle" size={12} /> VM must be running to read or edit the schedule.
        </p>
      )}

      {err && (
        <p className="text-xs text-danger mb-3 flex items-center gap-1.5">
          <Icon name="AlertCircle" size={12} /> {err}
        </p>
      )}

      {schedule && !schedule.crondRunning && (
        <p className="text-xs text-warning mb-3 flex items-start gap-1.5">
          <Icon name="AlertTriangle" size={12} className="mt-0.5 shrink-0" />
          <span>
            crond does not appear to be running on the VM — schedule entries will not fire.
            Start it with <span className="font-mono">sudo rc-service crond start</span> (and{' '}
            <span className="font-mono">sudo rc-update add crond default</span> to enable at boot).
          </span>
        </p>
      )}

      {schedule?.hasUnmanagedBackupLines && (
        <p className="text-xs text-warning mb-3 flex items-start gap-1.5">
          <Icon name="AlertTriangle" size={12} className="mt-0.5 shrink-0" />
          <span>
            The crontab also contains a <span className="font-mono">battlegroup backup</span> line outside the
            managed block. Saving here won't remove it — review with <span className="font-mono">sudo crontab -l</span>.
          </span>
        </p>
      )}

      {schedule?.managedBlockLooksTampered && (
        <p className="text-xs text-warning mb-3 flex items-start gap-1.5">
          <Icon name="AlertTriangle" size={12} className="mt-0.5 shrink-0" />
          <span>
            The managed block was edited outside this app. Clicking Save will overwrite those edits with the preset above.
          </span>
        </p>
      )}

      <div className="grid grid-cols-1 md:grid-cols-[1fr_180px_auto] gap-3 items-end mb-4">
        <label className="flex flex-col gap-1 text-xs">
          <span className="text-text-muted font-medium">Schedule</span>
          <select
            value={draftPreset}
            onChange={e => setDraftPreset(e.target.value)}
            disabled={!vmRunning || loading || saving}
            className="px-2 py-1.5 rounded bg-surface-2 border border-border text-text text-sm"
          >
            {presetChoices.map(p => (
              <option key={p.id} value={p.id}>{p.label}</option>
            ))}
          </select>
        </label>
        <label className="flex flex-col gap-1 text-xs">
          <span className="text-text-muted font-medium">
            Retention (days){draftRetention === 0 ? ' — keep forever' : ''}
          </span>
          <input
            type="number"
            min={0}
            max={3650}
            step={1}
            value={draftRetention}
            onChange={e => {
              const n = parseInt(e.target.value || '0', 10)
              setDraftRetention(Number.isFinite(n) ? Math.max(0, Math.min(3650, n)) : 0)
            }}
            disabled={!vmRunning || loading || saving || draftPreset === 'Off'}
            className="px-2 py-1.5 rounded bg-surface-2 border border-border text-text text-sm font-mono w-full"
          />
        </label>
        <div className="flex gap-2">
          <button
            type="button"
            onClick={() => void loadAll()}
            disabled={!vmRunning || loading || saving}
            className="btn-secondary"
          >
            <Icon name={loading ? 'Loader2' : 'RefreshCw'} size={14} className={loading ? 'animate-spin' : ''} />
            Refresh
          </button>
          <button
            type="button"
            onClick={() => void save()}
            disabled={!vmRunning || loading || saving || !dirty}
            className="btn-primary"
            title={dirty ? 'Install the new schedule on the VM' : 'No changes to save'}
          >
            <Icon name={saving ? 'Loader2' : 'Save'} size={14} className={saving ? 'animate-spin' : ''} />
            {saving ? 'Saving…' : 'Save schedule'}
          </button>
        </div>
      </div>

      {schedule && (
        <p className="text-xs text-text-dim mb-3">
          Currently installed:{' '}
          {schedule.enabled
            ? <>
                <strong className="text-text">{schedule.preset}</strong>
                {schedule.retentionDays > 0
                  ? <> · retention <strong className="text-text">{schedule.retentionDays}d</strong></>
                  : <> · no retention pruning</>}
              </>
            : <strong className="text-text">Off</strong>}
          {' · '}VM time <span className="font-mono">{schedule.vmNowUtc} ({tzLabel})</span>
        </p>
      )}

      <div className="border-t border-border pt-3 mt-1">
        <div className="flex items-center justify-between gap-3 mb-2">
          <div className="text-xs font-semibold text-text-muted">Recent backups</div>
          <div className="text-xs text-text-dim">
            {history?.dumpDirSize ? <>Dump dir: <span className="font-mono">{history.dumpDirSize}</span></> : null}
          </div>
        </div>
        {!history || history.recent.length === 0 ? (
          <p className="text-xs text-text-dim italic">
            {vmRunning ? 'No backup files found yet.' : 'VM not running.'}
          </p>
        ) : (
          <ul className="text-xs font-mono space-y-1">
            {history.recent.map(f => (
              <li key={f.path} className="flex items-baseline gap-2">
                <span className="text-text">{f.mtimeIso}</span>
                <span className="text-text-muted">{(f.sizeBytes / (1024 * 1024)).toFixed(1)} MB</span>
                <span className="text-text-dim truncate" title={f.path}>{f.path.replace(/^\/funcom\/artifacts\/database-dumps\//, '')}</span>
              </li>
            ))}
          </ul>
        )}
        {lastBackup && (
          <p className="text-xs text-text-dim mt-2">
            Last backup at <span className="font-mono">{lastBackup.mtimeIso}</span> ({relativeFromNow(lastBackup.mtimeEpoch)}).
          </p>
        )}
      </div>

      {history?.logTail && (
        <div className="mt-3">
          <button
            type="button"
            onClick={() => setShowLog(v => !v)}
            className="text-xs text-info hover:underline flex items-center gap-1"
          >
            <Icon name={showLog ? 'ChevronDown' : 'ChevronRight'} size={12} />
            {showLog ? 'Hide' : 'Show'} log tail (<span className="font-mono">{history.logPath}</span>, last 50 lines)
          </button>
          {showLog && (
            <pre className="mt-2 text-xs font-mono bg-surface-2 border border-border rounded p-3 overflow-x-auto whitespace-pre-wrap max-h-64">
              {history.logTail || '(empty)'}
            </pre>
          )}
        </div>
      )}

      <p className="text-xs text-text-dim mt-3 italic">
        Note: this schedule lives in the VM's root crontab. If the VM is reprovisioned the schedule is lost
        and must be re-installed from here.
      </p>
    </div>
  )
}

function relativeFromNow(epochSeconds: number): string {
  const deltaSec = Math.floor(Date.now() / 1000) - epochSeconds
  if (deltaSec < 60)        return `${deltaSec}s ago`
  if (deltaSec < 3600)      return `${Math.floor(deltaSec / 60)}m ago`
  if (deltaSec < 86400)     return `${Math.floor(deltaSec / 3600)}h ago`
  if (deltaSec < 86400 * 7) return `${Math.floor(deltaSec / 86400)}d ago`
  return `${Math.floor(deltaSec / 86400)}d ago`
}
