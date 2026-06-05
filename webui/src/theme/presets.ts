// Built-in theme presets.
//
// Each preset is a complete mapping of every CSS token key to a hex color.
// Adding a new preset: copy one of these, change the colors, append to
// PRESETS. The picker auto-renders new entries.
//
// Token resolution at runtime is `{ ...preset.tokens, ...userOverrides }`,
// so presets MUST set every key in TOKEN_KEYS or the user will see a
// half-themed UI when switching from a more-complete preset to a less-
// complete one.

import { TOKEN_KEYS } from './tokens'

export interface Preset {
  id: string
  name: string
  description: string
  // Five tiny preview swatches shown on the preset card.
  // Order: page bg, surface, accent, highlight, text.
  preview: [string, string, string, string, string]
  tokens: Record<string, string>
}

// ---------------------------------------------------------------------------
// Eyes of Ibad — the ORIGINAL default. Matches webui/src/index.css verbatim.
// ---------------------------------------------------------------------------
const eyesOfIbad: Preset = {
  id: 'eyes-of-ibad',
  name: 'Eyes of Ibad',
  description: 'The original. Desert amber on warm dark, with cyan glow highlights.',
  preview: ['#0c0a09', '#18120e', '#d97706', '#38bdf8', '#f5ebe0'],
  tokens: {
    '--color-base':          '#0c0a09',
    '--color-surface':       '#18120e',
    '--color-surface-2':     '#221913',
    '--color-surface-3':     '#2d211a',
    '--color-border':        '#3d2e23',
    '--color-border-bright': '#5a4030',

    '--color-text':          '#f5ebe0',
    '--color-text-muted':    '#b8a692',
    '--color-text-dim':      '#7a6a5a',

    '--color-accent':        '#d97706',
    '--color-accent-bright': '#f59e0b',
    '--color-accent-dim':    '#92400e',
    '--color-accent-fg':     '#0c0a09',

    '--color-ibad':          '#38bdf8',
    '--color-ibad-bright':   '#7dd3fc',

    '--color-success':       '#4ade80',
    '--color-danger':        '#f87171',
    '--color-warning':       '#fbbf24',
    '--color-info':          '#38bdf8',
  },
}

// ---------------------------------------------------------------------------
// Sietch Tabr — LIGHT theme. Warm tan / aged-parchment tones, dimmer than a
// typical bright-white light theme so it doesn't burn the eyes after a long
// dark-theme session. Cards lift off the page via the standard light-theme
// convention (surface lighter than base).
// ---------------------------------------------------------------------------
const sietchTabr: Preset = {
  id: 'sietch-tabr',
  name: 'Sietch Tabr',
  description: 'Daytime light theme. Aged-parchment tan with deep amber text — dim enough to live in.',
  preview: ['#c9b894', '#d8c8a2', '#92400e', '#1e40af', '#2e1f0e'],
  tokens: {
    '--color-base':          '#c9b894',
    '--color-surface':       '#d8c8a2',
    '--color-surface-2':     '#beb086',
    '--color-surface-3':     '#a89c75',
    '--color-border':        '#8c7e5e',
    '--color-border-bright': '#6b5e44',

    '--color-text':          '#2e1f0e',
    '--color-text-muted':    '#5a4528',
    '--color-text-dim':      '#786448',

    '--color-accent':        '#92400e',
    '--color-accent-bright': '#b45309',
    '--color-accent-dim':    '#78350f',
    '--color-accent-fg':     '#f5ecd9',

    '--color-ibad':          '#1e40af',
    '--color-ibad-bright':   '#1d4ed8',

    '--color-success':       '#14532d',
    '--color-danger':        '#991b1b',
    '--color-warning':       '#854d0e',
    '--color-info':          '#1e40af',
  },
}

// ---------------------------------------------------------------------------
// Caladan — Atreides homeworld. Ocean blue/teal on storm-cloud charcoal,
// with seafoam cyan accent.
// ---------------------------------------------------------------------------
const caladan: Preset = {
  id: 'caladan',
  name: 'Caladan',
  description: 'Atreides homeworld. Muted slate-blue on stormcloud grey.',
  preview: ['#131820', '#1a2230', '#6b87a8', '#a3b8cc', '#e0f2fe'],
  tokens: {
    '--color-base':          '#131820',
    '--color-surface':       '#1a2230',
    '--color-surface-2':     '#232d3d',
    '--color-surface-3':     '#2c3849',
    '--color-border':        '#3a4858',
    '--color-border-bright': '#556578',

    '--color-text':          '#e0f2fe',
    '--color-text-muted':    '#9bb4cc',
    '--color-text-dim':      '#5d7894',

    '--color-accent':        '#6b87a8',
    '--color-accent-bright': '#8aa3bf',
    '--color-accent-dim':    '#475569',
    '--color-accent-fg':     '#0a0f14',

    '--color-ibad':          '#a3b8cc',
    '--color-ibad-bright':   '#cdd9e0',

    '--color-success':       '#34d399',
    '--color-danger':        '#fb7185',
    '--color-warning':       '#fcd34d',
    '--color-info':          '#a3b8cc',
  },
}

