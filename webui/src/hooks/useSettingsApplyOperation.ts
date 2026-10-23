import { useSyncExternalStore } from 'react'

type ApplyStage = 'checking' | 'stopping' | 'saving' | 'starting'
type ApplyState = { running: boolean; message: string | null; error: string | null; stage: ApplyStage; stageStartedAt: number }
type Update = (state: Partial<Pick<ApplyState, 'message' | 'error' | 'stage'>>) => void
let state: ApplyState = { running: false, message: null, error: null, stage: 'checking', stageStartedAt: 0 }
const listeners = new Set<() => void>()
const subscribe = (listener: () => void) => { listeners.add(listener); return () => { listeners.delete(listener) } }
const snapshot = () => state
const publish = (next: Partial<ApplyState>) => {
  state = { ...state, ...next }
  for (const listener of listeners) listener()
}
const warnBeforeClosing = (event: BeforeUnloadEvent) => {
  event.preventDefault()
  event.returnValue = ''
}

// The accepted sequence belongs to this viewer, not a mounted route. Navigation
// may dispose the forms; their approved snapshots continue through this owner.
export async function runSettingsApply(task: (update: Update) => Promise<void>) {
  if (state.running) return
  publish({ running: true, message: 'Checking the reviewed settings…', error: null, stage: 'checking', stageStartedAt: Date.now() })
  window.addEventListener('beforeunload', warnBeforeClosing)
  try { await task(next => publish({ ...next, ...(next.stage && next.stage !== state.stage ? { stageStartedAt: Date.now() } : {}) })) }
  catch (error) { publish({ message: null, error: error instanceof Error ? error.message : String(error) }) }
  finally {
    window.removeEventListener('beforeunload', warnBeforeClosing)
    publish({ running: false })
  }
}

export function clearSettingsApplyResult() {
  if (!state.running) publish({ message: null, error: null })
}

export function useSettingsApplyOperation() {
  return useSyncExternalStore(subscribe, snapshot, snapshot)
}
