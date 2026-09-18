import { useState, useEffect, useMemo, useCallback, type FormEvent, type KeyboardEvent, type ReactElement } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { CollapsibleCard, useCardCollapse } from '../components/CollapsibleCard'
import { Link } from '../router'
import { IniShareModal } from '../components/IniShareModal'
import { ViewportNotice } from '../components/ViewportNotice'
import { useStatus } from '../hooks/useStatus'
import { useCommandDeck } from '../hooks/useCommandDeck'
import { api } from '../api/client'
import { confirmRoutineAction } from '../hooks/useReducedRoutineUi'
import { ServerNameCard } from './gameconfig/ServerNameCard'
import { TimeOfDayLockPanel } from './gameconfig/TwilightLockEvidenceCard'
import {
  getGameConfigSchema,
  getGameConfigExperimentalCategories,
  getGameConfigExperimentalCategory,
  searchGameConfigExperimental,
  getGameConfig,
  saveGameConfig,
  reloadGameConfigPods,
  backupGameConfig,
  listGameConfigBackups,
  deleteGameConfigBackups,
  getGameConfigClient,
  setGameConfigClientDir,
  setGameConfigClientEngineEnabled,
  applyGameConfigClient,
  openGameConfigClientFile,
  getGameConfigDefaults,
  saveGameConfigRaw,
} from '../api/gameconfig'
import type {
  GameConfigCategory,
  GameConfigField,
  GameConfigResponse,
  GameConfigFileBundle,
  GameConfigIniSection,
  GameConfigBackupEntry,
  GameConfigClientInfo,
  GameConfigDefaultsResponse,
  GameConfigDefaultSection,
  GameConfigDefaultKey,
  GameConfigRawUpdate,
  GameConfigClientApplyItem,
} from '../api/types'
import { SpicefieldsCard } from './gameconfig/SpicefieldsCard'
import { LandclaimTimerCard } from './gameconfig/LandclaimTimerCard'
import { DeepDesertPvpCard } from './gameconfig/DeepDesertPvpCard'
import { BaseBackupGuardPanel } from './gameconfig/BaseBackupGuardPanel'
import { isLocalViewer } from '../util/viewer'

export const EXPERIMENTAL_BLOCKED_DEFAULT_TARGETS = new Set([
  'game||/script/dunesandbox.timeofdaysettings||m_starttime',
])

const RETAIL_CLIENT_COMPATIBILITY_TARGETS = new Set([
  'engine||vehicle.maxvehiclesperplayer',
  'engine||dune.disableshieldonshooting',
  'game||playerinventorystartingsize',
  'game||playerinventorystartingvolumecapacity',
  'game||m_basebackuptoolmaprestriction',
])

type LoadState = 'idle' | 'loading' | 'ready' | 'error' | 'unavailable'
type ClientReviewMode = 'server' | 'legacy'

function clientBundleFor(info: GameConfigClientInfo, file: 'game' | 'engine') {
  return file === 'engine' ? info.engine : (info.game ?? info)
}

// Scroll back to the top of the page. The app scrolls inside AppShell's <main>
// element rather than the window, so walk up from the clicked button to the
// nearest scrollable ancestor and fall back to <main> / the window.
function scrollPageToTop(from: HTMLElement) {
  let el: HTMLElement | null = from.parentElement
  while (el) {
    const overflowY = getComputedStyle(el).overflowY
    if ((overflowY === 'auto' || overflowY === 'scroll') && el.scrollHeight > el.clientHeight) {
      el.scrollTo({ top: 0, behavior: 'smooth' })
      return
    }
    el = el.parentElement
  }
  const main = document.querySelector('main')
  if (main) main.scrollTo({ top: 0, behavior: 'smooth' })
  else window.scrollTo({ top: 0, behavior: 'smooth' })
}

const SANDWORM_ENABLED_KEY = 'sandworm.dune.Enabled'
const CORIOLIS_CYCLE_START_HOUR_KEY = 'm_CycleStartHour'
const CLIENT_INI_PATHS = {
  game: '%LOCALAPPDATA%\\DuneSandbox\\Saved\\Config\\Windows\\Game.ini',
  engine: '%LOCALAPPDATA%\\DuneSandbox\\Saved\\Config\\Windows\\Engine.ini',
} as const

type ClientShareEntry = { file: 'game' | 'engine'; path: string; block: string }

// Bool literal pairs per type so toggles emit exactly what UE expects.
function boolPair(type: GameConfigField['type']): { on: string; off: string } | null {
  if (type === 'bool') return { on: 'True', off: 'False' }
  if (type === 'boolLower') return { on: 'true', off: 'false' }
  if (type === 'bool01') return { on: '1', off: '0' }
  return null
}

function bundleFor(data: GameConfigResponse, file: 'game' | 'engine'): GameConfigFileBundle | null {
  // Defensive: a malformed / partial server response could omit one of the
  // bundles. Returning null lets every caller short-circuit to an "unset"
  // value instead of throwing on `.effective` and white-outing the form.
  if (!data) return null
  const b = file === 'game' ? data.game : data.engine
  return b ?? null
}

function fieldDefault(field: GameConfigField): string {
  return field?.default ?? ''
}

// Live value written in the battlegroup's INI for this field ('' when unset or VM down).
// Primary lookup is by the field's declared section. If the key isn't there but
// exists in ANOTHER section of the same file (a pre-existing placement that
// doesn't match DST's canonical section), fall back to the by-key value so the
// page reflects what's actually in the INI rather than showing the default. DST
// consolidates the key back into its declared section on the next save.
function liveValue(data: GameConfigResponse | null, field: GameConfigField): string {
  if (!data || !field) return ''
  const b = bundleFor(data, field.file)
  const inSection = b?.effective?.[`${field.section}||${field.key}`]
  if (inSection !== undefined && inSection !== '') return inSection
  const byKey = b?.effectiveByKey?.[field.key]
  return byKey ?? inSection ?? ''
}

// A field is "customized" when the live file overrides it with a value other than the default.
function isCustomized(data: GameConfigResponse | null, field: GameConfigField): boolean {
  const lv = liveValue(data, field)
  return lv !== '' && lv !== fieldDefault(field)
}

type ClientShareValue = {
  file: 'game' | 'engine'
  section: string
  key: string
  value: string
  structKey?: string
}

// Struct members cannot be emitted as standalone key=value lines. UE replaces
// the whole struct, so copy the complete live struct line once.
export function buildClientShareEntries(
  items: ClientShareValue[],
  cfg: GameConfigResponse | null,
  paths: Partial<Record<'game' | 'engine', string>> = CLIENT_INI_PATHS,
): ClientShareEntry[] {
  const byFile = new Map<'game' | 'engine', Map<string, string[]>>()
  const seen = new Set<string>()
  for (const item of items) {
    const bySection = byFile.get(item.file) ?? new Map<string, string[]>()
    const lines = bySection.get(item.section) ?? []
    if (item.structKey) {
      const id = `${item.file}||${item.section}||${item.structKey}`
      if (seen.has(id)) continue
      const bundle = cfg ? bundleFor(cfg, item.file) : null
      const structValue = bundle?.effective?.[`${item.section}||${item.structKey}`]
      if (!structValue) continue
      lines.push(`${item.structKey}=${structValue}`)
      seen.add(id)
    } else {
      const id = `${item.file}||${item.section}||${item.key}`
      if (seen.has(id)) continue
      lines.push(`${item.key}=${item.value}`)
      seen.add(id)
    }
    bySection.set(item.section, lines)
    byFile.set(item.file, bySection)
  }
  const entries: ClientShareEntry[] = []
  for (const file of ['engine', 'game'] as const) {
    const bySection = byFile.get(file)
    if (!bySection) continue
    entries.push({
      file,
      path: paths[file] ?? CLIENT_INI_PATHS[file],
      block: [...bySection.entries()]
        .map(([section, lines]) => [`[${section}]`, ...lines].join('\r\n'))
        .join('\r\n\r\n') + '\r\n',
    })
  }
  return entries
}

// The Experimental lists are console variables read out of the server binary.
// They share a warning banner, start rolled up, and are the ones that need a
// battlegroup restart before they do anything. "Experimental 2" is simply the
// overflow of the same set, split so neither list is unmanageably long.
// Build one set of client blocks covering EVERY customised client-apply setting
// DST manages, across every category on every page. Both Game Config and the
// Experimental page show this same list — a player needs the complete set, not
// whichever half the admin happened to be looking at. Engine.ini comes first so
// it lands on the left of the side-by-side view.
//
// Only settings actually changed from their default are included: that is what
// "DST added" means, and a player copying a value that already matches the
// default just adds noise to their file.
export function buildAllClientBlocks(
  cats: GameConfigCategory[] | null,
  cfg: GameConfigResponse | null,
): { entries: ClientShareEntry[]; count: number } {
  const items: ClientShareValue[] = []
  const seen = new Set<string>()
  let count = 0
  for (const cat of cats ?? []) {
    for (const f of cat.fields ?? []) {
      if (!f?.key || !f.clientApply) continue
      if (!isCustomized(cfg, f)) continue
      const v = liveValue(cfg, f)
      if (v === '') continue
      const id = `${f.file}||${f.section}||${f.key}`
      if (seen.has(id)) continue
      seen.add(id)
      items.push({ file: f.file, section: f.section, key: f.key, value: v, structKey: f.structKey })
      count++
    }
  }
  return { entries: buildClientShareEntries(items, cfg), count }
}

export function buildAllClientApplyItems(
  cats: GameConfigCategory[] | null,
  cfg: GameConfigResponse | null,
): GameConfigClientApplyItem[] {
  const items: GameConfigClientApplyItem[] = []
  const seen = new Set<string>()
  for (const cat of cats ?? []) {
    for (const field of cat.fields ?? []) {
      if (!field?.key || !field.clientApply || !isCustomized(cfg, field)) continue
      const target = `${field.file}||${field.key}`.toLowerCase()
      if (!RETAIL_CLIENT_COMPATIBILITY_TARGETS.has(target)) continue
      const value = liveValue(cfg, field)
      if (value === '') continue
      // The client API identifies a write by file + schema key; section is
      // display metadata resolved authoritatively from that key on the server.
      if (seen.has(target)) continue
      seen.add(target)
      items.push({
        file: field.file,
        section: field.section,
        key: field.key,
        label: field.label,
        value,
        structKey: field.structKey,
      })
    }
  }
  return items
}

function isExperimentalCategory(category: string): boolean {
  return category.startsWith('Experimental')
}

const EXPERIMENTAL_PAGE_SIZE = 25

// Build file-aware client blocks for a category's customised fields. Struct-backed
// controls emit their complete parent line once, never pseudo member keys.
export function buildCategoryClientBlocks(
  cat: GameConfigCategory,
  cfg: GameConfigResponse | null,
): { entries: ClientShareEntry[]; count: number; hasClientFields: boolean } {
  const clientFields = (cat.fields ?? []).filter(f => f && f.key && f.clientApply)
  const hasClientFields = clientFields.length > 0
  const items: ClientShareValue[] = []
  let count = 0
  for (const f of clientFields) {
    if (!isCustomized(cfg, f)) continue
    const v = liveValue(cfg, f)
    if (v === '') continue
    items.push({
      file: f.file,
      section: f.section,
      key: f.key,
      value: v,
      structKey: f.structKey,
    })
    count++
  }
  return { entries: buildClientShareEntries(items, cfg), count, hasClientFields }
}

// The value an input should hold: the live override when present, otherwise the default.
function currentValue(data: GameConfigResponse | null, field: GameConfigField): string {
  const lv = liveValue(data, field)
  return lv !== '' ? lv : fieldDefault(field)
}

// Numeric-aware, case-insensitive equality so 4 vs 4.0 and True vs true don't
// register as mismatches between the server and client INI values.
function valuesEqual(a: string, b: string): boolean {
  const ta = (a ?? '').trim()
  const tb = (b ?? '').trim()
  if (ta !== '' && tb !== '') {
    const na = Number(ta)
    const nb = Number(tb)
    if (Number.isFinite(na) && Number.isFinite(nb)) return na === nb
  }
  return ta.toLowerCase() === tb.toLowerCase()
}

function copyTextToClipboard(text: string) {
  const write = navigator.clipboard?.writeText(text)
  if (write) void write.catch(() => { /* clipboard may be unavailable */ })
}

function copyIniSectionFromKey(e: KeyboardEvent<HTMLElement>, sectionName: string) {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'c') {
    e.preventDefault()
    e.stopPropagation()
    copyTextToClipboard(`[${sectionName}]`)
  }
}

function sectionIsManaged(data: GameConfigResponse, field: GameConfigField): boolean {  if (!data || !field) return false
  const b = bundleFor(data, field.file)
  // PS+ConvertTo-Json can collapse an empty hashtable to {} or unwrap a
  // single-element array to a scalar, so managedSections may not always be
  // an array on the wire. Defensively coerce before calling .includes.
  const ms = b?.managedSections
  if (Array.isArray(ms)) return ms.includes(field.section)
  if (typeof ms === 'string') return ms === field.section
  return false
}

// Experimental controls get their own page, grouped by what they affect rather
// than by which decode pass found them. Order is presentation, so it lives here
// rather than in the schema; anything the backend could not place is reported as
// "Uncategorized" and is always shown last.
const EXPERIMENTAL_GROUP_ORDER = [
  'Survival & Shelter',
  'Fuel & Power',
  'Sandworm',
  'Hazards & Storms',
  'Base Building & Backups',
  'Vehicles',
  'Combat & Shields',
  'NPCs & Encounters',
  'Loot & Inventory',
  'Progression & Contracts',
  'Spice & Harvesting',
  'Server & Session',
]

function experimentalGroupRank(group: string): number {
  if (group === 'Uncategorized') return EXPERIMENTAL_GROUP_ORDER.length + 1
  const i = EXPERIMENTAL_GROUP_ORDER.indexOf(group)
  return i === -1 ? EXPERIMENTAL_GROUP_ORDER.length : i
}

// Re-shape the experimental categories into one card per group.
function groupExperimental(cats: GameConfigCategory[]): GameConfigCategory[] {
  const byGroup = new Map<string, GameConfigField[]>()
  for (const cat of cats) {
    for (const f of cat.fields ?? []) {
      if (!f?.key) continue
      const g = f.group || 'Uncategorized'
      if (!byGroup.has(g)) byGroup.set(g, [])
      byGroup.get(g)!.push(f)
    }
  }
  return [...byGroup.entries()]
    .sort((a, b) => experimentalGroupRank(a[0]) - experimentalGroupRank(b[0]) || a[0].localeCompare(b[0]))
    .map(([category, fields]) => ({ category, fields }))
}

