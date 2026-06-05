// Theme context, hook, and the boot-time loader that the inline script in
// index.html relies on.
//
// Why CSS variables on :root instead of a class-switch approach:
// Tailwind v4 compiles `@theme { --color-x: ... }` into `:root { --color-x: ... }`
// and every utility like `bg-accent`, `border-border/30`, `text-text-muted`
// resolves to those CSS vars. Setting a new value on :root cascades to every
// element in the tree without any class-toggle or rebuild.

import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { TOKEN_KEYS, TOKEN_KEY_SET, isValidHex, normalizeHex } from './tokens'
import { DEFAULT_PRESET_ID, PRESETS, getPreset } from './presets'

export const THEME_STORAGE_KEY = 'dst-theme'
export const THEME_SCHEMA_VERSION = 1

// What we persist to localStorage. `resolved` is denormalised so the inline
// boot script in index.html can apply colors without importing the presets
// module.
export interface StoredTheme {
  version: number
  presetId: string
  overrides: Record<string, string>
  resolved: Record<string, string>
}

// Shape exposed to React consumers.
export interface ThemeContextValue {
  presetId: string
  overrides: Record<string, string>
  resolved: Record<string, string>
  setPreset: (id: string) => void
  setOverride: (key: string, value: string) => void
  resetOverride: (key: string) => void
  resetAllOverrides: () => void
  resetToDefault: () => void
  exportJson: () => string
  importJson: (raw: string) => ImportResult
  /** Bumps every time the resolved map changes — useful for re-rendering
   * components that read CSS vars imperatively (xterm). */
  revision: number
}

export interface ImportResult {
  ok: boolean
  message: string
  appliedCount?: number
  ignoredKeys?: string[]
}

// ---------------------------------------------------------------------------
// Pure helpers (also used by the inline boot script via a separate file)
// ---------------------------------------------------------------------------

export function computeResolved(presetId: string, overrides: Record<string, string>): Record<string, string> {
  const preset = getPreset(presetId) ?? getPreset(DEFAULT_PRESET_ID)!
  return { ...preset.tokens, ...overrides }
}

export function applyResolvedToRoot(resolved: Record<string, string>): void {
  const root = document.documentElement
  for (const key of TOKEN_KEYS) {
    const v = resolved[key]
    if (v) root.style.setProperty(key, v)
  }
}

function readStored(): StoredTheme | null {
  try {
    const raw = localStorage.getItem(THEME_STORAGE_KEY)
    if (!raw) return null
    const parsed = JSON.parse(raw) as Partial<StoredTheme>
    if (!parsed || typeof parsed !== 'object') return null
    const presetId = typeof parsed.presetId === 'string' && getPreset(parsed.presetId)
      ? parsed.presetId
      : DEFAULT_PRESET_ID
    const overrides: Record<string, string> = {}
    if (parsed.overrides && typeof parsed.overrides === 'object') {
      for (const [k, v] of Object.entries(parsed.overrides)) {
        if (TOKEN_KEY_SET.has(k) && isValidHex(v)) overrides[k] = normalizeHex(v as string)
      }
    }
    const resolved = computeResolved(presetId, overrides)
    return { version: THEME_SCHEMA_VERSION, presetId, overrides, resolved }
  } catch {
    return null
  }
}

function writeStored(value: StoredTheme): void {
  try {
    localStorage.setItem(THEME_STORAGE_KEY, JSON.stringify(value))
  } catch {
    /* localStorage full / disabled — silently no-op. The user can still use
     * the picker; preference just won't survive a refresh. */
  }
}

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