// ---------------------------------------------------------------------------
// Giedi Prime — Harkonnen homeworld. Pure black, blood-red accent, bone-white
// text. High-contrast OLED-friendly.
// ---------------------------------------------------------------------------
const giediPrime: Preset = {
  id: 'giedi-prime',
  name: 'Giedi Prime',
  description: 'Harkonnen homeworld. Dark slate-grey with blood-red accents.',
  preview: ['#181818', '#222222', '#dc2626', '#a3a3a3', '#fafafa'],
  tokens: {
    '--color-base':          '#181818',
    '--color-surface':       '#222222',
    '--color-surface-2':     '#2c2c2c',
    '--color-surface-3':     '#363636',
    '--color-border':        '#444444',
    '--color-border-bright': '#5e5e5e',

    '--color-text':          '#fafafa',
    '--color-text-muted':    '#a3a3a3',
    '--color-text-dim':      '#737373',

    '--color-accent':        '#dc2626',
    '--color-accent-bright': '#ef4444',
    '--color-accent-dim':    '#991b1b',
    '--color-accent-fg':     '#fafafa',

    '--color-ibad':          '#a3a3a3',
    '--color-ibad-bright':   '#d4d4d4',

    '--color-success':       '#22c55e',
    '--color-danger':        '#ef4444',
    '--color-warning':       '#eab308',
    '--color-info':          '#a3a3a3',
  },
}

// ---------------------------------------------------------------------------
// Atreides — house colors. Forest green + royal gold on midnight.
// ---------------------------------------------------------------------------
const atreides: Preset = {
  id: 'atreides',
  name: 'Atreides',
  description: 'House colors. Forest green and royal gold on midnight blue.',
  preview: ['#0c1410', '#13201a', '#eab308', '#16a34a', '#f0fdf4'],
  tokens: {
    '--color-base':          '#0c1410',
    '--color-surface':       '#13201a',
    '--color-surface-2':     '#1a2d23',
    '--color-surface-3':     '#22392d',
    '--color-border':        '#2e4d3c',
    '--color-border-bright': '#4a7259',

    '--color-text':          '#f0fdf4',
    '--color-text-muted':    '#a7c4b3',
    '--color-text-dim':      '#6b8a78',

    '--color-accent':        '#eab308',
    '--color-accent-bright': '#facc15',
    '--color-accent-dim':    '#a16207',
    '--color-accent-fg':     '#0c1410',

    '--color-ibad':          '#16a34a',
    '--color-ibad-bright':   '#22c55e',

    '--color-success':       '#22c55e',
    '--color-danger':        '#f87171',
    '--color-warning':       '#facc15',
    '--color-info':          '#16a34a',
  },
}

// ---------------------------------------------------------------------------
// House Harkonnen — heraldic. Bone-white sigil on blood-crimson and oxidized
// blacks. Distinct from Giedi Prime (which is pure OLED black) — Harkonnen
// leans into the red-on-red house colors with silver/bone highlights for the
// sigil-and-armor feel.
// ---------------------------------------------------------------------------
const harkonnen: Preset = {
  id: 'harkonnen',
  name: 'House Harkonnen',
  description: 'Heraldic. Bone-white sigil on blood-crimson and oxidized black.',
  preview: ['#0a0202', '#150404', '#b91c1c', '#e5e7eb', '#fafafa'],
  tokens: {
    '--color-base':          '#0a0202',
    '--color-surface':       '#150404',
    '--color-surface-2':     '#1f0606',
    '--color-surface-3':     '#2a0808',
    '--color-border':        '#3a0e0e',
    '--color-border-bright': '#5a1818',

    '--color-text':          '#fafafa',
    '--color-text-muted':    '#d4d4d8',
    '--color-text-dim':      '#a1a1aa',

    '--color-accent':        '#b91c1c',
    '--color-accent-bright': '#dc2626',
    '--color-accent-dim':    '#7f1d1d',
    '--color-accent-fg':     '#fafafa',

    '--color-ibad':          '#e5e7eb',
    '--color-ibad-bright':   '#ffffff',

    '--color-success':       '#22c55e',
    '--color-danger':        '#f97316',
    '--color-warning':       '#fbbf24',
    '--color-info':          '#e0e7ff',
  },
}

export const PRESETS: Preset[] = [eyesOfIbad, sietchTabr, caladan, giediPrime, harkonnen, atreides]

export const DEFAULT_PRESET_ID = eyesOfIbad.id

export function getPreset(id: string): Preset | undefined {
  return PRESETS.find(p => p.id === id)
}

// Dev-time sanity check: each preset declares every known token.
if (import.meta.env?.DEV) {
  for (const p of PRESETS) {
    const missing = TOKEN_KEYS.filter(k => !(k in p.tokens))
    if (missing.length > 0) {
      // Surfaces it in the dev console, doesn't crash the app.
      console.warn(`[theme] Preset "${p.id}" is missing tokens:`, missing)
    }
  }
}
