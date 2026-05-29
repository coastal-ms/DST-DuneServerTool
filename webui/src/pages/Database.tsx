import { useState, useEffect, useMemo, useCallback, useRef } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { useStatus } from '../hooks/useStatus'
import { api } from '../api/client'
import { getDbInfo, runSql } from '../api/database'
import type { DbInfo, SqlResult, SqlOkResult, Command, CommandsResponse } from '../api/types'
import Editor, { type OnMount } from '@monaco-editor/react'

type CmdLaunch = { ok: boolean; name: string; pid?: number; mode: string }

const DEFAULT_SQL = `-- Read-only by default. Toggle the switch to allow writes.
SELECT current_database(), current_user, version();`

export function Database() {
  const { status, forceRefresh } = useStatus()
  const vmRunning = status?.vm?.running === true
  const bgState = status?.bg?.state ?? 'unknown'

  // ---------- Backup / Restore (delegates to /api/commands/run) ------------
  const [commands, setCommands] = useState<{ backup: Command | null; restore: Command | null }>({ backup: null, restore: null })
  const [launching, setLaunching] = useState<string | null>(null)
  const [toast, setToast] = useState<{ kind: 'ok' | 'err'; msg: string } | null>(null)

  const showToast = useCallback((kind: 'ok' | 'err', msg: string) => {
    setToast({ kind, msg })
    window.setTimeout(() => setToast(t => (t?.msg === msg ? null : t)), 4000)
  }, [])

  useEffect(() => {
    void (async () => {
      try {
        const cmds = await api<CommandsResponse>('/api/commands')
        setCommands({
          backup:  cmds.commands.find(c => c.name === 'backup')  ?? null,
          restore: cmds.commands.find(c => c.name === 'import') ?? null,
        })
      } catch { /* swallow — buttons stay disabled */ }
    })()
  }, [vmRunning, bgState])

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
          available={commands.backup?.available ?? false}
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
          available={commands.restore?.available ?? false}
          busy={launching === 'import'}
          onClick={() => void runMaint('import')}
        />
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