const ThemeContext = createContext<ThemeContextValue | null>(null)

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [presetId, setPresetIdState] = useState<string>(() => readStored()?.presetId ?? DEFAULT_PRESET_ID)
  const [overrides, setOverridesState] = useState<Record<string, string>>(() => readStored()?.overrides ?? {})
  const [revision, setRevision] = useState(0)

  const resolved = useMemo(() => computeResolved(presetId, overrides), [presetId, overrides])

  // Apply on every change. The inline boot script in index.html has already
  // applied the initial values pre-paint; this keeps the DOM in sync after.
  useEffect(() => {
    applyResolvedToRoot(resolved)
    writeStored({ version: THEME_SCHEMA_VERSION, presetId, overrides, resolved })
    setRevision(r => r + 1)
    // resolved is derived from presetId + overrides; including it covers both.
  }, [resolved, presetId, overrides])

  const setPreset = useCallback((id: string) => {
    if (!getPreset(id)) return
    setPresetIdState(id)
  }, [])

  const setOverride = useCallback((key: string, value: string) => {
    if (!TOKEN_KEY_SET.has(key) || !isValidHex(value)) return
    setOverridesState(prev => ({ ...prev, [key]: normalizeHex(value) }))
  }, [])

  const resetOverride = useCallback((key: string) => {
    setOverridesState(prev => {
      if (!(key in prev)) return prev
      const next = { ...prev }
      delete next[key]
      return next
    })
  }, [])

  const resetAllOverrides = useCallback(() => {
    setOverridesState({})
  }, [])

  const resetToDefault = useCallback(() => {
    setPresetIdState(DEFAULT_PRESET_ID)
    setOverridesState({})
  }, [])

  const exportJson = useCallback(() => {
    const payload: StoredTheme = {
      version: THEME_SCHEMA_VERSION,
      presetId,
      overrides,
      resolved,
    }
    return JSON.stringify(payload, null, 2)
  }, [presetId, overrides, resolved])

  const importJson = useCallback((raw: string): ImportResult => {
    let parsed: Partial<StoredTheme>
    try {
      parsed = JSON.parse(raw)
    } catch {
      return { ok: false, message: 'Not valid JSON.' }
    }
    if (!parsed || typeof parsed !== 'object') {
      return { ok: false, message: 'Theme file is empty or malformed.' }
    }
    if (typeof parsed.version === 'number' && parsed.version > THEME_SCHEMA_VERSION) {
      return { ok: false, message: `Theme file is from a newer version (v${parsed.version}). Update DST first.` }
    }

    // Prefer explicit overrides if present; otherwise we accept a `resolved`-
    // only file (lets people share custom themes with no preset reference).
    const nextPresetId = typeof parsed.presetId === 'string' && getPreset(parsed.presetId)
      ? parsed.presetId
      : DEFAULT_PRESET_ID

    const nextOverrides: Record<string, string> = {}
    const ignored: string[] = []

    const considerSource = (src: unknown, treatAsOverride: boolean) => {
      if (!src || typeof src !== 'object') return
      for (const [k, v] of Object.entries(src as Record<string, unknown>)) {
        if (!TOKEN_KEY_SET.has(k)) { ignored.push(k); continue }
        if (!isValidHex(v)) { ignored.push(k); continue }
        if (treatAsOverride) {
          nextOverrides[k] = normalizeHex(v as string)
        } else {
          const preset = getPreset(nextPresetId)!
          if (preset.tokens[k] !== v) nextOverrides[k] = normalizeHex(v as string)
        }
      }
    }

    if (parsed.overrides && Object.keys(parsed.overrides).length > 0) {
      considerSource(parsed.overrides, true)
    } else if (parsed.resolved) {
      considerSource(parsed.resolved, false)
    } else {
      return { ok: false, message: 'Theme file has no overrides or resolved colors.' }
    }

    setPresetIdState(nextPresetId)
    setOverridesState(nextOverrides)

    const applied = Object.keys(nextOverrides).length
    const presetLabel = getPreset(nextPresetId)?.name ?? nextPresetId
    const msg = ignored.length > 0
      ? `Imported "${presetLabel}" with ${applied} custom color${applied === 1 ? '' : 's'}. Ignored ${ignored.length} unknown key${ignored.length === 1 ? '' : 's'}.`
      : `Imported "${presetLabel}" with ${applied} custom color${applied === 1 ? '' : 's'}.`
    return { ok: true, message: msg, appliedCount: applied, ignoredKeys: ignored }
  }, [])

  const value: ThemeContextValue = {
    presetId,
    overrides,
    resolved,
    setPreset,
    setOverride,
    resetOverride,
    resetAllOverrides,
    resetToDefault,
    exportJson,
    importJson,
    revision,
  }

  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>
}

export function useTheme(): ThemeContextValue {
  const ctx = useContext(ThemeContext)
  if (!ctx) throw new Error('useTheme() called outside <ThemeProvider>')
  return ctx
}

// Convenience for component code that doesn't need the full context.
export { PRESETS, getPreset, DEFAULT_PRESET_ID }
