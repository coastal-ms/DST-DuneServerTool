// WebSocket bridge for the Terminal page. Mirrors the protocol implemented
// in app/server/routes/Terminal.ps1 — JSON frames in both directions.
//
// Server is an "exec" model (not a true PTY): each `exec` runs in a
// persistent runspace and finishes with `done`. While a command is
// running, the client may send a single `cancel` to stop it.

import { wsUrl } from './client'

// ---- Outgoing (client -> server) -------------------------------------------
export type TermInit   = { type: 'init';   cols: number }
export type TermExec   = { type: 'exec';   cmd: string }
export type TermCancel = { type: 'cancel' }
export type TermResize = { type: 'resize'; cols: number }
export type TermClientMsg = TermInit | TermExec | TermCancel | TermResize

// ---- Incoming (server -> client) -------------------------------------------
export type TermStream = 'stdout' | 'stderr' | 'info' | 'warn' | 'verbose'

export type TermReady  = { type: 'ready';  cwd: string; cols: number }
export type TermOutput = { type: 'output'; stream: TermStream; data: string }
export type TermDone   = { type: 'done';   cwd: string; durationMs: number; hadErrors: boolean }
export type TermError  = { type: 'error';  message: string }
export type TermServerMsg = TermReady | TermOutput | TermDone | TermError

export interface TerminalHandlers {
  onReady?:  (m: TermReady)  => void
  onOutput?: (m: TermOutput) => void
  onDone?:   (m: TermDone)   => void
  onError?:  (m: TermError)  => void
  onClose?:  (ev: CloseEvent) => void
  onSocketError?: (ev: Event) => void
}

export interface TerminalClient {
  send(msg: TermClientMsg): void
  exec(cmd: string): void
  cancel(): void
  resize(cols: number): void
  close(): void
  readonly socket: WebSocket
}

export function connectTerminal(handlers: TerminalHandlers, cols: number): TerminalClient {
  const ws = new WebSocket(wsUrl('/ws/terminal'))

  ws.addEventListener('open', () => {
    ws.send(JSON.stringify({ type: 'init', cols } satisfies TermInit))
  })

  ws.addEventListener('message', (ev) => {
    let msg: TermServerMsg
    try {
      msg = JSON.parse(typeof ev.data === 'string' ? ev.data : '') as TermServerMsg
    } catch {
      return
    }
    switch (msg.type) {
      case 'ready':  handlers.onReady?.(msg);  break
      case 'output': handlers.onOutput?.(msg); break
      case 'done':   handlers.onDone?.(msg);   break
      case 'error':  handlers.onError?.(msg);  break
    }
  })

  ws.addEventListener('close', (ev) => handlers.onClose?.(ev))
  ws.addEventListener('error', (ev) => handlers.onSocketError?.(ev))

  const send = (msg: TermClientMsg) => {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(msg))
    }
  }

  return {
    socket: ws,
    send,
    exec:   (cmd)  => send({ type: 'exec',   cmd }),
    cancel: ()     => send({ type: 'cancel' }),
    resize: (cols) => send({ type: 'resize', cols }),
    close:  ()     => { try { ws.close() } catch { /* ignore */ } },
  }
}