export function GameConfig({ mode = 'standard' }: { mode?: 'standard' | 'experimental' } = {}) {
  const contextual = useCommandDeck()
  const Guidance = contextual ? 'details' : 'div'
  const experimentalPage = mode === 'experimental'
  const localViewer = isLocalViewer()
  const { status, forceRefresh } = useStatus()
  const vmRunning = status?.vm?.running === true

  const [schema, setSchema] = useState<GameConfigCategory[] | null>(null)
  const [cfg, setCfg] = useState<GameConfigResponse | null>(null)
  const [values, setValues] = useState<Record<string, string>>({})
  const [originals, setOriginals] = useState<Record<string, string>>({})
  const [loadState, setLoadState] = useState<LoadState>('idle')
  const [loadError, setLoadError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)
  const [savedMsg, setSavedMsg] = useState<string | null>(null)
  const [reloadingPods, setReloadingPods] = useState(false)
  const [sandwormModalOpen, setSandwormModalOpen] = useState(false)
  const [search, setSearch] = useState('')
  const [experimentalGroup, setExperimentalGroup] = useState<string | null>(null)
  const [experimentalCatalogCategories, setExperimentalCatalogCategories] = useState<Array<{ category: string; count: number }>>([])
  const [experimentalCategoryCache, setExperimentalCategoryCache] = useState<Record<string, GameConfigField[]>>({})
  const [experimentalCategoryLoading, setExperimentalCategoryLoading] = useState<string | null>(null)
  const [experimentalCategoryError, setExperimentalCategoryError] = useState<string | null>(null)
  const [experimentalSearchFields, setExperimentalSearchFields] = useState<GameConfigField[]>([])
  const [experimentalSearchLoading, setExperimentalSearchLoading] = useState(false)
  const [experimentalSearchError, setExperimentalSearchError] = useState<string | null>(null)
  const [experimentalSource, setExperimentalSource] = useState<'all' | 'Dune' | 'Engine'>('all')
  const [experimentalRisk, setExperimentalRisk] = useState<'all' | 'experimental' | 'diagnostic' | 'high' | 'critical'>('all')
  const [experimentalModifiedOnly, setExperimentalModifiedOnly] = useState(false)
  const [experimentalPageIndex, setExperimentalPageIndex] = useState(0)
  // "Give players this" section share popup (client-side Game.ini block).
  const [shareBlock, setShareBlock] = useState<{ title: string; subtitle?: string; entries: ClientShareEntry[] } | null>(null)
  const [backing, setBacking] = useState(false)
  const [backupMsg, setBackupMsg] = useState<string | null>(null)
  const [backupError, setBackupError] = useState<string | null>(null)
  const [backupsOpen, setBackupsOpen] = useState(false)
  const [backupsLoading, setBackupsLoading] = useState(false)
  const [backupsError, setBackupsError] = useState<string | null>(null)
  const [backups, setBackups] = useState<GameConfigBackupEntry[]>([])
  const [backupSel, setBackupSel] = useState<Set<string>>(new Set())
  const [backupDeleting, setBackupDeleting] = useState(false)

  // Local client config (this PC). Game.ini writes remain per-action; Engine.ini
  // management requires the persistent, disabled-by-default opt-in.
  const [clientInfo, setClientInfo] = useState<GameConfigClientInfo | null>(null)
  const [clientDirInput, setClientDirInput] = useState('')
  const [clientBusy, setClientBusy] = useState(false)
  const [clientMsg, setClientMsg] = useState<string | null>(null)
  const [clientErr, setClientErr] = useState<string | null>(null)
  const [clientReview, setClientReview] = useState<{ mode: ClientReviewMode; items: GameConfigClientApplyItem[] } | null>(null)
  const [clientViewFile, setClientViewFile] = useState<'game' | 'engine' | null>(null)
  const refreshClient = useCallback(async () => {
    if (!localViewer) return null
    try {
      const info = await getGameConfigClient()
      setClientInfo(info)
      setClientDirInput(prev => (prev ? prev : info.dir))
      return info
    } catch (e) {
      setClientErr(e instanceof Error ? e.message : String(e))
      return null
    }
  }, [localViewer])

  useEffect(() => {
    void refreshClient()
  }, [refreshClient])

  const onBrowseClientDir = useCallback(async () => {
    setClientErr(null)
    setClientBusy(true)
    try {
      const r = await api<{ ok: boolean; cancelled: boolean; path: string }>('/api/browse-path', {
        method: 'POST',
        body: JSON.stringify({
          mode: 'folder',
          current: clientInfo?.dirResolved ?? clientDirInput,
          title: 'Select your Dune client config folder',
        }),
      })
      if (r.ok && !r.cancelled && r.path) setClientDirInput(r.path)
    } catch (e) {
      setClientErr(e instanceof Error ? e.message : String(e))
    } finally {
      setClientBusy(false)
    }
  }, [clientInfo, clientDirInput])

  const onSaveClientDir = useCallback(async () => {
    const dir = clientDirInput.trim()
    if (!dir) return
    setClientErr(null)
    setClientMsg(null)
    setClientBusy(true)
    try {
      const info = await setGameConfigClientDir(dir)
      setClientInfo(info)
      setClientDirInput(info.dir)
      setClientMsg('Client config folder saved.')
      window.setTimeout(() => setClientMsg(null), 5000)
    } catch (e) {
      setClientErr(e instanceof Error ? e.message : String(e))
    } finally {
      setClientBusy(false)
    }
  }, [clientDirInput])

  const onToggleClientEngine = useCallback(async (enabled: boolean) => {
    setClientErr(null)
    setClientMsg(null)
    setClientBusy(true)
    try {
      const result = await setGameConfigClientEngineEnabled(enabled, clientInfo?.dir)
      setClientInfo(result.client)
      if (result.client.engineEnabled) {
        setClientMsg('Engine.ini management enabled. DST can now mirror opted-in gameplay settings.')
      } else {
        setClientMsg(result.removed > 0
          ? `Engine.ini management disabled and ${result.removed} DST-managed setting${result.removed === 1 ? '' : 's'} removed.`
          : 'Engine.ini management disabled. No DST-managed Engine.ini settings were present.')
      }
      window.setTimeout(() => setClientMsg(null), 7000)
    } catch (e) {
      setClientErr(e instanceof Error ? e.message : String(e))
    } finally {
      setClientBusy(false)
    }
  }, [clientInfo])

  const onViewClient = useCallback(async (file: 'game' | 'engine') => {
    setClientErr(null)
    setClientViewFile(file)
    await refreshClient()
  }, [refreshClient])

  // Open either local client INI in Notepad on this PC (DST runs locally).
  const onOpenInEditor = useCallback(async (file: 'game' | 'engine') => {
    setClientErr(null)
    setClientMsg(null)
    setClientBusy(true)
    try {
      const r = await openGameConfigClientFile(file, clientInfo?.dir)
      setClientMsg(`Opened ${r.path} in Notepad.`)
      window.setTimeout(() => setClientMsg(null), 5000)
    } catch (e) {
      setClientErr(e instanceof Error ? e.message : String(e))
    } finally {
      setClientBusy(false)
    }
  }, [clientInfo])

  const onBackup = useCallback(async () => {
    setBacking(true)
    setBackupError(null)
    setBackupMsg(null)
    try {
      const r = await backupGameConfig()
      if (!r.ok) {
        setBackupError('Backup did not complete for one or more files. Is the battlegroup fully provisioned?')
        return
      }
      setBackupMsg(`Backed up UserGame.ini + UserEngine.ini on the server (snapshot ${r.timestamp}). You can revert via the File Browser if needed.`)
      window.setTimeout(() => setBackupMsg(null), 9000)
    } catch (e) {
      setBackupError(e instanceof Error ? e.message : String(e))
    } finally {
      setBacking(false)
    }
  }, [])

  const onViewBackups = useCallback(async () => {
    setBackupsOpen(true)
    setBackupsLoading(true)
    setBackupsError(null)
    setBackupSel(new Set())
    try {
      const r = await listGameConfigBackups()
      setBackups(r.backups ?? [])
    } catch (e) {
      setBackupsError(e instanceof Error ? e.message : String(e))
    } finally {
      setBackupsLoading(false)
    }
  }, [])

  const toggleBackupSel = useCallback((path: string) => {
    setBackupSel(prev => {
      const next = new Set(prev)
      if (next.has(path)) next.delete(path); else next.add(path)
      return next
    })
  }, [])

  const onDeleteSelectedBackups = useCallback(async () => {
    const paths = [...backupSel]
    if (paths.length === 0) return
    setBackupDeleting(true)
    setBackupsError(null)
    try {
      const r = await deleteGameConfigBackups(paths)
      const failed = (r.results ?? []).filter(x => !x.ok)
      setBackups(prev => prev.filter(b => !(backupSel.has(b.path) && !failed.some(f => f.path === b.path))))
      setBackupSel(new Set())
      if (failed.length > 0) {
        setBackupsError(`Deleted ${r.deleted}, but ${failed.length} could not be removed.`)
      }
    } catch (e) {
      setBackupsError(e instanceof Error ? e.message : String(e))
    } finally {
      setBackupDeleting(false)
    }
  }, [backupSel])

  const handleFieldChange = useCallback((key: string, newVal: string) => {
    if (
      key === SANDWORM_ENABLED_KEY &&
      newVal === '1' &&
      (values[key] ?? '') !== '1'
    ) {
      setSandwormModalOpen(true)
      return
    }
    setValues(prev => ({ ...prev, [key]: newVal }))
  }, [values])

  const confirmSandwormEnable = useCallback(() => {
    setValues(prev => ({ ...prev, [SANDWORM_ENABLED_KEY]: '1' }))
    setSandwormModalOpen(false)
  }, [])

  // Seed editable values: live override when present, otherwise the funcom default,
  // so every field is populated even before (or without) a live battlegroup.
  const seedValues = useCallback((cats: GameConfigCategory[], data: GameConfigResponse | null) => {
    const out: Record<string, string> = {}
    for (const cat of cats ?? []) {
      for (const f of cat?.fields ?? []) {
        if (f?.key) out[f.key] = currentValue(data, f)
      }
    }
    return out
  }, [])

  const loadAll = useCallback(async () => {
    setLoadState('loading')
    setLoadError(null)
    setSavedMsg(null)
    try {
      let sch = schema
      if (!sch) {
        const resp = await getGameConfigSchema()
        sch = resp?.schema
        if (!Array.isArray(sch)) throw new Error('Game config schema response was empty or malformed.')
        setSchema(sch)
      }
      const data = await getGameConfig()
      setCfg(data)
      const seeded = seedValues(sch, data)
      setValues(seeded)
      setOriginals(seeded)
      setLoadState('ready')
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      setLoadError(msg)
      setLoadState(/\b503\b/.test(msg) ? 'unavailable' : 'error')
    }
  }, [schema, seedValues])

  useEffect(() => {
    void (async () => {
      let s = schema
      if (!s) {
        // Retry the schema fetch up to 3 times — the WebView2 occasionally races
        // the dev/prod server startup, and a single failure here previously
        // left the page in a permanent error state until the user navigated away.
        let lastErr: unknown = null
        for (let attempt = 0; attempt < 3; attempt++) {
          try {
            const resp = await getGameConfigSchema()
            if (!Array.isArray(resp?.schema)) throw new Error('Schema response was empty or malformed.')
            s = resp.schema
            setSchema(s)
            lastErr = null
            break
          } catch (e) {
            lastErr = e
            if (attempt < 2) await new Promise(r => setTimeout(r, 400 * (attempt + 1)))
          }
        }
        if (!s) {
          setLoadError(lastErr instanceof Error ? lastErr.message : String(lastErr ?? 'Failed to load schema'))
          setLoadState('error')
          return
        }
      }
      if (vmRunning) {
        void loadAll()
      } else {
        // No live battlegroup: populate every field with its funcom default so the
        // form is readable. Editing/saving is gated until the VM is up.
        try {
          const seeded = seedValues(s, null)
          setValues(seeded)
          setOriginals(seeded)
        } catch (e) {
          // Seeding should never throw with the guards in seedValues, but if it
          // does we still want to leave the page in a recoverable state.
          console.error('GameConfig seedValues failed', e)
        }
        setCfg(null)
        setLoadState('unavailable')
        setLoadError('Showing Funcom defaults — start the battlegroup to load live values and edit.')
      }
    })()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [vmRunning])

  useEffect(() => {
    if (!experimentalPage) return
    let cancelled = false
    void getGameConfigExperimentalCategories()
      .then(response => {
        if (!cancelled) setExperimentalCatalogCategories(response.categories ?? [])
      })
      .catch(error => {
        if (!cancelled) setExperimentalCategoryError(error instanceof Error ? error.message : String(error))
      })
    return () => { cancelled = true }
  }, [experimentalPage])

  const dirtyKeys = useMemo(() => {
    const keys: string[] = []
    for (const k of Object.keys(values)) {
      if ((values[k] ?? '') !== (originals[k] ?? '')) keys.push(k)
    }
    return keys
  }, [values, originals])

  const loadedExperimentalFields = useMemo(
    () => {
      const fields = [...Object.values(experimentalCategoryCache).flat(), ...experimentalSearchFields]
      return [...new Map(fields.map(field => [
        `${field.file}||${field.section}||${field.key}`.toLowerCase(),
        field,
      ] as const)).values()]
    },
    [experimentalCategoryCache, experimentalSearchFields],
  )
  const schemaWithLoadedExperimental = useMemo(
    () => loadedExperimentalFields.length > 0
      ? [...(schema ?? []), { category: 'Experimental Lab', fields: loadedExperimentalFields }]
      : (schema ?? []),
    [schema, loadedExperimentalFields],
  )

  const surfacedIniTargets = useMemo(() => {
    const keys = new Set<string>(EXPERIMENTAL_BLOCKED_DEFAULT_TARGETS)
    for (const category of schemaWithLoadedExperimental) {
      for (const field of category.fields ?? []) {
        if (!field?.key) continue
        keys.add(`${field.file}||${field.section}||${field.key}`.toLowerCase())
        if (field.structKey) {
          keys.add(`${field.file}||${field.section}||${field.structKey}`.toLowerCase())
        }
      }
    }
    return keys
  }, [schemaWithLoadedExperimental])

  const experimentalStartupKeys = useMemo(() => {
    const keys = new Set<string>()
    for (const category of schemaWithLoadedExperimental) {
      if (!isExperimentalCategory(category.category)) continue
      for (const field of category.fields ?? []) {
        if (field.file === 'engine') keys.add(field.key)
      }
    }
    return keys
  }, [schemaWithLoadedExperimental])
  const experimentalStartupDirtyKeys = useMemo(
    () => dirtyKeys.filter(k => experimentalStartupKeys.has(k)),
    [dirtyKeys, experimentalStartupKeys],
  )
  const clientApplyItems = useMemo(
    () => buildAllClientApplyItems(schemaWithLoadedExperimental, cfg),
    [schemaWithLoadedExperimental, cfg],
  )
  const enabledClientApplyItems = useMemo(
    () => clientApplyItems.filter(item => item.file === 'game' || clientInfo?.engineEnabled === true),
    [clientApplyItems, clientInfo?.engineEnabled],
  )
  const legacyMigrationItems = useMemo(
    () => (clientInfo?.legacyMigration?.candidates ?? [])
      .filter(item => item.state !== 'current')
      .filter(item => item.file === 'game' || clientInfo?.engineEnabled === true),
    [clientInfo],
  )

  const onApplyCurrentClientSettings = useCallback(async (reviewedItems: GameConfigClientApplyItem[]) => {
    if (reviewedItems.length === 0) return
    setClientErr(null)
    setClientMsg(null)
    setClientBusy(true)
    try {
      const result = await applyGameConfigClient(reviewedItems, clientInfo?.dir)
      setClientInfo(result.client)
      setClientReview(null)
      const backupCount = Object.keys(result.backups ?? {}).length
      setClientMsg(
        `Applied ${result.applied} setting${result.applied === 1 ? '' : 's'} to this PC's local Dune client config${backupCount ? ` after backing up ${backupCount} destination file${backupCount === 1 ? '' : 's'}` : ''}. Other players must apply their own copy.`,
      )
      window.setTimeout(() => setClientMsg(null), 7000)
    } catch (e) {
      setClientErr(e instanceof Error ? e.message : String(e))
    } finally {
      setClientBusy(false)
    }
  }, [clientInfo])

  // The two pages share this component and split the same schema between them:
  // Game Config shows the settings we stand behind, Experimental shows the
  // recovered console variables regrouped by what they affect.
  const visibleSchema = useMemo(() => {
    if (!schema) return null
    const mine = schema.filter(c => isExperimentalCategory(c.category) === experimentalPage)
    return experimentalPage ? groupExperimental(mine) : mine
  }, [schema, experimentalPage])

  const experimentalGroups = useMemo(() => {
    if (!experimentalPage) return []
    const counts = new Map<string, number>()
    for (const category of visibleSchema ?? []) {
      counts.set(category.category, (counts.get(category.category) ?? 0) + (category.fields ?? []).length)
    }
    for (const category of experimentalCatalogCategories) {
      counts.set(category.category, (counts.get(category.category) ?? 0) + category.count)
    }
    counts.delete('All')
    const groups = [...counts.entries()]
      .map(([name, count]) => ({ name, count }))
      .sort((a, b) => experimentalGroupRank(a.name) - experimentalGroupRank(b.name) || a.name.localeCompare(b.name))
    return [{ name: 'All', count: groups.reduce((total, group) => total + group.count, 0) }, ...groups]
  }, [experimentalPage, visibleSchema, experimentalCatalogCategories])
  const selectedExperimentalGroup = experimentalGroup
    ?? experimentalGroups.find(group => group.name !== 'All')?.name
    ?? ''
  const experimentalSearchActive = search.trim() !== ''

  useEffect(() => {
    if (!experimentalPage || !selectedExperimentalGroup) return
    if (Object.prototype.hasOwnProperty.call(experimentalCategoryCache, selectedExperimentalGroup)) return
    let cancelled = false
    setExperimentalCategoryLoading(selectedExperimentalGroup)
    setExperimentalCategoryError(null)
    void getGameConfigExperimentalCategory(selectedExperimentalGroup)
      .then(response => {
        if (!cancelled) {
          setExperimentalCategoryCache(previous => ({
            ...previous,
            [selectedExperimentalGroup]: response.fields ?? [],
          }))
        }
      })
      .catch(error => {
        if (!cancelled) setExperimentalCategoryError(error instanceof Error ? error.message : String(error))
      })
      .finally(() => {
        if (!cancelled) setExperimentalCategoryLoading(null)
      })
    return () => { cancelled = true }
  }, [experimentalPage, selectedExperimentalGroup, experimentalCategoryCache])

  useEffect(() => {
    if (!experimentalPage) return
    const query = search.trim()
    if (!query) {
      setExperimentalSearchFields([])
      setExperimentalSearchLoading(false)
      setExperimentalSearchError(null)
      return
    }
    let cancelled = false
    setExperimentalSearchFields([])
    setExperimentalSearchLoading(true)
    setExperimentalSearchError(null)
    const timer = window.setTimeout(() => {
      void searchGameConfigExperimental(query)
        .then(response => {
          if (!cancelled) setExperimentalSearchFields(response.fields ?? [])
        })
        .catch(error => {
          if (!cancelled) setExperimentalSearchError(error instanceof Error ? error.message : String(error))
        })
        .finally(() => {
          if (!cancelled) setExperimentalSearchLoading(false)
        })
    }, 250)
    return () => {
      cancelled = true
      window.clearTimeout(timer)
    }
  }, [experimentalPage, search])

  const experimentalFieldsToSeed = useMemo(
    () => experimentalSearchActive
      ? experimentalSearchFields
      : (experimentalCategoryCache[selectedExperimentalGroup] ?? []),
    [experimentalCategoryCache, experimentalSearchActive, experimentalSearchFields, selectedExperimentalGroup],
  )

  useEffect(() => {
    if (experimentalFieldsToSeed.length === 0 || loadState === 'idle' || loadState === 'loading') return
    const seeded: Record<string, string> = {}
    for (const field of experimentalFieldsToSeed) seeded[field.key] = currentValue(cfg, field)
    setValues(previous => {
      const next = { ...previous }
      for (const [key, value] of Object.entries(seeded)) {
        if (!(key in next)) next[key] = value
      }
      return next
    })
    setOriginals(previous => {
      const next = { ...previous }
      for (const [key, value] of Object.entries(seeded)) {
        if (!(key in next)) next[key] = value
      }
      return next
    })
  }, [experimentalFieldsToSeed, loadState, cfg])

  const experimentalFilteredFields = useMemo(() => {
    if (!experimentalPage || !visibleSchema) return [] as GameConfigField[]
    const q = search.trim().toLowerCase()
    const schemaFields = experimentalSearchActive || selectedExperimentalGroup === 'All'
      ? visibleSchema.flatMap(category => category.fields ?? [])
      : (visibleSchema.find(category => category.category === selectedExperimentalGroup)?.fields ?? [])
    const catalogFields = experimentalSearchActive
      ? experimentalSearchFields
      : (experimentalCategoryCache[selectedExperimentalGroup] ?? [])
    const candidates = [...new Map([...schemaFields, ...catalogFields].map(field => [
      `${field.file}||${field.section}||${field.key}`.toLowerCase(),
      field,
    ] as const)).values()]
    return candidates
      .filter(field => {
        if (experimentalSource !== 'all' && field.source !== experimentalSource) return false
        if (experimentalRisk !== 'all' && field.risk !== experimentalRisk) return false
        if (experimentalModifiedOnly && !isCustomized(cfg, field)) return false
        if (!q) return true
        return (field.label ?? '').toLowerCase().includes(q)
          || (field.key ?? '').toLowerCase().includes(q)
          || (field.help ?? '').toLowerCase().includes(q)
          || (field.group ?? '').toLowerCase().includes(q)
      })
      .sort((a, b) => a.key.localeCompare(b.key))
  }, [experimentalPage, visibleSchema, experimentalCategoryCache, experimentalSearchFields, experimentalSearchActive, selectedExperimentalGroup, search, experimentalSource, experimentalRisk, experimentalModifiedOnly, cfg])

  useEffect(() => {
    setExperimentalPageIndex(0)
  }, [selectedExperimentalGroup, search, experimentalSource, experimentalRisk, experimentalModifiedOnly])

  const filteredSchema = useMemo(() => {
    if (!visibleSchema) return null
    if (experimentalPage) {
      const start = experimentalPageIndex * EXPERIMENTAL_PAGE_SIZE
      return [{
        category: experimentalSearchActive ? 'Search results' : selectedExperimentalGroup,
        fields: experimentalFilteredFields.slice(start, start + EXPERIMENTAL_PAGE_SIZE),
      }]
    }
    const q = search.trim().toLowerCase()
    if (!q) return visibleSchema
    return visibleSchema
      .map(cat => ({
        category: cat.category,
        fields: (cat.fields ?? []).filter(
          f =>
            (f?.label ?? '').toLowerCase().includes(q) ||
            (f?.key ?? '').toLowerCase().includes(q) ||
            (f?.help ?? '').toLowerCase().includes(q) ||
            cat.category.toLowerCase().includes(q),
        ),
      }))
      .filter(cat => cat.fields.length > 0)
  }, [visibleSchema, search, experimentalPage, experimentalSearchActive, selectedExperimentalGroup, experimentalFilteredFields, experimentalPageIndex])

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (dirtyKeys.length === 0) return
    if (experimentalStartupDirtyKeys.length > 0) {
      const count = experimentalStartupDirtyKeys.length
      const engineStatus = clientInfo?.engineEnabled
        ? 'Client Engine.ini management is currently ON.'
        : 'Client Engine.ini management is currently OFF.'
      const ok = confirmRoutineAction(
        `Save ${count} Experimental setting${count === 1 ? '' : 's'}?\n\n`
        + (experimentalPage
            ? 'These are written to the server UserGame.ini or UserEngine.ini as labeled. Nothing on the server changes until you restart the battlegroup — use “Apply INIs & restart” in the bar at the bottom of this page. Saving on its own does not disconnect anyone.\n\n'
            : 'These are written to the server UserEngine.ini. Nothing on the server changes until you restart the battlegroup — use “Apply INIs & restart”. Saving on its own does not disconnect anyone.\n\n')
        + 'Only controls explicitly marked Client are known to read a local Engine.ini value. '
        + 'Unknown-scope Lab controls stay server-side so field tests are not contaminated by an unnecessary client override.\n\n'
        + `${engineStatus} Turn it on under “Your client config” at the top of this page to let DST manage those values.`,
      )
      if (!ok) return
    }
    setSaving(true)
    setSaveError(null)
    setSavedMsg(null)
    try {
      const updates: Record<string, string> = {}
      for (const k of dirtyKeys) updates[k] = values[k] ?? ''
      const out = await saveGameConfig(updates)
      const next: GameConfigResponse = { available: true, source: out.source, game: out.game, engine: out.engine }
      setCfg(next)
      const seeded = seedValues(schemaWithLoadedExperimental, next)
      setValues(seeded)
      setOriginals(seeded)
      const n = out.applied ?? dirtyKeys.length
      let msg = `Saved ${n} change${n === 1 ? '' : 's'} into the DST-managed block. Tip: use “Backup settings” to snapshot before big changes — DST no longer auto-backs-up on every save.`
      if (experimentalStartupDirtyKeys.length > 0) {
        msg += experimentalPage
          ? ' Saved to the labeled server INI only — use “Apply INIs & restart” in the bar at the bottom of this page to put these into effect.'
          : ' Saved to the server INI only — restart the battlegroup with “Apply INIs & restart” to put these into effect.'
      }
      // If m_TaskGoalAmount was in this save, DST also rewrote the current
      // Landsraad term's goal_amount for every House row — surface the result.
      const lg = out.landsraadGoalApply
      if (lg) {
        if (lg.ok && !lg.skipped && lg.message) {
          msg += ` Landsraad: ${lg.message}`
        } else if (lg.ok && lg.skipped && lg.message) {
          msg += ` Landsraad: ${lg.message}`
        } else if (!lg.ok && lg.error) {
          msg += ` (Landsraad live-goal apply failed: ${lg.error}; INI saved OK, next term will pick it up.)`
        }

      }
      setSavedMsg(msg)
      // Local client files remain available through the explicit client-config
      // tools. Saving authoritative server settings never opens a client prompt.
    } catch (err) {
      setSavedMsg(null)
      setSaveError(err instanceof Error ? err.message : String(err))
    } finally {
      setSaving(false)
    }
  }

  async function onReloadPods() {
    if (dirtyKeys.length > 0 || reloadingPods) return
    const ok = window.confirm(
      'Apply the saved INI files by restarting every running game-server pod one at a time?\n\n'
      + 'Players on each map will disconnect when that map restarts. Database, director, operator, and other infrastructure pods are not touched. Each replacement must become Ready before the next map restarts.',
    )
    if (!ok) return
    setReloadingPods(true)
    setSaveError(null)
    setSavedMsg(null)
    try {
      const out = await reloadGameConfigPods()
      setSavedMsg(out.message)
      await forceRefresh()
    } catch (err) {
      setSavedMsg(null)
      setSaveError(err instanceof Error ? err.message : String(err))
    } finally {
      setReloadingPods(false)
    }
  }

  function resetDirty() {
    setValues(originals)
    setSaveError(null)
    setSavedMsg(null)
  }

  const sourcePresentation = cfg && (
    cfg.source === 'installed'
      ? { className: 'pill-success', title: 'Values from the authoritative installed INI files.', icon: 'CircleCheck' as const, label: 'Authoritative' }
      : cfg.source === 'legacy-live'
        ? { className: 'pill-success', title: 'Values from the live battlegroup INI files on an older Funcom installation.', icon: 'CircleCheck' as const, label: 'Live' }
        : cfg.source === 'live'
          ? { className: 'pill-success', title: 'Values from the live battlegroup INI files.', icon: 'CircleCheck' as const, label: 'Live' }
          : cfg.source === 'cache'
            ? { className: 'pill-info', title: 'Paths cached from a prior request this session.', icon: 'Info' as const, label: 'Cached' }
            : { className: 'pill-warning', title: 'No live battlegroup yet — values from setup templates.', icon: 'AlertTriangle' as const, label: 'Template' }
  )
  const sourcePill = sourcePresentation && (
    <span
      className={sourcePresentation.className}
      title={sourcePresentation.title}
    >
      <Icon name={sourcePresentation.icon} size={12} />
      {sourcePresentation.label}
    </span>
  )

  return (
    <>
      <PageHeader
        title={experimentalPage ? 'Experimental Lab' : 'Game Config'}
        icon={experimentalPage ? 'FlaskConical' : 'Sliders'}
        description={experimentalPage
          ? 'Complete recovered CVar and live default-INI catalog. Curated DST controls are excluded; saved overrides apply on the next DST battlegroup restart.'
          : 'UserGame.ini + UserEngine.ini editor. Edits are tracked in a DST-managed block written to the live battlegroup.'}
        actions={
          <div className="gameconfig-header-actions flex items-center gap-2">
            {sourcePill}
            <button
              type="button"
              onClick={() => void onReloadPods()}
              disabled={!vmRunning || reloadingPods || saving || dirtyKeys.length > 0 || loadState !== 'ready'}
              className="btn-secondary"
              title={dirtyKeys.length > 0
                ? 'Save or discard pending changes first'
                : 'Rebuild the server startup values from the INIs and restart the battlegroup so every map reloads with the current settings'}
            >
              <Icon name={reloadingPods ? 'Loader2' : 'RefreshCw'} size={14} className={reloadingPods ? 'animate-spin' : ''} />
              {reloadingPods ? 'Restarting battlegroup…' : 'Apply INIs & restart'}
            </button>
            {experimentalPage && (
              <Link to="/gameconfig" className="btn-secondary" title="Back to the settings we stand behind">
                <Icon name="Sliders" size={14} /> Game Config
              </Link>
            )}
            <button
              type="button"
              onClick={() => void onBackup()}
              disabled={!vmRunning || backing || saving}
              className="btn-secondary"
              title="Snapshot UserGame.ini + UserEngine.ini on the server before making changes"
            >
              <Icon name={backing ? 'Loader2' : 'DatabaseBackup'} size={14} className={backing ? 'animate-spin' : ''} />
              {backing ? 'Backing up…' : 'Backup settings'}
            </button>
            <button
              type="button"
              onClick={() => void onViewBackups()}
              disabled={!vmRunning}
              className="btn-secondary"
              title="View the most recent on-server backups of these INI files"
            >
              <Icon name="History" size={14} />
              View backups
            </button>
            <button
              type="button"
              onClick={() => void loadAll()}
              disabled={!vmRunning || loadState === 'loading' || saving}
              className="btn-secondary"
              title="Re-fetch values from the VM"
            >
              <Icon name={loadState === 'loading' ? 'Loader2' : 'RefreshCw'} size={14} className={loadState === 'loading' ? 'animate-spin' : ''} />
              Refresh
            </button>
          </div>
        }
      />

      {/* Backup / risk reminder. On the Experimental page this is also the single
          page-level warning — the per-card copy is suppressed there, otherwise it
          would repeat on every themed card. */}
      <Guidance className={'gameconfig-guidance card p-4 mb-4 text-sm flex items-start gap-3 ' + (experimentalPage ? 'border-warning/40 bg-warning/5' : 'border-ibad/40 bg-ibad/5')}>
        {contextual && <summary>
          <strong>Back up before editing. </strong>
          {experimentalPage
            ? 'Recovered controls are unconfirmed: crashes, disconnects, state corruption and performance loss are possible. Change one setting at a time; save, then Apply INIs & restart.'
            : 'Saving writes to the installed authoritative INIs; Apply INIs & restart pushes them to the battlegroup.'}
          <span> Safety &amp; player config</span>
        </summary>}
        <Icon name="FlaskConical" size={18} className={'mt-0.5 shrink-0 ' + (experimentalPage ? 'text-warning' : 'text-ibad')} />
        <div className="flex-1 min-w-0">
          {experimentalPage ? (
            <>
              <p className="text-xs text-text-muted leading-relaxed">
                Experimental Lab exposes recovered Dune and Unreal Engine console variables plus every setting in the live game&apos;s
                default INIs that DST does not already surface. CVar overrides are staged in{' '}
                <span className="font-mono">UserEngine.ini</span>; default-INI overrides keep their original file and section. Descriptions
                are recovered metadata, not proof the shipped build uses a control.{' '}
                <span className="text-text font-medium">Back up first and change one setting at a time.</span>
              </p>
              <p className="text-xs text-warning/90 leading-relaxed mt-1.5">
                Saving here changes nothing on a running server — use “Apply INIs &amp; restart” in the bar at the
                bottom of this page, or the same command on the Commands page. Critical and high-risk controls can crash,
                disconnect, corrupt state, or sharply reduce performance. Client behavior is unknown unless a control is explicitly
                marked Client.
              </p>
            </>
          ) : (
            <>
              <p className="text-xs text-text-muted leading-relaxed">
                Game Config writes directly to your live battlegroup&apos;s <span className="font-mono">UserGame.ini</span> /{' '}
                <span className="font-mono">UserEngine.ini</span>. Values are written into a
                DST-managed block. <span className="text-text font-medium">Always click “Backup settings” before making changes</span> so
                you have a restore point — backups are saved on the server next to each file and can be restored via the File Browser.
              </p>
              <p className="text-xs text-warning/90 leading-relaxed mt-1.5">
                Some settings are read only when a game pod starts. Use “Apply INIs &amp; restart” after saving to do a clean battlegroup restart so every map reloads with the new values.
              </p>
            </>
          )}
          {contextual && !experimentalPage && <p className="text-xs text-text-muted mt-2">
            DST moves the changed setting's entire section into its managed block, preserving structure and one clean copy.
            The original file is backed up on the server before every write.
          </p>}
          <button
            type="button"
            onClick={() => void onBackup()}
            disabled={!vmRunning || backing || saving}
            className="btn-secondary mt-2.5"
            title="Snapshot UserGame.ini + UserEngine.ini on the server before making changes"
          >
            <Icon name={backing ? 'Loader2' : 'DatabaseBackup'} size={14} className={backing ? 'animate-spin' : ''} />
            {backing ? 'Backing up…' : 'Backup settings now'}
          </button>
          <button
            type="button"
            onClick={() => void onViewBackups()}
            disabled={!vmRunning}
            className="btn-secondary mt-2.5 ml-2"
            title="View the most recent on-server backups of these INI files"
          >
            <Icon name="History" size={14} />
            View backups
          </button>
        </div>
      </Guidance>

      {backupMsg && (
        <div className="card p-3 mb-4 border-success/40 bg-success/10 text-success text-sm flex items-center gap-2">
          <Icon name="ShieldCheck" size={14} /> {backupMsg}
        </div>
      )}
      {backupError && (
        <div className="card p-3 mb-4 border-danger/40 bg-danger/10 text-danger text-sm flex items-center gap-2">
          <Icon name="AlertCircle" size={14} /> {backupError}
        </div>
      )}

      {/* Server name (battlegroup title shown in the in-game server browser) */}
      {!experimentalPage && (
      <ServerNameCard
        vmRunning={vmRunning}
        currentName={(status?.serverName ?? '').trim()}
        onRenamed={() => { void forceRefresh() }}
      />
      )}

      {/* How it works. On the Experimental page this is also where the user is
          told to go back to Game Config to apply — that path rebuilds the server
          startup values from the INI, which is what makes these take effect. */}
      {!contextual && (experimentalPage ? (
        <div className="card p-3 mb-4 border-border bg-surface-2/40 text-xs text-text-muted flex items-start gap-2">
          <Icon name="Info" size={14} className="mt-0.5 shrink-0 text-accent-bright" />
          <div>
            These are written to the labeled server <span className="font-mono text-text">UserGame.ini</span> or{' '}
            <span className="font-mono text-text">UserEngine.ini</span> when you save.
            Nothing changes on a running server until the battlegroup restarts — use{' '}
            <strong className="text-text">Apply INIs &amp; restart</strong> in the bar at the bottom of this page, or the same command
            on the Commands page.
          </div>
        </div>
      ) : (
        <div className="card p-3 mb-4 border-border bg-surface-2/40 text-xs text-text-muted flex items-start gap-2">
          <Icon name="Info" size={14} className="mt-0.5 shrink-0 text-accent-bright" />
          <div>
            When you change a setting, DST relocates that setting&apos;s entire section into a managed block at the
            bottom of the file and becomes its owner — keeping one clean copy, preserving structure, and migrating
            any existing managed block. The original file is backed up on the server before every write.
          </div>
        </div>
      ))}

      {cfg && <AdvancedIniBrowser cfg={cfg} />}

      {localViewer && (
        <>
          {/* Local client config (this PC) */}
          <CollapsibleCard
            id="gameconfig.clientConfig"
            icon="MonitorSmartphone"
            iconClassName="text-accent-bright shrink-0"
            title="Optional local client overrides (this PC)"
            titleClassName="text-sm font-semibold text-text"
            className="mb-4 border-border"
            headerClassName="px-4 pt-4 pb-2"
            bodyClassName="px-4 pb-4"
            headerRight={
              <>
                <button
                  type="button"
                  onClick={() => void onOpenInEditor('game')}
                  disabled={clientBusy}
                  className="btn-secondary"
                  title="Open local client Game.ini in Notepad"
                >
                  <Icon name="ExternalLink" size={14} /> Open local Game.ini
                </button>
                <button
                  type="button"
                  onClick={() => void onOpenInEditor('engine')}
                  disabled={clientBusy}
                  className="btn-secondary"
                  title="Open local client Engine.ini in Notepad"
                >
                  <Icon name="ExternalLink" size={14} /> Open local Engine.ini
                </button>
                <button
                  type="button"
                  onClick={() => void onViewClient('game')}
                  className="btn-secondary"
                  title="View local client Game.ini"
                >
                  <Icon name="FileSearch" size={14} /> View local Game.ini
                </button>
                <button
                  type="button"
                  onClick={() => void onViewClient('engine')}
                  className="btn-secondary"
                  title="View local client Engine.ini"
                >
                  <Icon name="FileSearch" size={14} /> View local Engine.ini
                </button>
              </>
            }
          >
            <p className="text-xs text-text-muted mb-3">
              Funcom&apos;s in-game Custom Settings deployment remains authoritative for supported settings. DST can
              optionally mirror a small, field-proven set of advanced Retail values that are still evaluated locally into
              this PC&apos;s <span className="font-mono">Game.ini</span>. Managing{' '}
              <span className="font-mono">Engine.ini</span> is a separate opt-in because client console-variable overrides
              can materially change gameplay.
            </p>
            <label className="mb-3 flex items-start gap-3 rounded-lg border border-warning/30 bg-warning/5 p-3 cursor-pointer select-none">
              <input
                type="checkbox"
                checked={clientInfo?.engineEnabled === true}
                onChange={e => void onToggleClientEngine(e.target.checked)}
                disabled={clientBusy || !clientInfo || (!clientInfo.dirExists && !clientInfo.engineEnabled)}
                className="h-4 w-4 mt-0.5 accent-warning shrink-0"
              />
              <span>
                <span className="block text-sm font-medium text-text">Allow DST to manage my client Engine.ini</span>
                <span className="block text-xs text-text-muted mt-0.5">
                  Off by default. While off, DST does not manage or write Engine.ini. Turning this off removes
                  DST-managed Engine.ini values. Close Dune: Awakening before changing this option.
                </span>
                <span className="block text-xs text-warning mt-1">
                  Multiplayer warning: every player may need compatible Engine.ini values. Use the same value as the server,
                  or an equal/higher local value for client-enforced limits. One player&apos;s local edit does not update anyone else.
                </span>
              </span>
            </label>
            <div className="mb-3 rounded-lg border border-border bg-surface-2/40 p-3 text-xs text-text-muted">
              <strong className="text-text">Review compatibility overrides from the action bar below.</strong>{' '}
              Only customized, non-default advanced settings outside Funcom&apos;s normal synchronized surface and backed
              by direct current-Retail evidence are offered. Game.ini values can apply without the Engine.ini opt-in.
              {clientApplyItems.some(item => item.file === 'engine') && clientInfo?.engineEnabled !== true
                ? ' Enable Engine.ini management here to include shield, vehicle-cap, and other proven client-read CVars.'
                : ' Engine.ini values are included only while Engine.ini management is enabled.'}
            </div>
            {clientInfo?.legacyMigration?.available && (
              <div className="mb-3 rounded-lg border border-warning/30 bg-warning/5 p-3 text-xs text-text-muted">
                <strong className="text-text">Retail moved its active client config from WindowsClient to Windows.</strong>{' '}
                DST found the former folder and can review only recognized, non-default settings with direct current-Retail
                evidence of local client evaluation. It never copies whole files or unrelated account, UI, session, or unknown
                settings. Missing destination values are preselected; conflicts require an explicit selection.
                <div className="mt-2 font-mono break-all text-[11px] text-text-dim">
                  {clientInfo.legacyMigration.sourceDir} → {clientInfo.legacyMigration.destinationDir}
                </div>
                <div className="mt-2 flex flex-wrap items-center gap-2">
                  <button
                    type="button"
                    onClick={() => setClientReview({ mode: 'legacy', items: legacyMigrationItems.map(item => ({ ...item })) })}
                    disabled={clientBusy || legacyMigrationItems.length === 0}
                    className="btn-secondary"
                    title={legacyMigrationItems.length === 0
                      ? 'No eligible WindowsClient values need review'
                      : 'Review recognized WindowsClient values before writing the active Windows config'}
                  >
                    <Icon name="FolderSync" size={14} /> Review WindowsClient migration
                  </button>
                  <span>
                    {clientInfo.legacyMigration.alreadyCurrentCount ?? 0} already current
                    {' • '}{clientInfo.legacyMigration.conflictCount ?? 0} conflict{clientInfo.legacyMigration.conflictCount === 1 ? '' : 's'}
                    {' • '}{clientInfo.legacyMigration.excludedRecognized.length} recognized setting{clientInfo.legacyMigration.excludedRecognized.length === 1 ? '' : 's'} excluded without current evidence
                  </span>
                </div>
                {clientInfo.legacyMigration.candidates.some(item => item.file === 'engine' && item.state !== 'current')
                  && clientInfo.engineEnabled !== true && (
                    <div className="mt-2 text-warning">
                      Enable Engine.ini management above to review eligible legacy Engine.ini values.
                    </div>
                  )}
              </div>
            )}
            <div className="flex items-center gap-2">
              <input
                type="text"
                value={clientDirInput}
                onChange={e => setClientDirInput(e.target.value)}
                spellCheck={false}
                placeholder={clientInfo?.default ?? '%LOCALAPPDATA%\\DuneSandbox\\Saved\\Config\\Windows'}
                className="flex-1 min-w-0 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm font-mono placeholder:text-text-dim focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
              />
              <button type="button" onClick={() => void onBrowseClientDir()} disabled={clientBusy} className="btn-secondary shrink-0">
                <Icon name={clientBusy ? 'Loader2' : 'FolderOpen'} size={14} className={clientBusy ? 'animate-spin' : ''} /> Browse
              </button>
              <button
                type="button"
                onClick={() => void onSaveClientDir()}
                disabled={clientBusy || !clientDirInput.trim() || clientDirInput.trim() === (clientInfo?.dir ?? '')}
                className="btn-primary shrink-0"
              >
                <Icon name="Save" size={14} /> Save
              </button>
            </div>
            {clientInfo && (
              <div className="text-[11px] text-text-dim mt-2 font-mono break-all space-y-0.5">
                {(['game', 'engine'] as const).map(file => {
                  const bundle = clientBundleFor(clientInfo, file)
                  return (
                    <div key={file}>
                      {bundle.path}{' '}
                      {file === 'engine' && !clientInfo.engineEnabled && <span className="text-text-dim">• management disabled </span>}
                      {bundle.exists
                        ? <span className="text-success">• found</span>
                        : clientInfo.dirExists
                          ? <span className="text-warning">• not present yet (will be created on apply)</span>
                          : <span className="text-danger">• folder not found</span>}
                    </div>
                  )
                })}
              </div>
            )}
          </CollapsibleCard>
          {clientMsg && (
            <div className="card p-3 mb-4 border-success/40 bg-success/10 text-success text-sm flex items-center gap-2">
              <Icon name="CheckCircle2" size={14} /> {clientMsg}
            </div>
          )}
          {clientErr && (
            <div className="card p-3 mb-4 border-danger/40 bg-danger/10 text-danger text-sm flex items-center gap-2">
              <Icon name="AlertCircle" size={14} /> {clientErr}
            </div>
          )}
        </>
      )}

      {/* Status / error banners */}
      {loadState === 'unavailable' && (
        <div className="card p-4 mb-4 border-accent/30 bg-accent/5 text-text-muted text-sm flex items-start gap-2">
          <Icon name="Info" size={16} className="mt-0.5 shrink-0 text-accent-bright" />
          <div>
            <div className="font-medium text-text">{loadError ?? 'Showing Funcom defaults.'}</div>
            <div className="text-xs text-text-muted mt-0.5">Every setting below shows its default value. Editing and saving are enabled once the battlegroup is running.</div>
          </div>
        </div>
      )}
      {loadState === 'error' && loadError && (
        <div className="card p-4 mb-4 border-danger/40 bg-danger/10 text-danger text-sm flex items-center justify-between gap-2">
          <span className="flex items-center gap-2"><Icon name="AlertCircle" size={14} /> {loadError}</span>
          <button
            type="button"
            onClick={() => void loadAll()}
            className="px-3 py-1 rounded bg-danger/20 hover:bg-danger/30 text-danger text-xs font-medium"
          >
            Retry
          </button>
        </div>
      )}
      {saveError ? (
        <ViewportNotice kind="err" text={saveError} onDismiss={() => setSaveError(null)} />
      ) : savedMsg ? (
        <ViewportNotice kind="ok" text={savedMsg} onDismiss={() => setSavedMsg(null)} />
      ) : null}
      {!schema && loadState === 'loading' && (
        <div className="card p-8 text-text-muted flex items-center gap-2">
          <Icon name="Loader2" size={14} className="animate-spin" /> Loading schema…
        </div>
      )}

      {schema && (
        <form onSubmit={onSubmit}>
          {/* Search */}
          <div className="relative mb-4">
            <Icon name="Search" size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-text-dim" />
            <input
              type="text"
              value={search}
              onChange={e => setSearch(e.target.value)}
              placeholder={experimentalPage ? 'Search all Experimental Lab settings…' : 'Filter settings…'}
              className="w-full pl-9 pr-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm placeholder:text-text-dim focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
            />
          </div>

          {experimentalPage && (
            <div className="mb-4 flex flex-wrap items-center gap-2">
              <select
                value={selectedExperimentalGroup}
                onChange={e => setExperimentalGroup(e.target.value)}
                className="min-w-52 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-xs"
                aria-label="Experimental category"
              >
                {experimentalGroups.map(group => (
                  <option key={group.name} value={group.name}>
                    {group.name} ({group.count.toLocaleString()})
                  </option>
                ))}
              </select>
              <select
                value={experimentalSource}
                onChange={e => setExperimentalSource(e.target.value as typeof experimentalSource)}
                className="px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-xs"
                aria-label="CVar source"
              >
                <option value="all">All sources</option>
                <option value="Dune">Dune gameplay</option>
                <option value="Engine">Unreal Engine</option>
              </select>
              <select
                value={experimentalRisk}
                onChange={e => setExperimentalRisk(e.target.value as typeof experimentalRisk)}
                className="px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-xs"
                aria-label="Risk level"
              >
                <option value="all">All risk levels</option>
                <option value="experimental">Experimental</option>
                <option value="diagnostic">Diagnostic</option>
                <option value="high">High risk</option>
                <option value="critical">Critical</option>
              </select>
              <label className="inline-flex items-center gap-2 px-3 py-2 rounded-lg bg-surface-2 border border-border text-xs text-text-muted">
                <input
                  type="checkbox"
                  checked={experimentalModifiedOnly}
                  onChange={e => setExperimentalModifiedOnly(e.target.checked)}
                />
                Modified only
              </label>
              <span className="text-xs text-text-dim ml-auto">
                {experimentalSearchActive && experimentalSearchLoading
                  ? 'Searching all categories...'
                  : !experimentalSearchActive && experimentalCategoryLoading === selectedExperimentalGroup
                    ? 'Loading category...'
                    : `${experimentalFilteredFields.length.toLocaleString()} recovered controls${experimentalSearchActive ? ' across all categories' : ''}`}
              </span>
            </div>
          )}
          {experimentalPage && (experimentalSearchActive ? experimentalSearchError : experimentalCategoryError) && (
            <div className="mb-4 text-xs text-danger">
              {experimentalSearchActive ? experimentalSearchError : experimentalCategoryError}
            </div>
          )}

          <div className="space-y-5">
            {(filteredSchema ?? []).map(cat => {
              // On the Experimental page a "category" is a theme built from
              // fields across both schema categories, so share blocks come from
              // the visible fields rather than a matching schema entry.
              const fullCat = experimentalPage
                ? (visibleSchema?.find(c => c.category === cat.category) ?? cat)
                : (schema?.find(c => c.category === cat.category) ?? cat)
              const share = buildCategoryClientBlocks(fullCat, cfg)
              return (
              <CategoryCard
                key={cat.category}
                category={cat.category}
                count={experimentalPage ? experimentalFilteredFields.length : (cat.fields ?? []).length}
                clientBlock={share.count > 0 ? 'available' : ''}
                hasClientFields={share.hasClientFields}
                onShare={() => setShareBlock({ title: `${cat.category} — give players this`, entries: share.entries })}
                forceOpen={experimentalPage || search.trim() !== ''}
                isExperimental={experimentalPage}
              >
                <div className="grid grid-cols-1 md:grid-cols-2 gap-x-6 gap-y-4">
                  {(cat.fields ?? []).map(f => (
                    f && f.key ? (
                      <FieldRow
                        key={`${f.section}||${f.key}`}
                        field={f}
                        value={values[f.key] ?? ''}
                        onChange={v => handleFieldChange(f.key, v)}
                        disabled={loadState !== 'ready' || saving}
                        isDirty={(values[f.key] ?? '') !== (originals[f.key] ?? '')}
                        isSet={liveValue(cfg, f) !== ''}
                        isCustom={isCustomized(cfg, f)}
                        defaultValue={fieldDefault(f)}
                        managed={cfg ? sectionIsManaged(cfg, f) : false}
                        fixedHeight={experimentalPage}
                      />
                    ) : null
                  ))}
                  {experimentalPage && experimentalFilteredFields.length > EXPERIMENTAL_PAGE_SIZE && (cat.fields ?? []).length > 0 && Array.from({
                    length: EXPERIMENTAL_PAGE_SIZE - (cat.fields ?? []).length,
                  }).map((_, index) => (
                    <div key={`empty-slot-${index}`} className="h-32 invisible" aria-hidden="true" />
                  ))}
                  {experimentalPage && (cat.fields ?? []).length === 0 && !experimentalSearchLoading && experimentalCategoryLoading !== selectedExperimentalGroup && (
                    <div className="md:col-span-2 text-sm text-text-muted">No recovered controls match these filters.</div>
                  )}
                </div>
                {experimentalPage && experimentalFilteredFields.length > EXPERIMENTAL_PAGE_SIZE && (
                  <div className="mt-5 pt-3 border-t border-border flex items-center justify-between gap-3">
                    <button
                      type="button"
                      className="btn-secondary"
                      disabled={experimentalPageIndex === 0}
                      onClick={() => setExperimentalPageIndex(i => Math.max(0, i - 1))}
                    >
                      Previous
                    </button>
                    <span className="text-xs text-text-muted">
                      Page {experimentalPageIndex + 1} of {Math.ceil(experimentalFilteredFields.length / EXPERIMENTAL_PAGE_SIZE)}
                    </span>
                    <button
                      type="button"
                      className="btn-secondary"
                      disabled={(experimentalPageIndex + 1) * EXPERIMENTAL_PAGE_SIZE >= experimentalFilteredFields.length}
                      onClick={() => setExperimentalPageIndex(i => i + 1)}
                    >
                      Next
                    </button>
                  </div>
                )}
                {/* Not an INI field, but it belongs with the base backup
                    settings: allowing the tool in the Deep Desert without this
                    means a stored base is recyclable-only after every reset. */}
                {!experimentalPage && cat.category === 'BaseBackUp' && (
                  <BaseBackupGuardPanel vmRunning={vmRunning} />
                )}
                {!experimentalPage && cat.category === 'Time of Day' && (
                  <TimeOfDayLockPanel vmRunning={vmRunning} />
                )}
              </CategoryCard>
              )
            })}
            {filteredSchema && filteredSchema.length === 0 && (
              <div className="card p-6 text-text-muted text-sm">No settings match “{search}”.</div>
            )}

            {!experimentalPage && (
              <>
                <SpicefieldsCard vmRunning={vmRunning} />

                <DeepDesertPvpCard vmRunning={vmRunning} />

                <LandclaimTimerCard vmRunning={vmRunning} />

              </>
            )}
            {experimentalPage && (
              <DefaultsCatalogBrowser
                vmRunning={vmRunning}
                onSaved={() => void loadAll()}
                excludedTargets={surfacedIniTargets}
              />
            )}
          </div>

          <div className="gameconfig-savebar sticky bottom-0 mt-6 -mx-6 px-6 py-3 bg-surface/95 border-t border-border backdrop-blur-sm flex items-center justify-between">
            <div className="text-xs text-text-muted flex items-center gap-4">
              {cfg && (
                <>
                  <span className="font-mono truncate max-w-xs" title={cfg.game.path}>game: {cfg.game.path}</span>
                  <span className="font-mono truncate max-w-xs" title={cfg.engine.path}>engine: {cfg.engine.path}</span>
                </>
              )}
            </div>
            <div className="flex flex-wrap items-center justify-end gap-2">
              <button
                type="button"
                onClick={e => scrollPageToTop(e.currentTarget)}
                className="btn-secondary"
                title="Scroll back to the top of the page"
              >
                <Icon name="ArrowUp" size={14} /> Top
              </button>
              <button
                type="button"
                onClick={() => void onReloadPods()}
                disabled={!vmRunning || reloadingPods || saving || dirtyKeys.length > 0 || loadState !== 'ready'}
                className="btn-secondary"
                title={dirtyKeys.length > 0
                  ? 'Save or discard pending changes first'
                  : 'Rebuild the server startup values from the INIs and restart the battlegroup so every map reloads with the current settings'}
              >
                <Icon name={reloadingPods ? 'Loader2' : 'RefreshCw'} size={14} className={reloadingPods ? 'animate-spin' : ''} />
                {reloadingPods ? 'Restarting battlegroup…' : 'Apply INIs & restart'}
              </button>
              {localViewer && (
                <button
                  type="button"
                  onClick={() => setClientReview({ mode: 'server', items: enabledClientApplyItems.map(item => ({ ...item })) })}
                  disabled={clientBusy || enabledClientApplyItems.length === 0}
                  className="btn-primary"
                  title={enabledClientApplyItems.length === 0
                    ? 'No customized field-proven advanced compatibility overrides are available'
                    : 'Review advanced compatibility overrides before writing this PC’s local Dune config'}
                >
                  <Icon name={clientBusy ? 'Loader2' : 'MonitorCog'} size={14} className={clientBusy ? 'animate-spin' : ''} />
                  Apply advanced compatibility overrides
                </button>
              )}
              <span className="text-xs text-text-muted">
                {dirtyKeys.length === 0 ? 'No changes' : `${dirtyKeys.length} change${dirtyKeys.length === 1 ? '' : 's'}`}
              </span>
              <button
                type="button"
                onClick={resetDirty}
                disabled={dirtyKeys.length === 0 || saving}
                className="btn-secondary"
              >
                <Icon name="Undo2" size={14} /> Discard
              </button>
              <button
                type="submit"
                disabled={dirtyKeys.length === 0 || saving || loadState !== 'ready'}
                className="btn-primary"
              >
                <Icon name={saving ? 'Loader2' : 'Save'} size={15} className={saving ? 'animate-spin' : ''} />
                {saving ? 'Saving…' : 'Save'}
              </button>
            </div>
          </div>
        </form>
      )}

      <SandwormConfirmModal
        open={sandwormModalOpen}
        onCancel={() => setSandwormModalOpen(false)}
        onConfirm={confirmSandwormEnable}
      />

      {clientReview && (
        <ClientApplyReviewModal
          items={clientReview.items}
          mode={clientReview.mode}
          busy={clientBusy}
          onCancel={() => setClientReview(null)}
          onConfirm={reviewedItems => void onApplyCurrentClientSettings(reviewedItems)}
        />
      )}

      {shareBlock && (
        <IniShareModal
          title={shareBlock.title}
          entries={shareBlock.entries}
          subtitle={shareBlock.subtitle ?? 'Players connecting to your server should add each block to the matching local client INI file.'}
          onClose={() => setShareBlock(null)}
        />
      )}

      {backupsOpen && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
          onClick={() => setBackupsOpen(false)}
        >
          <div
            className="card w-full max-w-2xl max-h-[80vh] flex flex-col p-0 overflow-hidden"
            onClick={e => e.stopPropagation()}
          >
            <div className="flex items-center justify-between px-5 py-3 border-b border-border">
              <h2 className="text-sm font-semibold text-text flex items-center gap-2">
                <Icon name="History" size={16} className="text-accent-bright" />
                Recent backups
              </h2>
              <button type="button" className="btn-icon" title="Close" onClick={() => setBackupsOpen(false)}>
                <Icon name="X" size={16} />
              </button>
            </div>
            <div className="px-5 py-4 overflow-y-auto">
              <p className="text-xs text-text-muted mb-3">
                On-server snapshots of <span className="font-mono">UserGame.ini</span> /{' '}
                <span className="font-mono">UserEngine.ini</span> (saved as{' '}
                <span className="font-mono">.dstbak-&lt;timestamp&gt;</span>). To restore one, open it in the File Browser
                and copy it back over the installed authoritative file.
              </p>
              {backupsLoading && (
                <div className="flex items-center gap-2 text-sm text-text-muted py-6 justify-center">
                  <Icon name="Loader2" size={16} className="animate-spin" /> Loading backups…
                </div>
              )}
              {!backupsLoading && backupsError && (
                <div className="card p-3 border-danger/40 bg-danger/10 text-danger text-sm flex items-center gap-2">
                  <Icon name="AlertCircle" size={14} /> {backupsError}
                </div>
              )}
              {!backupsLoading && !backupsError && backups.length === 0 && (
                <div className="text-sm text-text-muted py-6 text-center">
                  No backups found yet. Click “Backup settings” to create your first restore point.
                </div>
              )}
              {!backupsLoading && !backupsError && backups.length > 0 && (
                <div className="space-y-1.5">
                  <div className="flex items-center justify-between px-1 pb-1 text-[11px] text-text-dim">
                    <button type="button" className="hover:text-text"
                      onClick={() => setBackupSel(backupSel.size === backups.length ? new Set() : new Set(backups.map(b => b.path)))}>
                      {backupSel.size === backups.length ? 'Clear all' : 'Select all'}
                    </button>
                    <span>{backupSel.size} selected</span>
                  </div>
                  {backups.map(b => {
                    const checked = backupSel.has(b.path)
                    return (
                      <label key={b.path} className={`flex items-center gap-3 rounded border px-3 py-2 cursor-pointer ${checked ? 'border-danger/50 bg-danger/5' : 'border-border bg-surface-2/40 hover:bg-surface-3/30'}`}>
                        <input type="checkbox" checked={checked} onChange={() => toggleBackupSel(b.path)} disabled={backupDeleting}
                          className="shrink-0 accent-danger" />
                        <Icon name="FileCog" size={14} className="shrink-0 text-text-dim" />
                        <div className="min-w-0 flex-1">
                          <div className="text-sm text-text truncate" title={b.path}>{b.name}</div>
                          <div className="text-[11px] text-text-dim truncate" title={b.dir}>{b.dir}</div>
                        </div>
                        <div className="text-right shrink-0">
                          <div className="text-xs text-text-muted">{formatBackupStamp(b)}</div>
                          <div className="text-[11px] text-text-dim">{formatBytes(b.size)}</div>
                        </div>
                      </label>
                    )
                  })}
                </div>
              )}
            </div>
            <div className="px-5 py-3 border-t border-border flex items-center justify-between gap-2">
              <button
                type="button"
                onClick={() => void onViewBackups()}
                disabled={backupsLoading || backupDeleting}
                className="btn-secondary"
                title="Reload the backup list"
              >
                <Icon name={backupsLoading ? 'Loader2' : 'RefreshCw'} size={14} className={backupsLoading ? 'animate-spin' : ''} />
                Refresh
              </button>
              <div className="flex items-center gap-2">
                <button
                  type="button"
                  className="btn-danger"
                  disabled={backupSel.size === 0 || backupDeleting}
                  onClick={() => void onDeleteSelectedBackups()}
                  title="Permanently delete the selected backup files from the server"
                >
                  <Icon name={backupDeleting ? 'Loader2' : 'Trash2'} size={14} className={backupDeleting ? 'animate-spin' : ''} />
                  {backupDeleting ? 'Deleting…' : `Delete${backupSel.size > 0 ? ` (${backupSel.size})` : ''}`}
                </button>
                <button type="button" className="btn-primary" onClick={() => setBackupsOpen(false)}>Close</button>
              </div>
            </div>
          </div>
        </div>
      )}

      {clientViewFile && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
          onClick={() => setClientViewFile(null)}
        >
          <div
            className="card w-full max-w-3xl max-h-[85vh] flex flex-col p-0 overflow-hidden"
            onClick={e => e.stopPropagation()}
          >
            <div className="flex items-center justify-between px-5 py-3 border-b border-border">
              <h2 className="text-sm font-semibold text-text flex items-center gap-2">
                <Icon name="MonitorSmartphone" size={16} className="text-accent-bright" />
                Your client {clientViewFile === 'engine' ? 'Engine.ini' : 'Game.ini'}
              </h2>
              <button type="button" className="btn-icon" title="Close" onClick={() => setClientViewFile(null)}>
                <Icon name="X" size={16} />
              </button>
            </div>
            <div className="px-5 py-4 overflow-y-auto">
              <div className="text-[11px] text-text-dim font-mono break-all mb-3">
                {clientInfo ? clientBundleFor(clientInfo, clientViewFile).path : CLIENT_INI_PATHS[clientViewFile]}{' '}
                {clientInfo && clientBundleFor(clientInfo, clientViewFile).exists
                  ? <span className="text-success">• found</span>
                  : <span className="text-warning">• not present yet</span>}
              </div>
              {(!clientInfo || !clientBundleFor(clientInfo, clientViewFile).exists) && (
                <div className="text-sm text-text-muted py-4 text-center">
                  No client <span className="font-mono">{clientViewFile === 'engine' ? 'Engine.ini' : 'Game.ini'}</span> at this location yet. It will be created the
                  first time you apply a client-side setting.
                </div>
              )}
              {clientInfo && clientBundleFor(clientInfo, clientViewFile).exists && (
                <pre className="text-xs font-mono text-text bg-base border border-border rounded-lg p-3 overflow-x-auto max-h-[60vh] overflow-y-auto whitespace-pre leading-relaxed">
                  {clientBundleFor(clientInfo, clientViewFile).raw || '(empty file)'}
                </pre>
              )}
            </div>
            <div className="px-5 py-3 border-t border-border flex items-center justify-between gap-2">
              <span className="text-[11px] text-text-dim">Read-only preview. “Open in Notepad” edits the real file.</span>
              <div className="flex items-center gap-2">
                <button type="button" onClick={() => void onOpenInEditor(clientViewFile)} disabled={clientBusy} className="btn-secondary" title="Open this file in Notepad">
                  <Icon name="ExternalLink" size={14} /> Open in Notepad
                </button>
                <button type="button" onClick={() => void refreshClient()} className="btn-secondary" title="Reload">
                  <Icon name="RefreshCw" size={14} /> Refresh
                </button>
                <button type="button" className="btn-primary" onClick={() => setClientViewFile(null)}>Close</button>
              </div>
            </div>
          </div>
        </div>
      )}
    </>
  )
}

