import { useEffect, useRef, useState, useCallback } from 'react'
import { Terminal as XTerm } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import '@xterm/xterm/css/xterm.css'

import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { connectTerminal, type TerminalClient, type TermStream } from '../api/terminal'

// ----------------------------------------------------------------------------
// Terminal page — embedded PowerShell session.
//
// The server backend (app/server/routes/Terminal.ps1) is an *exec* model,
// not a true PTY. So this page implements client-side line editing: typing
// builds up a local `currentLine`; Enter ships the line to the server as
// `{type:'exec'}`; output frames are streamed back and written to xterm.
// While a command is running, input is locked except Ctrl+C (cancel).
//
// Streams are color-coded:
//   stdout  - text-default
//   stderr  - bright red
//   info    - cyan (Write-Host / Write-Information)
//   warn    - yellow
//   verbose - dim cyan
// ----------------------------------------------------------------------------

const PROMPT = (cwd: string) => `\x1b[38;5;208mPS\x1b[0m \x1b[38;5;110m${cwd}\x1b[0m\x1b[38;5;208m>\x1b[0m `

const STREAM_PREFIX: Record<TermStream, string> = {
  stdout:  '',
  stderr:  '\x1b[91m',                 // bright red
  info:    '\x1b[36m',                 // cyan
  warn:    '\x1b[33m',                 // yellow
  verbose: '\x1b[2;36m',               // dim cyan
}
const STREAM_RESET = '\x1b[0m'

function writeStream(term: XTerm, stream: TermStream, data: string) {
  const prefix = STREAM_PREFIX[stream]
  // Normalize line endings — server sends mixed \n / \r\n depending on stream.
  const text = data.replace(/\r?\n/g, '\r\n')
  if (prefix) {
    // Wrap each line so multi-line stderr stays colored across breaks.
    term.write(prefix + text.replace(/\r\n/g, STREAM_RESET + '\r\n' + prefix) + STREAM_RESET)
  } else {
    term.write(text)
  }
}

