// Theme token definitions.
//
// Every CSS custom property the theming engine knows about. Adding a new
// token here is enough to make it appear in the AppearanceCard picker and be
// included in resolved-map snapshots / import-export validation.
//
// IMPORTANT: every key listed here must also exist as a `--color-*` declaration
// in `webui/src/index.css` (either inside `@theme {}` for Tailwind utilities or
// as a plain `:root {}` declaration). Otherwise the runtime override won't have
// a default to fall back to.

export type TokenCategory = 'surface' | 'text' | 'accent' | 'ibad' | 'status'

export interface TokenDef {
  key: string          // e.g. '--color-base'
  label: string        // human label for the picker
  category: TokenCategory
  hint?: string        // optional one-liner shown in the UI
}

// Order here drives display order in the picker.
export const TOKENS: TokenDef[] = [
  // --- Surfaces (page + cards + borders) -----------------------------------
  { key: '--color-base',          label: 'Page background',  category: 'surface', hint: 'Deepest backdrop behind everything.' },
  { key: '--color-surface',       label: 'Card surface',     category: 'surface' },
  { key: '--color-surface-2',     label: 'Card surface 2',   category: 'surface', hint: 'Hover / nested card.' },
  { key: '--color-surface-3',     label: 'Card surface 3',   category: 'surface', hint: 'Deepest nested surface.' },
  { key: '--color-border',        label: 'Border',           category: 'surface' },
  { key: '--color-border-bright', label: 'Border (bright)',  category: 'surface', hint: 'Hover / focus borders.' },

  // --- Text ----------------------------------------------------------------
  { key: '--color-text',          label: 'Text',             category: 'text' },
  { key: '--color-text-muted',    label: 'Text (muted)',     category: 'text' },
  { key: '--color-text-dim',      label: 'Text (dim)',       category: 'text', hint: 'Captions, helper text.' },

  // --- Accent (primary action color) ---------------------------------------
  { key: '--color-accent',        label: 'Accent',           category: 'accent', hint: 'Primary buttons, focus glow.' },
  { key: '--color-accent-bright', label: 'Accent (bright)',  category: 'accent', hint: 'Hover state.' },
  { key: '--color-accent-dim',    label: 'Accent (dim)',     category: 'accent' },
  { key: '--color-accent-fg',     label: 'Accent foreground', category: 'accent', hint: 'Text color on accent buttons. Pick something that contrasts the accent.' },

  // --- Ibad (secondary highlight / focus ring) -----------------------------
  { key: '--color-ibad',          label: 'Highlight',        category: 'ibad', hint: 'Focus rings, info accents.' },
  { key: '--color-ibad-bright',   label: 'Highlight (bright)', category: 'ibad' },

  // --- Status --------------------------------------------------------------
  { key: '--color-success',       label: 'Success',          category: 'status' },
  { key: '--color-danger',        label: 'Danger',           category: 'status' },
  { key: '--color-warning',       label: 'Warning',          category: 'status' },
  { key: '--color-info',          label: 'Info',             category: 'status' },
]

export const TOKEN_KEYS = TOKENS.map(t => t.key)
export const TOKEN_KEY_SET = new Set(TOKEN_KEYS)

export const CATEGORY_LABELS: Record<TokenCategory, string> = {
  surface: 'Surfaces & borders',
  text:    'Text',
  accent:  'Accent',
  ibad:    'Highlight (Eyes of Ibad)',
  status:  'Status colors',
}

export const CATEGORY_ORDER: TokenCategory[] = ['surface', 'text', 'accent', 'ibad', 'status']

// Validates a hex color string. Accepts `#rgb`, `#rrggbb`, and `#rrggbbaa`.
// Native <input type="color"> only emits `#rrggbb` so import is the only path
// that could feed in the other shapes — we accept them and normalize on write.
const HEX_RE = /^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i

export function isValidHex(v: unknown): v is string {
  return typeof v === 'string' && HEX_RE.test(v)
}

// Normalizes `#abc` → `#aabbcc` so <input type="color"> can display it.
// Leaves longer forms untouched.
export function normalizeHex(v: string): string {
  if (/^#[0-9a-f]{3}$/i.test(v)) {
    return '#' + v.slice(1).split('').map(c => c + c).join('').toLowerCase()
  }
  return v.toLowerCase()
}