// Render a backup's timestamp. Prefer the embedded yyyyMMddHHmmss stamp; fall
// back to the file's mtime (epoch seconds).
function formatBackupStamp(b: GameConfigBackupEntry): string {
  const s = b.stamp
  if (s && /^\d{14}$/.test(s)) {
    const d = new Date(
      Number(s.slice(0, 4)),
      Number(s.slice(4, 6)) - 1,
      Number(s.slice(6, 8)),
      Number(s.slice(8, 10)),
      Number(s.slice(10, 12)),
      Number(s.slice(12, 14)),
    )
    if (!Number.isNaN(d.getTime())) return d.toLocaleString()
  }
  if (b.modified > 0) return new Date(b.modified * 1000).toLocaleString()
  return '—'
}

function formatBytes(n: number): string {
  if (!n || n < 1024) return `${n || 0} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / (1024 * 1024)).toFixed(1)} MB`
}

// -----------------------------------------------------------------------------
// Category card + field row
// -----------------------------------------------------------------------------

function CategoryCard({
  category,
  count,
  clientBlock,
  hasClientFields,
  onShare,
  forceOpen = false,
  isExperimental,
  children,
}: {
  category: string
  count: number
  clientBlock?: string
  hasClientFields?: boolean
  onShare?: () => void
  forceOpen?: boolean
  /** Set on the Experimental page, where card titles are themes rather than schema categories. */
  isExperimental?: boolean
  children: React.ReactNode
}) {
  const experimental = isExperimental ?? isExperimentalCategory(category)
  // Every category can be rolled up for aesthetics; the choice persists per
  // category. The Experimental lists stay closed by default because they are
  // long and unconfirmed; the rest start open.
  const { open: userOpen, toggle } = useCardCollapse(`gameconfig.category.${category}`, !experimental)
  const expanded = forceOpen || userOpen

  return (
    <div
      className={'card p-5 ' + (experimental ? 'border-warning/40' : '')}
      data-section-nav-id={`gameconfig.category.${category}`}
      data-section-nav-label={category}
    >
      <div className={(expanded ? 'mb-4 ' : '') + 'flex items-center justify-between gap-2'}>
        <button
          type="button"
          className="flex items-center gap-2 text-left min-w-0"
          onClick={toggle}
          aria-expanded={expanded}
          data-section-nav-toggle
        >
          <Icon
            name={expanded ? 'ChevronDown' : 'ChevronRight'}
            size={14}
            className={experimental ? 'text-warning' : 'text-accent-bright'}
          />
          <span
            className={
              'text-sm font-semibold uppercase tracking-wider ' +
              (experimental ? 'text-warning' : 'text-accent-bright')
            }
          >
            {category}
          </span>
          <span className="text-[10px] font-normal text-text-dim normal-case tracking-normal">({count})</span>
        </button>

        {clientBlock ? (
          <button
            type="button"
            className="btn-secondary text-xs py-1 shrink-0"
            onClick={onShare}
            title="Copy this section's client-side INI blocks to hand to players"
          >
            <Icon name="Share2" size={13} /> Give players this
          </button>
        ) : hasClientFields ? (
          <span
            className="text-[10px] text-text-dim flex items-center gap-1 shrink-0 normal-case"
            title="This section has client-side settings, but none are customised yet — nothing to hand out"
          >
            <Icon name="Minus" size={12} /> No custom client settings
          </span>
        ) : null}
      </div>
      {expanded && (
        <>
          {experimental && !isExperimental && (
            <div className="mb-4 rounded-lg border border-warning/35 bg-warning/10 p-3 text-xs text-text-muted">
              <div className="mb-1 flex items-center gap-2 font-semibold text-warning">
                <Icon name="FlaskConical" size={14} /> Test settings
              </div>
              <p>
                These CVars are written to the battlegroup&apos;s <span className="font-mono text-text">UserEngine.ini</span> under <span className="font-mono text-text">[ConsoleVariables]</span>. Saving changes nothing on a running server: the values are applied to the game servers when the battlegroup restarts, so use <strong className="text-text">Apply INIs &amp; restart</strong> to put them into effect. The explicit client-config tools remain available for optional local edits.
              </p>
              <p className="mt-1.5">
                Experimental Lab includes recovered Dune and Unreal Engine controls that are not already surfaced by DST. Risk badges identify known crash, persistence, networking, performance, and diagnostic hazards; they do not make lower-risk controls field-confirmed. Back up first and change one setting at a time.
              </p>
            </div>
          )}
          {children}
        </>
      )}
    </div>
  )
}