export function TerminalPage() {
  const hostRef = useRef<HTMLDivElement | null>(null)
  const termRef = useRef<XTerm | null>(null)
  const fitRef = useRef<FitAddon | null>(null)
  const clientRef = useRef<TerminalClient | null>(null)

  // Mutable per-keystroke state — refs avoid re-renders & stale closures.
  const cwdRef       = useRef<string>('')
  const lineRef      = useRef<string>('')
  const cursorRef    = useRef<number>(0)        // position within lineRef
  const busyRef      = useRef<boolean>(false)
  const historyRef   = useRef<string[]>([])
  const historyIdxRef = useRef<number>(-1)      // -1 = editing fresh line
  const pendingLineRef = useRef<string>('')     // saved when scrolling up

  const [status, setStatus] = useState<'connecting' | 'open' | 'closed' | 'error'>('connecting')
  const [statusMsg, setStatusMsg] = useState<string>('')
  const [busy, setBusy] = useState<boolean>(false)
  const [cwd, setCwd] = useState<string>('')

  // ---- helpers ------------------------------------------------------------

  const writePrompt = useCallback(() => {
    const t = termRef.current; if (!t) return
    t.write(PROMPT(cwdRef.current))
  }, [])

  const redrawLine = useCallback(() => {
    const t = termRef.current; if (!t) return
    // Move cursor to start-of-line, clear, redraw prompt + line, then put cursor.
    t.write('\r\x1b[2K')
    t.write(PROMPT(cwdRef.current) + lineRef.current)
    const tail = lineRef.current.length - cursorRef.current
    if (tail > 0) t.write(`\x1b[${tail}D`)
  }, [])

  const setLine = useCallback((next: string) => {
    lineRef.current = next
    cursorRef.current = next.length
    redrawLine()
  }, [redrawLine])

  // ---- key handling -------------------------------------------------------

  const handleData = useCallback((data: string) => {
    const t = termRef.current; const c = clientRef.current
    if (!t || !c) return

    // Ctrl+C — always allowed.
    if (data === '\x03') {
      if (busyRef.current) {
        t.write('^C')
        c.cancel()
      } else {
        t.write('^C\r\n')
        lineRef.current = ''
        cursorRef.current = 0
        historyIdxRef.current = -1
        pendingLineRef.current = ''
        writePrompt()
      }
      return
    }

    // Ignore input while command is running.
    if (busyRef.current) return

    // Multi-character sequences (paste / arrow keys).
    if (data.length > 1) {
      if (data === '\x1b[A') { /* up */
        if (historyRef.current.length === 0) return
        if (historyIdxRef.current === -1) {
          pendingLineRef.current = lineRef.current
          historyIdxRef.current = historyRef.current.length - 1
        } else if (historyIdxRef.current > 0) {
          historyIdxRef.current -= 1
        }
        setLine(historyRef.current[historyIdxRef.current] ?? '')
        return
      }
      if (data === '\x1b[B') { /* down */
        if (historyIdxRef.current === -1) return
        historyIdxRef.current += 1
        if (historyIdxRef.current >= historyRef.current.length) {
          historyIdxRef.current = -1
          setLine(pendingLineRef.current)
          pendingLineRef.current = ''
        } else {
          setLine(historyRef.current[historyIdxRef.current] ?? '')
        }
        return
      }
      if (data === '\x1b[D') { /* left */
        if (cursorRef.current > 0) {
          cursorRef.current -= 1
          t.write('\x1b[D')
        }
        return
      }
      if (data === '\x1b[C') { /* right */
        if (cursorRef.current < lineRef.current.length) {
          cursorRef.current += 1
          t.write('\x1b[C')
        }
        return
      }
      if (data === '\x1b[H' || data === '\x01') { /* Home / Ctrl+A */
        const dist = cursorRef.current
        if (dist > 0) { cursorRef.current = 0; t.write(`\x1b[${dist}D`) }
        return
      }
      if (data === '\x1b[F' || data === '\x05') { /* End / Ctrl+E */
        const dist = lineRef.current.length - cursorRef.current
        if (dist > 0) { cursorRef.current = lineRef.current.length; t.write(`\x1b[${dist}C`) }
        return
      }
      // Treat as paste — strip any control chars and insert.
      const clean = data.replace(/[\x00-\x08\x0b-\x1f\x7f]/g, '')
      if (clean) {
        const before = lineRef.current.slice(0, cursorRef.current)
        const after  = lineRef.current.slice(cursorRef.current)
        lineRef.current = before + clean + after
        cursorRef.current += clean.length
        redrawLine()
      }
      return
    }

    const ch = data
    const code = ch.charCodeAt(0)

    // Enter
    if (ch === '\r' || ch === '\n') {
      const line = lineRef.current
      t.write('\r\n')
      lineRef.current = ''
      cursorRef.current = 0
      historyIdxRef.current = -1
      pendingLineRef.current = ''

      const trimmed = line.trim()
      if (trimmed.length === 0) {
        writePrompt()
        return
      }
      // History dedupe (don't store consecutive dupes).
      const hist = historyRef.current
      if (hist[hist.length - 1] !== line) hist.push(line)
      while (hist.length > 500) hist.shift()

      busyRef.current = true
      setBusy(true)
      c.exec(line)
      return
    }

    // Backspace (DEL=127, BS=8)
    if (code === 127 || code === 8) {
      if (cursorRef.current > 0) {
        const before = lineRef.current.slice(0, cursorRef.current - 1)
        const after  = lineRef.current.slice(cursorRef.current)
        lineRef.current = before + after
        cursorRef.current -= 1
        redrawLine()
      }
      return
    }

    // Delete-forward (Esc[3~ comes as multi-char; Ctrl+D)
    if (code === 4) {
      if (cursorRef.current < lineRef.current.length) {
        const before = lineRef.current.slice(0, cursorRef.current)
        const after  = lineRef.current.slice(cursorRef.current + 1)
        lineRef.current = before + after
        redrawLine()
      }
      return
    }

    // Ctrl+L — clear screen + redraw prompt + current line.
    if (code === 12) {
      t.write('\x1b[2J\x1b[H')
      writePrompt()
      t.write(lineRef.current)
      const tail = lineRef.current.length - cursorRef.current
      if (tail > 0) t.write(`\x1b[${tail}D`)
      return
    }

    // Tab — ignored (no completion in exec model)
    if (ch === '\t') return

    // Other control chars — ignore
    if (code < 32) return

    // Printable
    const before = lineRef.current.slice(0, cursorRef.current)
    const after  = lineRef.current.slice(cursorRef.current)
    if (after.length === 0) {
      lineRef.current = before + ch
      cursorRef.current += 1
      t.write(ch)
    } else {
      lineRef.current = before + ch + after
      cursorRef.current += 1
      redrawLine()
    }
  }, [redrawLine, setLine, writePrompt])

  // ---- mount: create xterm + WS ------------------------------------------

  useEffect(() => {
    if (!hostRef.current) return
    const term = new XTerm({
      cursorBlink: true,
      fontFamily: '"JetBrains Mono", "Cascadia Code", "Consolas", monospace',
      fontSize: 13,
      lineHeight: 1.2,
      theme: {
        background: '#0c0a09',
        foreground: '#f5ebe0',
        cursor:     '#d97706',
        selectionBackground: '#d9770655',
        black: '#0c0a09', red: '#f87171', green: '#4ade80',
        yellow: '#fbbf24', blue: '#38bdf8', magenta: '#c084fc',
        cyan: '#22d3ee', white: '#f5ebe0',
        brightBlack: '#7a6a5a', brightRed: '#ef4444',
        brightGreen: '#86efac', brightYellow: '#fde047',
        brightBlue: '#7dd3fc', brightMagenta: '#e9d5ff',
        brightCyan: '#67e8f9', brightWhite: '#ffffff',
      },
      scrollback: 5000,
      convertEol: false,
    })
    const fit = new FitAddon()
    term.loadAddon(fit)
    term.open(hostRef.current)
    termRef.current = term
    fitRef.current = fit
    try { fit.fit() } catch { /* dom not ready */ }

    term.onData(handleData)

    // Connect WS once xterm dimensions are known.
    const cols = term.cols || 100
    const client = connectTerminal({
      onReady: (m) => {
        cwdRef.current = m.cwd
        setCwd(m.cwd)
        setStatus('open')
        setStatusMsg('')
        term.write('\x1b[38;5;110mDune Server Tool — embedded PowerShell\x1b[0m\r\n')
        term.write('\x1b[38;5;245m(exec model: vim/htop not supported; kubectl/ssh-with-cmd works)\x1b[0m\r\n\r\n')
        writePrompt()
      },
      onOutput: (m) => writeStream(term, m.stream, m.data),
      onDone: (m) => {
        cwdRef.current = m.cwd
        setCwd(m.cwd)
        busyRef.current = false
        setBusy(false)
        // Cosmetic: newline if last char wasn't, then prompt.
        term.write('\r\n')
        writePrompt()
        if (m.hadErrors) {
          // Subtle indicator: nothing — colors already showed the error.
        }
      },
      onError: (m) => {
        term.write(`\r\n\x1b[91m[server error] ${m.message}\x1b[0m\r\n`)
        busyRef.current = false
        setBusy(false)
        writePrompt()
      },
      onClose: () => {
        setStatus('closed')
        setStatusMsg('Connection closed')
        term.write('\r\n\x1b[91m[connection closed]\x1b[0m\r\n')
      },
      onSocketError: () => {
        setStatus('error')
        setStatusMsg('WebSocket error')
      },
    }, cols)
    clientRef.current = client

    // Resize observer.
    const ro = new ResizeObserver(() => {
      try {
        fit.fit()
        const c = term.cols
        if (c && clientRef.current) clientRef.current.resize(c)
      } catch { /* ignore */ }
    })
    ro.observe(hostRef.current)

    return () => {
      ro.disconnect()
      try { client.close() } catch { /* ignore */ }
      try { term.dispose() } catch { /* ignore */ }
      termRef.current = null
      fitRef.current = null
      clientRef.current = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const onCancelClick = () => {
    const c = clientRef.current
    if (!c) return
    if (busyRef.current) c.cancel()
  }

  const onClearClick = () => {
    const t = termRef.current
    if (!t) return
    t.write('\x1b[2J\x1b[H')
    if (!busyRef.current) writePrompt()
  }

  const onReconnectClick = () => {
    try { clientRef.current?.close() } catch { /* ignore */ }
    // Effect cleanup will run + re-run via remount; simplest = full reload.
    window.location.reload()
  }

  const statusPill = (() => {
    if (status === 'open' && busy)  return <span className="pill-warning"><Icon name="Loader2" size={12} /> Running</span>
    if (status === 'open')           return <span className="pill-success"><Icon name="CheckCircle2" size={12} /> Ready</span>
    if (status === 'connecting')     return <span className="pill-info"><Icon name="Plug" size={12} /> Connecting…</span>
    if (status === 'closed')         return <span className="pill-muted"><Icon name="PlugZap" size={12} /> Closed</span>
    return <span className="pill-danger"><Icon name="AlertCircle" size={12} /> Error</span>
  })()

  return (
    <>
      <PageHeader
        title="Terminal"
        icon="SquareTerminal"
        description="Embedded PowerShell session — runs locally on this machine. Use it for kubectl, ssh dune@vm '…', and other one-shot commands."
      />

      <div className="flex items-center justify-between mb-3 gap-3">
        <div className="flex items-center gap-3 min-w-0">
          {statusPill}
          {cwd && (
            <span className="text-text-muted text-xs font-mono truncate" title={cwd}>{cwd}</span>
          )}
          {statusMsg && (
            <span className="text-danger text-xs">{statusMsg}</span>
          )}
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            className="btn-secondary"
            onClick={onCancelClick}
            disabled={!busy}
            title="Send Ctrl+C to running command"
          >
            <Icon name="OctagonX" size={14} /> Cancel
          </button>
          <button
            type="button"
            className="btn-secondary"
            onClick={onClearClick}
            title="Clear screen (Ctrl+L)"
          >
            <Icon name="Eraser" size={14} /> Clear
          </button>
          <button
            type="button"
            className="btn-secondary"
            onClick={onReconnectClick}
            title="Drop session, open a new one"
          >
            <Icon name="RotateCw" size={14} /> Reconnect
          </button>
        </div>
      </div>

      <div className="card p-3" style={{ height: 'calc(100vh - 220px)', minHeight: 360 }}>
        <div ref={hostRef} className="h-full w-full" />
      </div>

      <div className="mt-3 text-xs text-text-dim">
        <span className="font-mono">Enter</span> run · <span className="font-mono">Ctrl+C</span> cancel · <span className="font-mono">↑/↓</span> history · <span className="font-mono">Ctrl+L</span> clear · <span className="font-mono">Home/End</span> line edge.
        Each session runs in an isolated PowerShell runspace; cwd and variables persist between commands.
      </div>
    </>
  )
}
