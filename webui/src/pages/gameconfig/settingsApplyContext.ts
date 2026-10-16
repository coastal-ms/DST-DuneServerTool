import { createContext, useContext, useEffect, useRef } from 'react'

export type SettingsChange = { label: string; before: string; after: string; target: string }
export type SettingsDraft = {
  changes: SettingsChange[]
  ready: boolean
  apply: () => Promise<void>
  validate?: () => Promise<void>
}
export type SettingsApplyController = {
  register: (id: string, draft: SettingsDraft | null) => void
  review: () => void
  locked: boolean
}

export const SettingsApplyContext = createContext<SettingsApplyController | null>(null)

// Registration follows the form without remounting it when users switch tabs.
// Apply/validate always see the latest draft; summary updates only on a real change.
export function useSettingsDraft(id: string, draft: SettingsDraft) {
  const controller = useContext(SettingsApplyContext)
  const register = controller?.register
  const latest = useRef(draft)
  latest.current = draft
  const signature = JSON.stringify([draft.changes, draft.ready])
  useEffect(() => {
    if (!register) return
    const [changes, ready] = JSON.parse(signature) as [SettingsChange[], boolean]
    register(id, {
      changes, ready,
      apply: () => latest.current.apply(),
      validate: () => latest.current.validate?.() ?? Promise.resolve(),
    })
  }, [id, register, signature])
  useEffect(() => () => register?.(id, null), [id, register])
  return controller
}