type FieldRowProps = {
  field: GameConfigField
  value: string
  onChange: (v: string) => void
  disabled: boolean
  isDirty: boolean
  isSet: boolean
  isCustom: boolean
  defaultValue: string
  managed: boolean
  fixedHeight?: boolean
}

// Human-friendly rendering of a raw default value for the grayed "Default:" line.
function formatDefaultDisplay(field: GameConfigField, def: string): string {
  if (def === '') return '(unset)'
  if (field.key === CORIOLIS_CYCLE_START_HOUR_KEY) {
    const hour = Number(def)
    if (Number.isInteger(hour) && hour >= 0 && hour <= 23) {
      return formatCoriolisCycleStartHour(hour, new Date().getTimezoneOffset())
    }
  }
  if (field.type === 'select' && field.options) {
    const opt = field.options.find(o => o.value === def)
    return opt ? opt.label : def
  }
  const pair = boolPair(field.type)
  if (pair) return def === pair.on ? 'On' : def === pair.off ? 'Off' : def
  return def
}

export function formatCoriolisCycleStartHour(utcHour: number, timezoneOffsetMinutes: number): string {
  const localMinutes = ((utcHour * 60 - timezoneOffsetMinutes) % 1440 + 1440) % 1440
  const localHour = Math.floor(localMinutes / 60)
  const localMinute = localMinutes % 60
  const suffix = localHour >= 12 ? 'PM' : 'AM'
  const displayHour = localHour % 12 || 12
  const utc = `${String(utcHour).padStart(2, '0')}:00`
  return `${displayHour}:${String(localMinute).padStart(2, '0')} ${suffix} local (${utc} GMT/UTC)`
}

