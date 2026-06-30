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
  downloadBackup,
  uploadBackup,
  getBackupDumpPods,
  pruneBackupDumpPods,
} from '../api/database'
import type {
  DbInfo,
  SqlResult,
  SqlOkResult,
  BackupSchedule,
  BackupHistory,
  BackupDumpPodList,
} from '../api/types'
import Editor, { type OnMount } from '@monaco-editor/react'

type CmdLaunch = { ok: boolean; name: string; pid?: number; mode: string }
type FixMapsResult = { ok: boolean; output?: string; logTail?: string; message?: string }

// WebView2 shell bridge: request a native file dialog and get the chosen path back.
// Posts a message to the shell (MainForm.cs) which shows the dialog and responds
// via window.chrome.webview.addEventListener('message', ...).
function pickFileFromShell(action: 'pick-save-file' | 'pick-open-file', opts: { id: string; defaultName?: string; filter?: string }): Promise<string | null> {
  return new Promise(resolve => {
    const wv = (window as any).chrome?.webview
    if (!wv) {
      // Not running in WebView2 (e.g. browser portal) — fall through gracefully
      resolve(null)
      return
    }
    function handler(e: MessageEvent) {
      const data = typeof e.data === 'string' ? JSON.parse(e.data) : e.data
      if (data?.action === 'file-picked' && data?.id === opts.id) {
        wv.removeEventListener('message', handler)
        resolve(data.path ?? null)
      }
    }
    wv.addEventListener('message', handler)
    wv.postMessage({ action, ...opts })
    // Timeout: if the dialog is cancelled or shell doesn't respond within 5 min
    setTimeout(() => { wv.removeEventListener('message', handler); resolve(null) }, 300_000)
  })
}

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
    // Restore (import) is a full, destructive replace of the entire BG database —
    // every player, base, inventory, storage, blueprint, and the market rolls back
    // to the chosen snapshot and everything since is permanently lost. Gate it
    // behind a typed confirmation so it can't be triggered by a stray click.
    if (name === 'import') {
      const typed = window.prompt(
        'FULL DATABASE RESTORE — SEVERE, IRREVERSIBLE.\n\n' +
        'This REPLACES the entire battlegroup database with the backup you pick in the console window. ' +
        'ALL players, bases, inventories, storage, blueprints, and the market will be rolled back to that snapshot. ' +
        'Everything created since the backup is permanently lost. This cannot be undone.\n\n' +
        'Take a fresh backup first if you have not. The battlegroup must be stopped.\n\n' +
        'NOTE: restoring a backup onto a DIFFERENT server/battlegroup than it was taken on does NOT reliably restore characters — they are bound to your Funcom account in the cloud, so they may fail to load or get cleared on boot. Cross-server restores recover the world/bases, not character logins. Restore is intended for the SAME server.\n\n' +
        'Type RESTORE to continue:',
      )
      if (typed == null) return
      if (typed.trim().toUpperCase() !== 'RESTORE') {
        showToast('err', 'Restore cancelled — confirmation text did not match.')
        return
      }
    }
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
          description="Full destructive restore — REPLACES the entire BG database with a previously taken backup. All players, bases, inventories, storage, blueprints, and the market roll back to that snapshot; everything since is permanently lost. The battlegroup must be stopped, and this cannot be undone. Restoring onto a different server/BG than it came from won't reliably restore characters (they're cloud-bound to Funcom accounts) — world/bases come back, character logins may not."
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
  const [dumpPods, setDumpPods] = useState<BackupDumpPodList | null>(null)
  const [loading, setLoading]   = useState(false)
  const [saving, setSaving]     = useState(false)
  const [pruning, setPruning]   = useState(false)
  const [err, setErr]           = useState<string | null>(null)
  const [showLog, setShowLog]   = useState(false)
  const [transferring, setTransferring] = useState<string | null>(null)  // vmPath or 'upload'

  // Draft state — initialised from `schedule` when it loads, then locally
  // editable so the user can preview their choice before clicking Save.
  const [draftPreset, setDraftPreset]       = useState<string>('Off')
  const [draftKeepLast, setDraftKeepLast]   = useState<number>(8)
  const [draftKeepDumpPods, setDraftKeepDumpPods] = useState<number>(5)
  const [draftKeepDumpDays, setDraftKeepDumpDays] = useState<number>(0)

  const loadAll = useCallback(async () => {
    if (!vmRunning) {
      setSchedule(null); setHistory(null); setDumpPods(null); setErr('VM is not running.')
      return
    }
    setLoading(true); setErr(null)
    try {
      const [sched, hist, pods] = await Promise.all([
        getBackupSchedule(),
        getBackupHistory({ recent: 5, logLines: 50 }),
        getBackupDumpPods().catch(() => null),
      ])
      setSchedule(sched)
      setHistory(hist)
      setDumpPods(pods)
      setDraftPreset(sched.preset === 'Custom' ? 'Off' : sched.preset)
      setDraftKeepLast(sched.keepLast > 0 ? sched.keepLast : (sched.preset === 'Off' ? 8 : 0))
      setDraftKeepDumpPods(sched.keepLastPods ?? 10)
      setDraftKeepDumpDays(sched.keepDaysPods ?? 0)
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
      setSchedule(null); setHistory(null); setDumpPods(null)
    } finally {
      setLoading(false)
    }
  }, [vmRunning])

  useEffect(() => { void loadAll() }, [loadAll])

  const dirty = useMemo(() => {
    if (!schedule) return false
    // If the schedule was inferred from an unmanaged line (i.e. no managed
    // block exists yet), the user MUST be able to save even though the draft
    // matches the inferred preset — saving is how the line gets migrated.
    if (schedule.inferredFromUnmanaged) return true
    // Likewise, if there are still unmanaged lines outside our block, allow
    // saving so the user can clean them up by re-installing.
    if (schedule.hasUnmanagedBackupLines) return true
    return (
      draftPreset !== schedule.preset ||
      draftKeepLast !== schedule.keepLast ||
      draftKeepDumpPods !== (schedule.keepLastPods ?? 10) ||
      draftKeepDumpDays !== (schedule.keepDaysPods ?? 0)
    )
  }, [schedule, draftPreset, draftKeepLast, draftKeepDumpPods, draftKeepDumpDays])

  async function save() {
    if (!schedule) return
    setSaving(true)
    try {
      const updated = await putBackupSchedule({
        preset: draftPreset,
        keepLast: draftKeepLast,
        keepLastPods: draftKeepDumpPods,
        keepDaysPods: draftKeepDumpDays,
      })
      setSchedule(updated)
      setDraftPreset(updated.preset === 'Custom' ? 'Off' : updated.preset)
      setDraftKeepLast(updated.keepLast > 0 ? updated.keepLast : (updated.preset === 'Off' ? 8 : 0))
      setDraftKeepDumpPods(updated.keepLastPods ?? 10)
      setDraftKeepDumpDays(updated.keepDaysPods ?? 0)
      showToast('ok', draftPreset === 'Off' ? 'Schedule disabled.' : `Schedule saved.`)
      // Refresh history + pod list in the background so the user sees the new
      // schedule reflected immediately when the next cron run lands.
      void getBackupHistory({ recent: 5, logLines: 50 }).then(setHistory).catch(() => {})
      void getBackupDumpPods().then(setDumpPods).catch(() => {})
    } catch (e) {
      showToast('err', `Save failed: ${e instanceof Error ? e.message : String(e)}`)
    } finally {
      setSaving(false)
    }
  }

  async function handleDownload(vmPath: string) {
    const fileName = vmPath.split('/').pop() ?? 'backup.backup'
    const localPath = await pickFileFromShell('pick-save-file', { id: 'backup-download', defaultName: fileName })
    if (!localPath) return  // cancelled
    setTransferring(vmPath)
    try {
      const r = await downloadBackup({ vmPath, localPath })
      showToast('ok', r.message ?? 'Download complete.')
    } catch (e) {
      showToast('err', `Download failed: ${e instanceof Error ? e.message : String(e)}`)
    } finally {
      setTransferring(null)
    }
  }

  async function handleUpload() {
    const localPath = await pickFileFromShell('pick-open-file', { id: 'backup-upload' })
    if (!localPath) return  // cancelled
    setTransferring('upload')
    try {
      const r = await uploadBackup({ localPath })
      showToast('ok', r.message ?? 'Upload complete.')
      // Refresh history so the new file appears
      void getBackupHistory({ recent: 5, logLines: 50 }).then(setHistory).catch(() => {})
    } catch (e) {
      showToast('err', `Upload failed: ${e instanceof Error ? e.message : String(e)}`)
    } finally {
      setTransferring(null)
    }
  }

  async function handlePruneDumpPods() {
    setPruning(true)
    try {
      const r = await pruneBackupDumpPods({ keepLast: draftKeepDumpPods, keepDays: draftKeepDumpDays })
      const delCount = r.deleted?.length ?? 0
      const keepCount = r.kept?.length ?? 0
      showToast('ok', delCount > 0
        ? `Deleted ${delCount} dump pod(s); kept ${keepCount}.`
        : (r.message ?? 'Nothing to prune.'))
      // Trust the server response: `r.remaining` is from a fresh kubectl
      // read on the SAME SSH session as the deletes (with a 1s settle so
      // the API server has indexed them). A second background fetch over
      // a new SSH connection raced this and clobbered the correct count
      // with stale data — that's gone now. We still refetch history in
      // the background so the log tail picks up the new prune lines.
      // Scroll position is preserved — these are data-only updates.
      setDumpPods({ ok: true, pods: r.remaining ?? [], count: (r.remaining ?? []).length })
      void getBackupHistory({ recent: 5, logLines: 50 }).then(setHistory).catch(() => {})
    } catch (e) {
      showToast('err', `Prune failed: ${e instanceof Error ? e.message : String(e)}`)
    } finally {
      setPruning(false)
    }
  }

  // Dump-pod retention inputs differ from what's saved on the VM. Mirrors
  // the schedule-wide `dirty` memo but scoped to just this row so we can
  // show a focused "Save" affordance right next to the inputs the user is
  // actually editing.
  const dumpPodsDirty = useMemo(() => {
    if (!schedule) return false
    return (
      draftKeepDumpPods !== (schedule.keepLastPods ?? 10) ||
      draftKeepDumpDays !== (schedule.keepDaysPods ?? 0)
    )
  }, [schedule, draftKeepDumpPods, draftKeepDumpDays])

  // Pods eligible for prune: name-rank > keepLast (when keepLast>0) OR age > keepDays (when keepDays>0).
  // Pod age is read from the YYYYMMDD-HHMMSS embedded in the pod name (more
  // reliable than k8s status.startTime, which can clear on terminal pods).
  const dumpPodPruneCandidateCount = useMemo(() => {
    if (!dumpPods || !dumpPods.pods?.length) return 0
    if (draftKeepDumpPods === 0 && draftKeepDumpDays === 0) return 0
    const ageCutoffMs = draftKeepDumpDays > 0 ? Date.now() - draftKeepDumpDays * 86400 * 1000 : null
    let count = 0
    dumpPods.pods.forEach((p, idx) => {
      const exceededCount = draftKeepDumpPods > 0 && idx >= draftKeepDumpPods
      let exceededAge = false
      if (ageCutoffMs !== null) {
        const m = p.name.match(/-dump-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-pod$/)
        if (m) {
          const ts = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6])
          if (ts < ageCutoffMs) exceededAge = true
        }
      }
      if (exceededCount || exceededAge) count++
    })
    return count
  }, [dumpPods, draftKeepDumpPods, draftKeepDumpDays])

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

      {schedule?.inferredFromUnmanaged && (
        <p className="text-xs text-info mb-3 flex items-start gap-1.5">
          <Icon name="Info" size={12} className="mt-0.5 shrink-0" />
          <span>
            Found a hand-installed <span className="font-mono">battlegroup backup</span> cron on the VM that
            matches the <strong>{schedule.preset}</strong> preset. Click <strong>Save schedule</strong> to take
            it over into a managed block (the old line will be replaced cleanly — no duplicate runs).
          </span>
        </p>
      )}

      {schedule?.hasUnmanagedBackupLines && !schedule.inferredFromUnmanaged && (
        <p className="text-xs text-warning mb-3 flex items-start gap-1.5">
          <Icon name="AlertTriangle" size={12} className="mt-0.5 shrink-0" />
          <span>
            The crontab also contains one or more <span className="font-mono">battlegroup backup</span> lines
            outside the managed block. Saving here will <strong>remove</strong> them and replace with the preset
            above (so you never end up with two schedules running at once).
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
            Keep last (count){draftKeepLast === 0 ? ' — keep forever' : ''}
          </span>
          <input
            type="number"
            min={0}
            max={1000}
            step={1}
            value={draftKeepLast}
            onChange={e => {
              const n = parseInt(e.target.value || '0', 10)
              setDraftKeepLast(Number.isFinite(n) ? Math.max(0, Math.min(1000, n)) : 0)
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
                {schedule.keepLast > 0
                  ? <> · keep last <strong className="text-text">{schedule.keepLast}</strong> backups</>
                  : <> · keep forever</>}
              </>
            : <strong className="text-text">Off</strong>}
          {' · '}VM time <span className="font-mono">{schedule.vmNowUtc} ({tzLabel})</span>
        </p>
      )}

      <div className="border-t border-border pt-3 mt-1">
        <div className="flex items-center justify-between gap-3 mb-2">
          <div className="text-xs font-semibold text-text-muted">Recent backups</div>
          <div className="flex items-center gap-3">
            <button
              type="button"
              onClick={() => void handleUpload()}
              disabled={!vmRunning || !!transferring}
              className="btn-secondary text-xs py-1 px-2"
              title="Upload a .backup file from your PC to the VM's dump directory"
            >
              <Icon name={transferring === 'upload' ? 'Loader2' : 'Upload'} size={12} className={transferring === 'upload' ? 'animate-spin' : ''} />
              {transferring === 'upload' ? 'Uploading…' : 'Import backup'}
            </button>
            <span className="text-xs text-text-dim">
              {history?.dumpDirSize ? <>Dump dir: <span className="font-mono">{history.dumpDirSize}</span></> : null}
            </span>
          </div>
        </div>
        {!history || history.recent.length === 0 ? (
          <p className="text-xs text-text-dim italic">
            {vmRunning ? 'No backup files found yet.' : 'VM not running.'}
          </p>
        ) : (
          <ul className="text-xs font-mono space-y-1">
            {history.recent.map(f => (
              <li key={f.path} className="flex items-center gap-2">
                <button
                  type="button"
                  onClick={() => void handleDownload(f.path)}
                  disabled={!!transferring}
                  className="text-info hover:text-info-bright disabled:opacity-40 shrink-0"
                  title="Download to your PC"
                >
                  <Icon name={transferring === f.path ? 'Loader2' : 'Download'} size={12} className={transferring === f.path ? 'animate-spin' : ''} />
                </button>
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

      {/* Completed backup pods — Funcom's database-backup job leaves a
          `*-dump-YYYYMMDD-HHMMSS-pod` behind on every run. They terminate
          Succeeded and are never garbage-collected, so they pile up on the
          Pods page and in the VM's shell-pod picker. Retention is persisted
          as part of the schedule (Save schedule above writes both); the
          cron tick honors keepLast, the manual button honors both. The
          .backup files on the PVC are handled by Keep last (count) above
          (separate retention). */}
      <div className="border-t border-border pt-3 mt-3">
        <div className="flex items-center justify-between gap-3 mb-2">
          <div className="text-xs font-semibold text-text-muted">Completed backup pods</div>
          <div className="text-xs text-text-dim">
            {dumpPods
              ? <>Found <strong className="text-text">{dumpPods.count}</strong> Succeeded dump pod{dumpPods.count === 1 ? '' : 's'} on the cluster.</>
              : <span className="italic">{vmRunning ? 'Loading…' : 'VM not running.'}</span>}
          </div>
        </div>
        <p className="text-xs text-text-dim mb-2">
          Funcom's <span className="font-mono">battlegroup backup</span> job creates a one-shot pod per run that finishes
          Succeeded and is never cleaned up. The scheduled cleanup runs after every backup tick using <strong>Keep last (count)</strong> below;
          the manual button honors both thresholds. Only terminal <span className="font-mono">*-dump-*-pod</span> objects are touched —
          live DB, util/mon/pghero, file-browser, and the <span className="font-mono">.backup</span> files are never affected.
        </p>
        <div className="flex flex-wrap items-end gap-3">
          <label className="flex flex-col gap-1 text-xs">
            <span className="text-text-muted font-medium">
              Keep last (count){draftKeepDumpPods === 0 ? ' — no cap' : ''}
            </span>
            <input
              type="number"
              min={0}
              max={100}
              step={1}
              value={draftKeepDumpPods}
              onChange={e => {
                const n = parseInt(e.target.value || '0', 10)
                setDraftKeepDumpPods(Number.isFinite(n) ? Math.max(0, Math.min(100, n)) : 0)
              }}
              disabled={!vmRunning || pruning || saving}
              className="px-2 py-1.5 rounded bg-surface-2 border border-border text-text text-sm font-mono w-24"
            />
          </label>
          <label className="flex flex-col gap-1 text-xs">
            <span className="text-text-muted font-medium">
              Keep last (days){draftKeepDumpDays === 0 ? ' — no age cap' : ''}
            </span>
            <input
              type="number"
              min={0}
              max={365}
              step={1}
              value={draftKeepDumpDays}
              onChange={e => {
                const n = parseInt(e.target.value || '0', 10)
                setDraftKeepDumpDays(Number.isFinite(n) ? Math.max(0, Math.min(365, n)) : 0)
              }}
              disabled={!vmRunning || pruning || saving}
              className="px-2 py-1.5 rounded bg-surface-2 border border-border text-text text-sm font-mono w-24"
            />
          </label>
          <button
            type="button"
            onClick={() => void save()}
            disabled={!vmRunning || saving || pruning || !dumpPodsDirty}
            className="btn-primary"
            title={dumpPodsDirty
              ? 'Persist these retention values into the schedule so they survive reload and drive the auto-prune.'
              : 'No unsaved changes.'}
          >
            <Icon name={saving ? 'Loader2' : 'Save'} size={14} className={saving ? 'animate-spin' : ''} />
            {saving ? 'Saving…' : 'Save retention'}
          </button>
          <button
            type="button"
            onClick={() => void handlePruneDumpPods()}
            disabled={!vmRunning || pruning || saving || dumpPodPruneCandidateCount === 0}
            className="btn-secondary"
            title={dumpPodPruneCandidateCount > 0
              ? `Delete ${dumpPodPruneCandidateCount} pod(s) now; keep ${(dumpPods?.count ?? 0) - dumpPodPruneCandidateCount}.`
              : 'Nothing to prune at these thresholds.'}
          >
            <Icon name={pruning ? 'Loader2' : 'Trash2'} size={14} className={pruning ? 'animate-spin' : ''} />
            {pruning ? 'Pruning…' : `Prune now${dumpPodPruneCandidateCount > 0 ? ` (${dumpPodPruneCandidateCount})` : ''}`}
          </button>
        </div>
        <p className="text-xs text-text-dim mt-2 italic">
          A pod is kept only if it's both within the count cap and younger than the age cap. Set either to <span className="font-mono">0</span> to disable that axis. <strong>Save retention</strong> persists the values; <strong>Prune now</strong> applies them this instant.
          {dumpPodsDirty && <span className="text-warning ml-1">• Unsaved changes.</span>}
        </p>

        {/* Enumerated pod list — shows what the server actually saw, with the
            timestamp parsed from each pod's name and an age in days. This is
            the diagnostic surface for "why didn't this pod get pruned?":
            either it's within keepLast (still in the kept set), or its name
            didn't match the regex (won't appear at all). */}
        {dumpPods && dumpPods.count > 0 && (
          <details className="mt-3">
            <summary className="text-xs text-info hover:underline cursor-pointer">
              Show enumerated pods ({dumpPods.count})
            </summary>
            <div className="mt-2 max-h-64 overflow-y-auto border border-border rounded bg-surface-2/50">
              <table className="w-full text-xs font-mono">
                <thead className="text-text-muted sticky top-0 bg-surface-2">
                  <tr>
                    <th className="text-left px-2 py-1 font-medium">#</th>
                    <th className="text-left px-2 py-1 font-medium">Namespace</th>
                    <th className="text-left px-2 py-1 font-medium">Name</th>
                    <th className="text-left px-2 py-1 font-medium">Age</th>
                    <th className="text-left px-2 py-1 font-medium">Disposition</th>
                  </tr>
                </thead>
                <tbody>
                  {dumpPods.pods.map((p, idx) => {
                    const exceededCount = draftKeepDumpPods > 0 && idx >= draftKeepDumpPods
                    const ageDays = p.ageMinutes != null ? Math.floor(p.ageMinutes / (60 * 24)) : null
                    const exceededAge = draftKeepDumpDays > 0 && ageDays != null && ageDays > draftKeepDumpDays
                    const wouldDelete = exceededCount || exceededAge
                    return (
                      <tr key={`${p.namespace}/${p.name}`} className={wouldDelete ? 'text-danger' : 'text-text'}>
                        <td className="px-2 py-1">{idx + 1}</td>
                        <td className="px-2 py-1 truncate max-w-[10rem]" title={p.namespace}>{p.namespace}</td>
                        <td className="px-2 py-1 truncate" title={p.name}>{p.name}</td>
                        <td className="px-2 py-1 whitespace-nowrap">
                          {ageDays != null ? `${ageDays}d` : '—'}
                        </td>
                        <td className="px-2 py-1 whitespace-nowrap">
                          {wouldDelete
                            ? <span className="text-danger">prune {exceededCount ? '(count)' : ''}{exceededCount && exceededAge ? ' + ' : ''}{exceededAge ? '(age)' : ''}</span>
                            : <span className="text-text-muted">keep</span>}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          </details>
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