function FieldRow({ field, value, onChange, disabled, isDirty, isSet, isCustom, defaultValue, managed, fixedHeight = false }: FieldRowProps) {
  const inputBase =
    'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm ' +
    'placeholder:text-text-dim focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50 ' +
    'disabled:opacity-50 disabled:cursor-not-allowed'

  const pair = boolPair(field.type)
  const isNumber = field.type === 'int' || field.type === 'float'
  const isCoriolisCycleStart = field.key === CORIOLIS_CYCLE_START_HOUR_KEY
  const wide = field.wide

  // Whether the current input already equals the Funcom default (numeric/bool
  // aware), so the reset button can be disabled when there's nothing to reset.
  const atDefault = valuesEqual(value, defaultValue)
  const resetToDefault = () => { if (!disabled && !atDefault) onChange(defaultValue) }

  return (
    <div className={fixedHeight ? 'h-32 overflow-hidden' : wide ? 'md:col-span-2' : ''}>
      <label className="flex items-center justify-between text-sm font-medium mb-1.5 gap-2">
        <span className="flex items-center gap-2 min-w-0">
          <span className="truncate">{field.label}</span>
          {isDirty && <span className="w-1.5 h-1.5 rounded-full bg-ibad shrink-0" title="Modified" />}
        </span>
        <span className="flex items-center gap-1 shrink-0">
          <button
            type="button"
            onClick={resetToDefault}
            disabled={disabled || atDefault}
            title={atDefault ? 'Already at the Funcom default' : `Reset to default (${formatDefaultDisplay(field, defaultValue)}) — removes the key from the INI on save`}
            className="text-[9px] font-semibold uppercase tracking-wider px-1.5 py-0.5 rounded bg-surface-2 text-text-muted hover:text-text hover:bg-surface-3 disabled:opacity-40 disabled:cursor-not-allowed inline-flex items-center gap-1"
          >
            <Icon name="RotateCcw" size={10} /> Default
          </button>
          {managed && (
            <span className="text-[9px] font-semibold uppercase tracking-wider px-1.5 py-0.5 rounded bg-accent/15 text-accent-bright" title="DST owns this section in the managed block">
              DST
            </span>
          )}
          {field.consoleVar && (
            <span className="text-[9px] font-semibold uppercase tracking-wider px-1.5 py-0.5 rounded bg-surface-2 text-text-muted" title="Console variable — saving alone changes nothing on a running server. It takes effect when the battlegroup restarts and rebuilds its startup command: use “Apply INIs & restart” in the bar at the bottom of this page. DST also offers to mirror console variables into this PC’s client Engine.ini; some are client-enforced and need every player to carry a matching value.">
              CVar
            </span>
          )}
          {field.source && (
            <span className="text-[9px] font-semibold uppercase tracking-wider px-1.5 py-0.5 rounded bg-surface-2 text-text-muted" title={`${field.source} catalog; scope: ${field.scope ?? 'Unknown'}`}>
              {field.source}
            </span>
          )}
          {field.risk && field.risk !== 'experimental' && (
            <span className={
              'text-[9px] font-semibold uppercase tracking-wider px-1.5 py-0.5 rounded ' +
              (field.risk === 'critical'
                ? 'bg-danger/20 text-danger'
                : field.risk === 'high'
                  ? 'bg-warning/20 text-warning'
                  : 'bg-surface-2 text-text-dim')
            } title={`${field.risk} risk; behavior is not validated`}>
              {field.risk}
            </span>
          )}
          {field.clientApply && !field.consoleVar && (
            <span className="text-[9px] font-semibold uppercase tracking-wider px-1.5 py-0.5 rounded bg-surface-2 text-text-muted" title="Client-enforced — each player also needs a matching (or equal/higher) value in their own client INI before this takes full effect. Use “Player config” to get the exact lines to hand out.">
              Client
            </span>
          )}
          {isCustom ? (
            <span className="text-[9px] font-semibold uppercase tracking-wider px-1.5 py-0.5 rounded bg-ibad/15 text-ibad" title="This value overrides the Funcom default">
              Custom
            </span>
          ) : isSet && !managed ? (
            <span className="text-[9px] font-semibold uppercase tracking-wider px-1.5 py-0.5 rounded bg-surface-2 text-text-muted" title="Currently set in the file (matches default)">
              Set
            </span>
          ) : (
            <span className="text-[9px] font-semibold uppercase tracking-wider px-1.5 py-0.5 rounded bg-surface-2 text-text-dim" title="Using the Funcom default value">
              Default
            </span>
          )}
          <span className="text-[10px] font-mono text-text-dim uppercase tracking-wider">{field.file}</span>
        </span>
      </label>

      {/* When this field overrides the default, show the uneditable default beneath the name. */}
      {isCustom && (
        <div className="mb-1.5 text-[11px] text-text-dim flex items-center gap-1.5" title="Funcom default — read-only">
          <Icon name="CornerDownRight" size={11} className="shrink-0 opacity-60" />
          <span>Default:</span>
          <span className="font-mono">{formatDefaultDisplay(field, defaultValue)}</span>
        </div>
      )}

      {isCoriolisCycleStart ? (
        <select value={value} disabled={disabled} onChange={e => onChange(e.target.value)} className={inputBase}>
          <option value="">(unset)</option>
          {Array.from({ length: 24 }, (_, utcHour) => (
            <option key={utcHour} value={String(utcHour)}>
              {formatCoriolisCycleStartHour(utcHour, new Date().getTimezoneOffset())}
            </option>
          ))}
        </select>
      ) : field.type === 'select' && field.options ? (
        <select value={value} disabled={disabled} onChange={e => onChange(e.target.value)} className={inputBase}>
          <option value="">(unset)</option>
          {(field.options ?? []).filter(o => o && typeof o.value === 'string').map(o => (
            <option key={o.value} value={o.value}>{o.label ?? o.value}</option>
          ))}
        </select>
      ) : pair ? (
        <BoolToggle on={pair.on} off={pair.off} value={value} disabled={disabled} onChange={onChange} />
      ) : isNumber ? (
        <div className="flex items-center gap-2">
          <input
            type="number"
            value={value}
            disabled={disabled}
            placeholder={field.placeholder ?? ''}
            step={field.type === 'float' ? 'any' : 1}
            min={field.min ?? undefined}
            max={field.max ?? undefined}
            onChange={e => onChange(e.target.value)}
            className={inputBase + ' font-mono'}
          />
          {field.unit && <span className="text-xs text-text-muted shrink-0">{field.unit}</span>}
        </div>
      ) : (
        <input
          type="text"
          value={value}
          disabled={disabled}
          placeholder={field.placeholder ?? ''}
          onChange={e => onChange(e.target.value)}
          className={inputBase + ' font-mono'}
        />
      )}

      <div className="mt-1 flex items-center justify-between gap-2">
        {field.help && <p className={fixedHeight ? 'text-xs text-text-dim line-clamp-2' : 'text-xs text-text-dim'} title={fixedHeight ? field.help : undefined}>{field.help}</p>}
        {field.label !== field.key && (
          <span className="text-[10px] font-mono text-text-dim ml-auto truncate" title={`${field.section} / ${field.key}`}>{field.key}</span>
        )}
      </div>
    </div>
  )
}

function BoolToggle({ on, off, value, disabled, onChange }: { on: string; off: string; value: string; disabled: boolean; onChange: (v: string) => void }) {
  const isOn = valuesEqual(value, on)
  const isOff = valuesEqual(value, off)
  const btn = 'flex-1 px-3 py-2 text-sm font-medium rounded-lg transition-colors disabled:opacity-50 disabled:cursor-not-allowed'
  return (
    <div className="flex items-center gap-2">
      <button
        type="button"
        disabled={disabled}
        onClick={() => onChange(off)}
        className={btn + ' ' + (isOff ? 'bg-danger/20 text-danger border border-danger/40' : 'bg-surface-2 border border-border text-text-muted')}
      >
        Off
      </button>
      <button
        type="button"
        disabled={disabled}
        onClick={() => onChange(on)}
        className={btn + ' ' + (isOn ? 'bg-success/20 text-success border border-success/40' : 'bg-surface-2 border border-border text-text-muted')}
      >
        On
      </button>
    </div>
  )
}

// -----------------------------------------------------------------------------
// All default settings browser — lazy-loads DefaultGame.ini + DefaultEngine.ini
// straight from the live game-server pod. Every section is a collapsible card;
// every key is editable and saved back to UserGame/UserEngine.ini via the
// existing explicit PUT /api/gameconfig form. Mirrors the reference implementation's "Server
// Settings" page.
// -----------------------------------------------------------------------------

function DefaultsCatalogBrowser({
  vmRunning, onSaved, excludedTargets,
}: {
  vmRunning: boolean
  onSaved: () => void
  excludedTargets?: Set<string>
}) {
  const { open, setOpen } = useCardCollapse('gameconfig.defaultsCatalog', false)
  const [data, setData] = useState<GameConfigDefaultsResponse | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [fileFilter, setFileFilter] = useState<'all' | 'game' | 'engine'>('all')
  const [expanded, setExpanded] = useState<Set<string>>(() => new Set())
  // sectionName||key  ->  edited value (string). Empty when nothing pending.
  const [edits, setEdits] = useState<Map<string, string>>(() => new Map())
  // sectionName||key||indexInSection  ->  edited value (string) for array (+/-)
  // rows. Array rows can appear multiple times per key (one per struct entry),
  // so we key by the row's fixed position in section.keys. Empty means "delete
  // this entry" — the save path drops empty-effective rows before writing.
  const [arrayEdits, setArrayEdits] = useState<Map<string, string>>(() => new Map())
  // sectionName||key||indexInSection  ->  true when the row's textarea is
  // expanded. Kept separate from the edits map so collapsing a row doesn't
  // discard a pending edit.
  const [arrayExpanded, setArrayExpanded] = useState<Set<string>>(() => new Set())
  const [saving, setSaving] = useState(false)
  const [saveErr, setSaveErr] = useState<string | null>(null)
  const [savedMsg, setSavedMsg] = useState<string | null>(null)

  const load = useCallback(async (refresh = false) => {
    setLoading(true); setError(null)
    try {
      const r = await getGameConfigDefaults(refresh)
      setData(r)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  // Fetch on first open, not before — keeps the (large) request lazy.
  useEffect(() => {
    if (open && !data && !loading && vmRunning) void load(false)
  }, [open, data, loading, vmRunning, load])

  const dirtyCount = edits.size + arrayEdits.size
  const sectionEditCount = (sectionName: string): number => {
    let n = 0
    edits.forEach((_v, k) => { if (k.startsWith(sectionName + '||')) n++ })
    arrayEdits.forEach((_v, k) => { if (k.startsWith(sectionName + '||')) n++ })
    return n
  }

  const sectionsFiltered = useMemo(() => {
    if (!data) return [] as GameConfigDefaultSection[]
    const q = search.trim().toLowerCase()
    return data.sections.map(s => {
      const keys = s.keys.filter(k => !excludedTargets?.has(`${s.file}||${s.name}||${k.key}`.toLowerCase()))
      return {
        ...s,
        keys,
        count: keys.length,
        overriddenCount: keys.filter(k => k.overridden).length,
      }
    }).filter(s => {
      if (s.keys.length === 0) return false
      if (fileFilter !== 'all' && s.file !== fileFilter) return false
      if (!q) return true
      if (s.name.toLowerCase().includes(q)) return true
      return s.keys.some(k => k.key.toLowerCase().includes(q))
    })
  }, [data, search, fileFilter, excludedTargets])

  const toggleSection = (name: string) => {
    setExpanded(prev => {
      const next = new Set(prev)
      if (next.has(name)) next.delete(name); else next.add(name)
      return next
    })
  }

  const setEdit = (sectionName: string, key: string, value: string, original: string) => {
    setEdits(prev => {
      const next = new Map(prev)
      const id = `${sectionName}||${key}`
      if (value === original) next.delete(id)
      else next.set(id, value)
      return next
    })
  }

  // Array-row edits (isArray=true entries): keyed by section||key||idx so
  // multiple struct-array rows with the same key don't collide. Passing ''
  // (empty) marks the row for deletion — the save path drops it from the
  // arrayLines set. Comparing to `original` keeps the map clean when the user
  // edits and then reverts.
  const setArrayEdit = (sectionName: string, key: string, idx: number, value: string, original: string) => {
    setArrayEdits(prev => {
      const next = new Map(prev)
      const id = `${sectionName}||${key}||${idx}`
      if (value === original) next.delete(id)
      else next.set(id, value)
      return next
    })
  }
  const getArrayEdit = (sectionName: string, key: string, idx: number): string | undefined =>
    arrayEdits.get(`${sectionName}||${key}||${idx}`)

  const toggleArrayRow = (sectionName: string, key: string, idx: number) => {
    setArrayExpanded(prev => {
      const next = new Set(prev)
      const id = `${sectionName}||${key}||${idx}`
      if (next.has(id)) next.delete(id); else next.add(id)
      return next
    })
  }
  const isArrayRowExpanded = (sectionName: string, key: string, idx: number): boolean =>
    arrayExpanded.has(`${sectionName}||${key}||${idx}`)

  const resetEdits = () => {
    setEdits(new Map())
    setArrayEdits(new Map())
    setSavedMsg(null)
    setSaveErr(null)
  }

  const onSave = async () => {
    if (!data || (edits.size === 0 && arrayEdits.size === 0)) return
    setSaving(true); setSaveErr(null); setSavedMsg(null)
    try {
      // Map each section name -> its file + full row list. Used both for
      // scalar-edit dispatch and for rebuilding arrayLines from the union of
      // catalog rows + pending arrayEdits.
      const sectionMeta = new Map<string, { file: 'game' | 'engine'; keys: GameConfigDefaultKey[] }>()
      for (const s of data.sections) sectionMeta.set(s.name, { file: s.file, keys: s.keys })

      const updates: GameConfigRawUpdate[] = []

      // 1) Scalar edits — same shape as before.
      edits.forEach((value, id) => {
        const ix = id.indexOf('||')
        if (ix < 0) return
        const section = id.slice(0, ix)
        const key = id.slice(ix + 2)
        const meta = sectionMeta.get(section)
        if (!meta) return
        updates.push({ file: meta.file, section, key, value })
      })

      // 2) Array edits — group per (section, key), then rebuild the full set
      // of +/-key= lines using the catalog rows for that key (in section
      // order), applying the per-row edit override where present. Empty
      // effective values drop the row from the set (delete). Basic bracket
      // balance check rejects malformed struct values before they hit the
      // server — Unreal INI is picky about paren counts and a missing ')'
      // silently breaks the whole key at load time.
      const arrayGroups = new Map<string, { section: string; key: string; file: 'game' | 'engine' }>()
      arrayEdits.forEach((_v, id) => {
        const parts = id.split('||')
        if (parts.length !== 3) return
        const [section, key] = parts
        const meta = sectionMeta.get(section)
        if (!meta) return
        const gkey = `${section}||${key}`
        if (!arrayGroups.has(gkey)) arrayGroups.set(gkey, { section, key, file: meta.file })
      })

      for (const { section, key, file } of arrayGroups.values()) {
        const meta = sectionMeta.get(section)
        if (!meta) continue
        const lines: string[] = []
        meta.keys.forEach((k, idx) => {
          if (!k.isArray || k.key !== key) return
          const override = getArrayEdit(section, key, idx)
          const raw = override !== undefined ? override : k.current
          // Strip stray CR/LF a paste may have injected; INI stores each
          // entry on a single physical line.
          const value = raw.replace(/[\r\n]+/g, '').trim()
          if (!value) return
          // Bracket balance check — must count paren pairs. Anything else the
          // server would happily write, but the game would drop.
          let depth = 0
          let bad = false
          for (const ch of value) {
            if (ch === '(') depth++
            else if (ch === ')') { depth--; if (depth < 0) { bad = true; break } }
          }
          if (bad || depth !== 0) {
            throw new Error(`Unbalanced parens in ${key} entry #${idx + 1}. Fix the ( ) count before saving.`)
          }
          const prefix = (k.prefix === '-' || k.prefix === '+') ? k.prefix : '+'
          lines.push(`${prefix}${key}=${value}`)
        })
        updates.push({ file, section, key, arrayLines: lines })
      }

      if (updates.length === 0) return
      await saveGameConfigRaw(updates)
      setSavedMsg(`Saved ${updates.length} change${updates.length === 1 ? '' : 's'}.`)
      setEdits(new Map())
      setArrayEdits(new Map())
      await load(false)
      onSaved()
    } catch (e) {
      setSaveErr(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="card p-5" data-section-nav-id="gameconfig.defaultsCatalog" data-section-nav-label="Remaining default INI settings">
      <button
        type="button"
        onClick={() => setOpen(o => !o)}
        aria-expanded={open}
        data-section-nav-toggle
        className="w-full flex items-center justify-between text-sm font-semibold uppercase tracking-wider text-accent-bright"
      >
        <span className="flex items-center gap-2">
          <Icon name={open ? 'ChevronDown' : 'ChevronRight'} size={14} />
          Remaining default INI settings
        </span>
        <span className="text-[10px] font-normal text-text-dim normal-case tracking-normal">
          {data ? `${data.sections.length} sections` : 'lazy-loaded'}
        </span>
      </button>

      {open && (
        <div className="mt-4 space-y-3">
          {!vmRunning && (
            <div className="text-xs text-text-muted">Start the VM to load the defaults catalog.</div>
          )}

          {vmRunning && (
            <div className="rounded-lg border border-border/60 bg-surface-2/50 px-3 py-2 text-[11px] text-text-muted leading-relaxed">
              <span className="text-text-dim font-semibold">Live default INI catalog.</span> Curated Game Config and CVar keys are excluded.
              Each remaining row is one line
              in <span className="font-mono text-text-dim">DefaultGame.ini</span> or <span className="font-mono text-text-dim">DefaultEngine.ini</span>.
              Rows tagged <span className="font-mono text-warning">[+]</span> or <span className="font-mono text-warning">[-]</span> are
              array entries — one struct value per row. Click <span className="font-semibold text-text-dim">Edit</span> to open a textarea;
              your edit rewrites just that entry when you Save. <span className="font-semibold text-text-dim">Delete entry</span> drops the row from the
              INI file on save. Empty rows are skipped. Bracket count is validated before saving — DST won't ship a malformed struct to Unreal.
            </div>
          )}

          {vmRunning && (
            <div className="flex items-center gap-2 flex-wrap">
              <input
                type="text"
                value={search}
                onChange={e => setSearch(e.target.value)}
                placeholder="Search section or key…"
                className="flex-1 min-w-[200px] px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm placeholder:text-text-dim focus:outline-none focus:ring-2 focus:ring-accent/40"
              />
              <div className="flex items-center gap-1 bg-surface-2 rounded-lg p-0.5">
                {(['all', 'game', 'engine'] as const).map(f => (
                  <button
                    key={f}
                    type="button"
                    onClick={() => setFileFilter(f)}
                    className={'px-3 py-1.5 text-xs font-medium rounded-md ' + (fileFilter === f ? 'bg-accent/20 text-accent-bright' : 'text-text-muted')}
                  >
                    {f === 'all' ? 'All' : f === 'game' ? 'Game' : 'Engine'}
                  </button>
                ))}
              </div>
              <button
                type="button"
                onClick={() => void load(true)}
                disabled={loading}
                className="btn-secondary"
                title="Re-read DefaultGame.ini / DefaultEngine.ini from the live pod"
              >
                <Icon name={loading ? 'Loader2' : 'RefreshCw'} size={13} className={loading ? 'animate-spin' : ''} />
                Refresh
              </button>
            </div>
          )}

          {loading && !data && (
            <div className="text-sm text-text-muted flex items-center gap-2">
              <Icon name="Loader2" size={14} className="animate-spin" />
              Reading DefaultGame.ini + DefaultEngine.ini from the live pod…
            </div>
          )}

          {error && (
            <div className="text-sm text-danger flex items-start gap-2">
              <Icon name="AlertTriangle" size={14} className="mt-0.5" />
              <span>{error}</span>
            </div>
          )}

          {data && (
            <>
              {data.source && (
                <div className="text-[11px] font-mono text-text-dim truncate" title={`${data.source.ns}/${data.source.pod} @ ${data.source.fetchedAt}`}>
                  source: {data.source.pod} {data.cached && <span className="text-text-muted">(cached)</span>}
                </div>
              )}

              <div className="space-y-2 max-h-[32rem] overflow-y-auto pr-1">
                {sectionsFiltered.map(s => (
                  <DefaultsSectionCard
                    key={`${s.file}-${s.name}`}
                    section={s}
                    expanded={expanded.has(s.name)}
                    onToggle={() => toggleSection(s.name)}
                    editsCount={sectionEditCount(s.name)}
                    getEdit={(key) => edits.get(`${s.name}||${key}`)}
                    onEdit={(key, value, original) => setEdit(s.name, key, value, original)}
                    getArrayEdit={(key, idx) => getArrayEdit(s.name, key, idx)}
                    onArrayEdit={(key, idx, value, original) => setArrayEdit(s.name, key, idx, value, original)}
                    isArrayRowExpanded={(key, idx) => isArrayRowExpanded(s.name, key, idx)}
                    onToggleArrayRow={(key, idx) => toggleArrayRow(s.name, key, idx)}
                    searchTerm={search.trim().toLowerCase()}
                  />
                ))}
                {sectionsFiltered.length === 0 && (
                  <div className="text-sm text-text-muted">No sections match the filter.</div>
                )}
              </div>

              <div className="flex items-center justify-between border-t border-border pt-3 mt-2">
                <div className="text-xs text-text-muted">
                  {dirtyCount === 0 ? 'No changes' : `${dirtyCount} pending change${dirtyCount === 1 ? '' : 's'}`}
                  {savedMsg && <span className="ml-3 text-success">{savedMsg}</span>}
                  {saveErr && <span className="ml-3 text-danger">{saveErr}</span>}
                </div>
                <div className="flex items-center gap-2">
                  <button
                    type="button"
                    onClick={resetEdits}
                    disabled={dirtyCount === 0 || saving}
                    className="btn-secondary"
                  >
                    Reset
                  </button>
                  <button
                    type="button"
                    onClick={() => void onSave()}
                    disabled={dirtyCount === 0 || saving || !vmRunning}
                    className="btn-primary"
                  >
                    <Icon name={saving ? 'Loader2' : 'Save'} size={14} className={saving ? 'animate-spin' : ''} />
                    {saving ? 'Saving…' : `Save ${dirtyCount || ''}`}
                  </button>
                </div>
              </div>
            </>
          )}
        </div>
      )}
    </div>
  )
}

function DefaultsSectionCard({
  section, expanded, onToggle, editsCount, getEdit, onEdit,
  getArrayEdit, onArrayEdit, isArrayRowExpanded, onToggleArrayRow, searchTerm,
}: {
  section: GameConfigDefaultSection
  expanded: boolean
  onToggle: () => void
  editsCount: number
  getEdit: (key: string) => string | undefined
  onEdit: (key: string, value: string, original: string) => void
  getArrayEdit: (key: string, idx: number) => string | undefined
  onArrayEdit: (key: string, idx: number, value: string, original: string) => void
  isArrayRowExpanded: (key: string, idx: number) => boolean
  onToggleArrayRow: (key: string, idx: number) => void
  searchTerm: string
}) {
  // Preserve each row's index in the FULL section.keys array — that stable
  // index is the arrayEdits map key and identifies the specific struct entry
  // this row represents when multiple isArray rows share a key.
  const visibleKeys = useMemo(() => {
    const withIdx = section.keys.map((k, idx) => ({ k, idx }))
    if (!searchTerm) return withIdx
    if (section.name.toLowerCase().includes(searchTerm)) return withIdx
    return withIdx.filter(({ k }) => k.key.toLowerCase().includes(searchTerm))
  }, [section, searchTerm])

  return (
    <div className="border border-border rounded-lg overflow-hidden">
      <button
        type="button"
        onClick={onToggle}
        onKeyDown={e => copyIniSectionFromKey(e, section.name)}
        className="w-full flex items-center justify-between px-3 py-2 bg-surface-2 hover:bg-surface-3 transition-colors text-left"
        title={`Click to ${expanded ? 'collapse' : 'expand'}; Ctrl+C copies [${section.name}]`}
      >
        <span className="flex items-center gap-2 min-w-0">
          <Icon name={expanded ? 'ChevronDown' : 'ChevronRight'} size={13} className="shrink-0 text-text-muted" />
          <span className="font-mono text-xs text-text truncate" title={section.name}>[{section.name}]</span>
          <span className={'text-[9px] font-semibold uppercase tracking-wider px-1.5 py-0.5 rounded shrink-0 ' +
            (section.file === 'engine' ? 'bg-warning/15 text-warning' : 'bg-accent/15 text-accent-bright')}>
            {section.file}
          </span>
        </span>
        <span className="flex items-center gap-2 shrink-0 text-[10px] text-text-dim">
          {editsCount > 0 && (
            <span className="px-1.5 py-0.5 rounded bg-success/15 text-success font-semibold">
              {editsCount} edit{editsCount === 1 ? '' : 's'}
            </span>
          )}
          {section.overriddenCount > 0 && (
            <span className="px-1.5 py-0.5 rounded bg-accent/15 text-accent-bright font-semibold">
              {section.overriddenCount} overridden
            </span>
          )}
          <span>{section.count} keys</span>
        </span>
      </button>

      {expanded && (
        <div className="divide-y divide-border/60">
          {visibleKeys.length === 0 && (
            <div className="px-3 py-2 text-[11px] text-text-dim">(no keys match)</div>
          )}
          {visibleKeys.map(({ k, idx }) => (
            <DefaultsKeyRow
              key={`${k.key}-${idx}`}
              k={k}
              rowIdx={idx}
              pending={getEdit(k.key)}
              onChange={(v) => onEdit(k.key, v, k.current)}
              arrayPending={getArrayEdit(k.key, idx)}
              onArrayChange={(v) => onArrayEdit(k.key, idx, v, k.current)}
              expanded={isArrayRowExpanded(k.key, idx)}
              onToggleExpand={() => onToggleArrayRow(k.key, idx)}
            />
          ))}
        </div>
      )}
    </div>
  )
}

function DefaultsKeyRow({
  k, rowIdx, pending, onChange,
  arrayPending, onArrayChange, expanded, onToggleExpand,
}: {
  k: GameConfigDefaultKey
  rowIdx: number
  pending: string | undefined
  onChange: (v: string) => void
  arrayPending: string | undefined
  onArrayChange: (v: string) => void
  expanded: boolean
  onToggleExpand: () => void
}) {
  const displayed = pending ?? k.current
  const isDirty = pending !== undefined
  const isArray = k.isArray
  // For array rows the effective value tracks arrayPending, and dirty state
  // includes cleared entries (delete-a-row).
  const arrayDisplayed = arrayPending !== undefined ? arrayPending : k.current
  const arrayIsDirty = arrayPending !== undefined
  const arrayIsDeleted = arrayIsDirty && arrayPending!.trim() === ''

  const inputCls =
    'w-full px-2 py-1 rounded bg-surface border border-border text-text text-xs font-mono ' +
    'focus:outline-none focus:ring-2 focus:ring-accent/40 disabled:opacity-60'

  let control: ReactElement
  if (isArray) {
    // Array (+/-) rows: single-line preview with an expand toggle. Expanded
    // view shows a multi-line textarea (Unreal struct syntax can be long)
    // plus Reset-this-entry and Delete-this-entry actions. On save, the
    // parent walks all array rows for this key in section order and rewrites
    // the entire +/-key= line set — deleted rows drop out.
    if (expanded) {
      control = (
        <div className="space-y-1.5">
          <textarea
            value={arrayDisplayed}
            onChange={e => onArrayChange(e.target.value)}
            spellCheck={false}
            rows={Math.min(10, Math.max(3, Math.ceil(arrayDisplayed.length / 80)))}
            className={inputCls + ' resize-y min-h-[4rem] leading-snug'}
            placeholder="(Field=Value,Field=Value)"
          />
          <div className="flex items-center justify-between gap-2 text-[10px]">
            <span className="text-text-dim">
              entry #{rowIdx + 1}{k.prefix === '-' ? ' (array-remove)' : ''}
              {arrayIsDeleted && <span className="ml-2 px-1 rounded bg-danger/15 text-danger font-semibold uppercase">will delete</span>}
            </span>
            <div className="flex items-center gap-1">
              <button
                type="button"
                onClick={() => onArrayChange(k.current)}
                disabled={!arrayIsDirty}
                className="btn-ghost px-2 py-0.5 text-[10px] disabled:opacity-40"
                title="Revert this entry to what's currently in the INI"
              >
                Reset
              </button>
              <button
                type="button"
                onClick={() => onArrayChange('')}
                disabled={arrayIsDeleted}
                className="btn-ghost px-2 py-0.5 text-[10px] text-danger disabled:opacity-40"
                title="Drop this entry from the +key=... line set on save"
              >
                Delete entry
              </button>
              <button
                type="button"
                onClick={onToggleExpand}
                className="btn-ghost px-2 py-0.5 text-[10px]"
              >
                Collapse
              </button>
            </div>
          </div>
        </div>
      )
    } else {
      control = (
        <div className="flex items-center gap-2 min-w-0">
          <span className="text-[11px] font-mono text-text-dim truncate flex-1" title={arrayDisplayed}>
            {arrayIsDeleted ? <span className="italic text-danger/80">(will delete)</span> : arrayDisplayed}
          </span>
          <button
            type="button"
            onClick={onToggleExpand}
            className="btn-ghost px-2 py-0.5 text-[10px] shrink-0"
            title="Edit this array entry"
          >
            Edit
          </button>
        </div>
      )
    }
  } else {
    const pair = boolPair(k.type)
    if (pair) {
      control = (
        <div className="flex items-center gap-1">
          <button
            type="button"
            onClick={() => onChange(pair.off)}
            className={'px-2 py-1 text-[11px] rounded ' + (valuesEqual(displayed, pair.off) ? 'bg-danger/20 text-danger border border-danger/40' : 'bg-surface border border-border text-text-muted')}
          >Off</button>
          <button
            type="button"
            onClick={() => onChange(pair.on)}
            className={'px-2 py-1 text-[11px] rounded ' + (valuesEqual(displayed, pair.on) ? 'bg-success/20 text-success border border-success/40' : 'bg-surface border border-border text-text-muted')}
          >On</button>
        </div>
      )
    } else if (k.type === 'int' || k.type === 'float') {
      control = (
        <input
          type="number"
          value={displayed}
          onChange={e => onChange(e.target.value)}
          className={inputCls}
          step={k.type === 'float' ? 'any' : '1'}
        />
      )
    } else {
      control = (
        <input
          type="text"
          value={displayed}
          onChange={e => onChange(e.target.value)}
          className={inputCls}
        />
      )
    }
  }

  return (
    <div className={
      'px-3 py-2 grid grid-cols-[minmax(0,2fr)_minmax(0,3fr)_minmax(0,2fr)] gap-3 ' +
      (isArray && expanded ? 'items-start' : 'items-center')
    }>
      <span className="font-mono text-[11px] text-text truncate" title={k.key}>
        {isArray && (
          <span className="text-warning mr-1" title={`Array entry ${k.prefix === '-' ? '(array-remove)' : '(array-append)'}`}>
            {k.prefix === '-' ? '[-]' : '[+]'}
          </span>
        )}
        {k.key}
      </span>
      <div>{control}</div>
      <div className="text-[10px] font-mono text-text-dim truncate flex items-center gap-2" title={`default: ${k.default}`}>
        {isDirty && <span className="px-1 rounded bg-success/15 text-success font-semibold uppercase">edited</span>}
        {arrayIsDeleted && <span className="px-1 rounded bg-danger/15 text-danger font-semibold uppercase">delete</span>}
        {arrayIsDirty && !arrayIsDeleted && <span className="px-1 rounded bg-success/15 text-success font-semibold uppercase">edited</span>}
        {!isDirty && !arrayIsDirty && k.overridden && <span className="px-1 rounded bg-accent/15 text-accent-bright font-semibold uppercase">overridden</span>}
        <span className="truncate">default: {k.default || <span className="text-text-dim/60">∅</span>}</span>
      </div>
    </div>
  )
}

// -----------------------------------------------------------------------------
// Advanced / raw INI browser (read-only) — shows everything in both files,
// including keys DST has no curated control for, with managed-block badges.
// -----------------------------------------------------------------------------

function AdvancedIniBrowser({ cfg }: { cfg: GameConfigResponse }) {
  const { open, setOpen } = useCardCollapse('gameconfig.authoritativeIni', false)
  const [file, setFile] = useState<'game' | 'engine'>('game')
  const [showRaw, setShowRaw] = useState(false)

  const bundle = file === 'game' ? cfg.game : cfg.engine

  return (
    <div className="card p-5 mb-4" data-section-nav-id="gameconfig.advancedIni" data-section-nav-label="Authoritative server INIs">
      <button
        type="button"
        onClick={() => setOpen(o => !o)}
        aria-expanded={open}
        data-section-nav-toggle
        className="w-full flex items-center justify-between text-sm font-semibold uppercase tracking-wider text-accent-bright"
      >
        <span className="flex items-center gap-2">
          <Icon name={open ? 'ChevronDown' : 'ChevronRight'} size={14} /> Authoritative server INIs
        </span>
        <span className="text-[10px] font-normal text-text-dim normal-case tracking-normal">read-only</span>
      </button>

      {open && (
        <div className="mt-4">
          <p className="text-xs text-text-muted mb-3">
            These are the exact <span className="font-mono">UserGame.ini</span> and{' '}
            <span className="font-mono">UserEngine.ini</span> overrides DST owns and deploys to the battlegroup.
            Funcom defaults are inherited and appear here only after they are overridden.
          </p>
          <div className="flex items-center justify-between mb-3">
            <div className="flex items-center gap-1 bg-surface-2 rounded-lg p-0.5">
              {(['game', 'engine'] as const).map(f => (
                <button
                  key={f}
                  type="button"
                  onClick={() => setFile(f)}
                  className={'px-3 py-1.5 text-xs font-medium rounded-md ' + (file === f ? 'bg-accent/20 text-accent-bright' : 'text-text-muted')}
                >
                  {f === 'game' ? 'UserGame.ini' : 'UserEngine.ini'}
                </button>
              ))}
            </div>
            <button type="button" onClick={() => setShowRaw(r => !r)} className="btn-ghost px-2 py-1 text-xs">
              <Icon name="Code" size={13} /> {showRaw ? 'Sections' : 'Raw text'}
            </button>
          </div>

          {showRaw ? (
            <pre className="text-[11px] font-mono text-text-muted bg-surface-2 rounded-lg p-3 overflow-x-auto max-h-[28rem] overflow-y-auto whitespace-pre">
              {bundle.raw}
            </pre>
          ) : (
            <div className="space-y-3 max-h-[28rem] overflow-y-auto pr-1">
              {bundle.sections.map((s, i) => (
                <IniSectionBlock key={`${s.name}-${i}`} section={s} />
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  )
}

function IniSectionBlock({ section }: { section: GameConfigIniSection }) {
  return (
    <div className="border border-border rounded-lg overflow-hidden">
      <div
        tabIndex={0}
        onKeyDown={e => copyIniSectionFromKey(e, section.name)}
        className="flex items-center justify-between px-3 py-2 bg-surface-2 focus:outline-none focus:ring-2 focus:ring-accent/50"
        title={`Ctrl+C copies [${section.name}]`}
      >
        <span className="font-mono text-xs text-text truncate" title={section.name}>[{section.name}]</span>
        {section.managed && (
          <span className="text-[9px] font-semibold uppercase tracking-wider px-1.5 py-0.5 rounded bg-accent/15 text-accent-bright shrink-0">
            DST-managed
          </span>
        )}
      </div>
      <div className="divide-y divide-border/60">
        {section.keys.length === 0 && (
          <div className="px-3 py-1.5 text-[11px] text-text-dim">(no keys)</div>
        )}
        {section.keys.map((k, i) => (
          <div key={`${k.key}-${i}`} className="px-3 py-1.5 flex items-start gap-2 text-[11px] font-mono">
            <span className="text-text-muted shrink-0">
              {k.isArray && <span className="text-warning mr-1" title="Array entry (+/-)">[]</span>}
              {k.key}
            </span>
            <span className="text-text-dim">=</span>
            <span className="text-text break-all">{k.value}</span>
          </div>
        ))}
      </div>
    </div>
  )
}

function ClientApplyReviewModal({
  items, mode, busy, onCancel, onConfirm,
}: {
  items: GameConfigClientApplyItem[]
  mode: ClientReviewMode
  busy: boolean
  onCancel: () => void
  onConfirm: (items: GameConfigClientApplyItem[]) => void
}) {
  const itemId = (item: GameConfigClientApplyItem) => `${item.file}||${item.key}`.toLowerCase()
  const [selectedIds, setSelectedIds] = useState(() => new Set(items.filter(item => item.selected !== false).map(itemId)))
  const selectedItems = items.filter(item => selectedIds.has(itemId(item)))
  const groups = (['game', 'engine'] as const)
    .map(file => ({ file, items: items.filter(item => item.file === file) }))
    .filter(group => group.items.length > 0)
  const toggleItem = (item: GameConfigClientApplyItem) => {
    const id = itemId(item)
    setSelectedIds(previous => {
      const next = new Set(previous)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4"
      onClick={() => { if (!busy) onCancel() }}
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="client-apply-review-title"
        className="card p-0 max-w-2xl w-full max-h-[85vh] flex flex-col overflow-hidden"
        onClick={e => e.stopPropagation()}
      >
        <div className="px-5 py-4 border-b border-border flex items-center justify-between gap-3">
          <div>
            <h3 id="client-apply-review-title" className="font-semibold text-text flex items-center gap-2">
              <Icon name="MonitorCog" size={16} className="text-accent-bright" />
              {mode === 'legacy' ? 'Review WindowsClient migration' : 'Review advanced compatibility overrides'}
            </h3>
            <p className="mt-1 text-xs text-text-muted">
              {mode === 'legacy'
                ? 'This imports only recognized, non-default compatibility values with direct current-Retail evidence. Whole files and unrelated settings are never copied.'
                : 'This writes only customized, non-default compatibility overrides with direct current-Retail evidence of local evaluation. It does not copy every server INI setting.'}
            </p>
          </div>
          <button
            type="button"
            className="btn-ghost px-2 py-1"
            onClick={onCancel}
            disabled={busy}
            aria-label="Close client settings review"
          >
            <Icon name="X" size={16} />
          </button>
        </div>

        <div className="px-5 py-4 overflow-y-auto space-y-4">
          {groups.map(group => (
            <section key={group.file} aria-labelledby={`client-review-${group.file}`}>
              <div className="mb-2 flex items-center justify-between gap-3">
                <h4 id={`client-review-${group.file}`} className="text-sm font-semibold text-text font-mono">
                  {group.file === 'game' ? 'Game.ini' : 'Engine.ini'}
                </h4>
                <span className="text-xs text-text-muted">
                  {group.items.filter(item => selectedIds.has(itemId(item))).length} of {group.items.length} selected
                </span>
              </div>
              <div className="divide-y divide-border border border-border rounded-lg overflow-hidden">
                {group.items.map(item => (
                  <label
                    key={itemId(item)}
                    className="flex items-start gap-3 p-3 bg-surface-2/40 cursor-pointer"
                  >
                    <input
                      type="checkbox"
                      checked={selectedIds.has(itemId(item))}
                      onChange={() => toggleItem(item)}
                      disabled={busy}
                      className="h-4 w-4 mt-0.5 accent-accent shrink-0"
                    />
                    <span className="min-w-0 flex-1">
                      <span className="block text-sm font-medium text-text">{item.label}</span>
                      <span className="mt-0.5 block text-xs text-text-muted">
                        {mode === 'legacy'
                          ? item.state === 'conflict'
                            ? 'Conflict: the active Windows file has a different value. Review both values before selecting this item.'
                            : 'Missing from the active Windows file and preselected for import from WindowsClient.'
                          : 'Offered because current Retail field testing shows this advanced value is evaluated from the local client config.'}
                      </span>
                      <span className="mt-1 grid gap-1 text-xs font-mono sm:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
                        <span className="text-text-muted break-all">[{item.section}] {item.key}</span>
                        <span className="text-text break-all sm:text-right">
                          {mode === 'legacy'
                            ? <>old: {item.value}{item.currentValue ? ` • current: ${item.currentValue}` : ' • current: missing'}</>
                            : item.value}
                        </span>
                      </span>
                    </span>
                  </label>
                ))}
              </div>
            </section>
          ))}
          <p className="text-xs text-text-muted">
            Game.ini compatibility values do not require Engine.ini management. Engine.ini entries appear here only after
            that separate opt-in is enabled. Existing destination files are backed up before an atomic, verified write.
            This changes this PC only; other players must review and apply their own matching values.
          </p>
        </div>

        <div className="px-5 py-3 border-t border-border flex flex-wrap items-center justify-between gap-2">
          <span className="text-xs text-text-muted">
            {selectedItems.length} of {items.length} reviewed setting{items.length === 1 ? '' : 's'} selected
          </span>
          <div className="flex items-center gap-2">
            <button type="button" className="btn-secondary" onClick={onCancel} disabled={busy}>
              Cancel
            </button>
            <button
              type="button"
              className="btn-primary"
              onClick={() => onConfirm(selectedItems)}
              disabled={busy || selectedItems.length === 0}
            >
              <Icon name={busy ? 'Loader2' : 'MonitorCog'} size={14} className={busy ? 'animate-spin' : ''} />
              {busy ? 'Applying…' : `Apply ${selectedItems.length} selected setting${selectedItems.length === 1 ? '' : 's'}`}
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}

// -----------------------------------------------------------------------------
// Sandworm-enable confirmation modal
// -----------------------------------------------------------------------------

function SandwormConfirmModal({
  open, onCancel, onConfirm,
}: {
  open: boolean
  onCancel: () => void
  onConfirm: () => void
}) {
  const [text, setText] = useState('')

  useEffect(() => { if (!open) setText('') }, [open])

  if (!open) return null

  const ok = text.trim().toLowerCase() === 'i confirm'

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4"
      onClick={onCancel}
    >
      <div
        className="card p-0 max-w-md w-full"
        onClick={e => e.stopPropagation()}
      >
        <div className="px-5 py-4 border-b border-border flex items-center justify-between">
          <h3 className="font-semibold text-text flex items-center gap-2">
            <Icon name="AlertTriangle" size={16} className="text-warning" />
            Enable Sandworms?
          </h3>
          <button type="button" className="btn-ghost px-2 py-1" onClick={onCancel}>
            <Icon name="X" size={16} />
          </button>
        </div>

        <div className="px-5 py-4 space-y-4">
          <div className="text-sm text-text leading-relaxed">
            When this is enabled, all sandworm areas should be clear of items
            you want to keep.{' '}
            <span className="font-semibold text-danger">Irreversible.</span>
          </div>

          <div>
            <label className="block text-xs uppercase tracking-wider text-text-muted mb-1.5">
              Type <span className="font-mono text-text">i confirm</span> to proceed
            </label>
            <input
              type="text"
              autoFocus
              value={text}
              onChange={e => setText(e.target.value)}
              onKeyDown={e => {
                if (e.key === 'Enter' && ok) { e.preventDefault(); onConfirm() }
                if (e.key === 'Escape') { e.preventDefault(); onCancel() }
              }}
              placeholder="i confirm"
              className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm
                         font-mono placeholder:text-text-dim focus:outline-none focus:ring-2
                         focus:ring-warning focus:border-warning/50"
            />
          </div>
        </div>

        <div className="px-5 py-3 border-t border-border flex items-center justify-end gap-2">
          <button type="button" className="btn-secondary" onClick={onCancel}>
            Cancel
          </button>
          <button
            type="button"
            disabled={!ok}
            onClick={onConfirm}
            className="btn-primary"
          >
            <Icon name="AlertTriangle" size={14} />
            Enable Sandworms
          </button>
        </div>
      </div>
    </div>
  )
}
