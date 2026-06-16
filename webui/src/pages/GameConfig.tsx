import { useState, useEffect, useMemo, useCallback, type FormEvent, type ReactElement } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { useStatus } from '../hooks/useStatus'
import { api } from '../api/client'
import {
  getGameConfigSchema,
  getGameConfig,
  saveGameConfig,
  backupGameConfig,
  listGameConfigBackups,
  deleteGameConfigBackups,
  getGameConfigClient,
  setGameConfigClientDir,
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
  GameConfigClientApply,
  GameConfigClientApplyResult,
  GameConfigClientInfo,
  GameConfigDefaultsResponse,
  GameConfigDefaultSection,
  GameConfigDefaultKey,
  GameConfigRawUpdate,
} from '../api/types'
import { SpicefieldsCard } from './gameconfig/SpicefieldsCard'

type LoadState = 'idle' | 'loading' | 'ready' | 'error' | 'unavailable'

// One server-vs-client disagreement for a customised ClientApply setting.
type ClientMismatch = {
  key: string
  label: string
  section: string
  serverValue: string
  clientValue: string | null
  // True when this entry belongs to a structurally-incomplete client struct box
  // (a stripped "stub" — see clientMismatches). Drives the "your client is
  // missing part of a settings block" notice, distinct from a plain value diff.
  structural?: boolean
}

const SANDWORM_ENABLED_KEY = 'sandworm.dune.Enabled'

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

// Build a human-readable result message for a client-apply that signifies what
// was WRITTEN (added/changed) vs REMOVED (reset to default / deprecated key
// cleanup), so the user can tell exactly what DST did to their client Game.ini.
function describeClientApply(
  r: GameConfigClientApplyResult,
  writeVerb: 'Applied' | 'Synced' | 'Wrote' = 'Applied',
): string {
  const items = r.items ?? []
  const removed = items.filter(i => i.remove).length
  const written = items.length - removed
  const parts: string[] = []
  if (written > 0) parts.push(`${r.created ? 'created the file and ' : ''}wrote ${written} setting${written === 1 ? '' : 's'}`)
  if (removed > 0) parts.push(`removed ${removed} key${removed === 1 ? '' : 's'} (reset/cleanup)`)
  const what = parts.length > 0 ? parts.join(' and ') : `applied ${r.applied} change${r.applied === 1 ? '' : 's'}`
  const lead = parts.length > 0 ? '' : `${writeVerb}: `
  return `${lead}${what.charAt(0).toUpperCase()}${what.slice(1)} in your local client Game.ini (${r.path}).`
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

export function GameConfig() {
  const { status } = useStatus()
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
  const [clientApply, setClientApply] = useState<GameConfigClientApply | null>(null)
  const [sandwormModalOpen, setSandwormModalOpen] = useState(false)
  const [search, setSearch] = useState('')
  const [backing, setBacking] = useState(false)
  const [backupMsg, setBackupMsg] = useState<string | null>(null)
  const [backupError, setBackupError] = useState<string | null>(null)
  const [backupsOpen, setBackupsOpen] = useState(false)
  const [backupsLoading, setBackupsLoading] = useState(false)
  const [backupsError, setBackupsError] = useState<string | null>(null)
  const [backups, setBackups] = useState<GameConfigBackupEntry[]>([])
  const [backupSel, setBackupSel] = useState<Set<string>>(new Set())
  const [backupDeleting, setBackupDeleting] = useState(false)

  // Local client config (this PC). DST runs locally, so it can read/write the
  // player's own client Game.ini directly — gated behind explicit user action.
  const [clientInfo, setClientInfo] = useState<GameConfigClientInfo | null>(null)
  const [clientDirInput, setClientDirInput] = useState('')
  const [clientBusy, setClientBusy] = useState(false)
  const [clientMsg, setClientMsg] = useState<string | null>(null)
  const [clientErr, setClientErr] = useState<string | null>(null)
  const [clientViewOpen, setClientViewOpen] = useState(false)
  const [applying, setApplying] = useState(false)
  const [clientSnippetCopied, setClientSnippetCopied] = useState(false)

  // Server-vs-client mismatch popup. Auto-shown on load when a configured client
  // Game.ini disagrees with the server on a customised ClientApply setting.
  const [mismatchOpen, setMismatchOpen] = useState(false)
  const [mismatchAutoShown, setMismatchAutoShown] = useState(false)
  const [mismatchFixing, setMismatchFixing] = useState(false)
  const [mismatchErr, setMismatchErr] = useState<string | null>(null)
  const [mismatchMsg, setMismatchMsg] = useState<string | null>(null)
  const [mismatchFallback, setMismatchFallback] = useState(false)
  const [mismatchCopied, setMismatchCopied] = useState(false)
  // Signature of the mismatch set the user last dismissed ("Not now"/close),
  // persisted so we don't re-nag with the modal on every page load for the same
  // unchanged values. A successful fix clears it; a genuinely new/changed
  // mismatch produces a different signature and surfaces again.
  const [mismatchDismissedSig, setMismatchDismissedSig] = useState<string>(() => {
    try { return window.localStorage.getItem('dst.gameconfig.mismatchDismissed') ?? '' } catch { return '' }
  })
  const persistMismatchDismissed = useCallback((sig: string) => {
    setMismatchDismissedSig(sig)
    try {
      if (sig) window.localStorage.setItem('dst.gameconfig.mismatchDismissed', sig)
      else window.localStorage.removeItem('dst.gameconfig.mismatchDismissed')
    } catch { /* localStorage may be unavailable; in-memory state still applies */ }
  }, [])

  // INI text the admin can hand to OTHER players (who don't run DST) to paste
  // into their own client Game.ini — grouped by section, last-write-wins order.
  const clientSnippet = useMemo(() => {
    if (!clientApply || clientApply.items.length === 0) return ''
    const bySection = new Map<string, string[]>()
    for (const it of clientApply.items) {
      const lines = bySection.get(it.section) ?? []
      lines.push(`${it.key}=${it.value}`)
      bySection.set(it.section, lines)
    }
    return [...bySection.entries()]
      .map(([section, lines]) => [`[${section}]`, ...lines].join('\n'))
      .join('\n\n')
  }, [clientApply])

  const onCopyClientSnippet = useCallback(async () => {
    if (!clientSnippet) return
    try {
      await navigator.clipboard.writeText(clientSnippet)
      setClientSnippetCopied(true)
      setTimeout(() => setClientSnippetCopied(false), 1500)
    } catch { /* clipboard may be unavailable; the snippet is still shown */ }
  }, [clientSnippet])

  // Schema struct groups (file||section||structKey) -> member field keys. Used to
  // detect a structurally-incomplete client struct box, e.g. a stripped
  // LandsraadSettings Data=(...) stub that's missing members the game ships. A
  // UE struct override REPLACES the whole box, so a stub silently drops every
  // member it omits back to a built-in default — without ever differing on a
  // value the admin customised, so the plain value detector below can't see it.
  const structMemberGroups = useMemo(() => {
    const groups = new Map<string, { file: string; section: string; structKey: string; keys: string[] }>()
    if (!schema) return groups
    for (const cat of schema) {
      for (const f of cat?.fields ?? []) {
        if (!f?.clientApply || !f.key || !f.structKey) continue
        const id = `${f.file}||${f.section}||${f.structKey}`
        const g = groups.get(id) ?? { file: f.file, section: f.section, structKey: f.structKey, keys: [] }
        g.keys.push(f.key)
        groups.set(id, g)
      }
    }
    return groups
  }, [schema])

  // Client-mirror mismatch detector. For every ClientApply field the admin has
  // CUSTOMISED on the server (value present and != default), compare the server's
  // effective value against the player's local client Game.ini. Any that differ
  // (or are missing client-side) won't take full effect until mirrored locally.
  //
  // Plus a STRUCTURAL pass: when a client struct box is a partial stub (some
  // members present, some missing), surface every member that's missing or
  // differs — even ones at server default — so clicking Fix rewrites the box
  // whole (the server-side apply reseeds the full struct). This catches a
  // stripped LandsraadSettings box that the value-only pass would miss because
  // the missing members sit at default and so never register as customised.
  const clientMismatches = useMemo<ClientMismatch[]>(() => {
    if (!schema || !cfg || !clientInfo || !clientInfo.exists) return []
    // Struct groups that are a PARTIAL stub client-side: at least one member
    // present AND at least one missing. A complete box (all present) is healthy;
    // an entirely-absent box is "not applied yet" (handled by the value path
    // for any customised members), not a stub — only the partial case is drift.
    const stubGroups = new Set<string>()
    for (const [id, g] of structMemberGroups) {
      let present = 0
      let missing = 0
      for (const mk of g.keys) {
        const v = clientInfo.effectiveByKey?.[mk]
        if (v === undefined || v === null) missing++
        else present++
      }
      if (present > 0 && missing > 0) stubGroups.add(id)
    }
    const out: ClientMismatch[] = []
    for (const cat of schema) {
      for (const f of cat?.fields ?? []) {
        if (!f?.clientApply || !f.key) continue
        const groupId = f.structKey ? `${f.file}||${f.section}||${f.structKey}` : null
        const inStub = groupId ? stubGroups.has(groupId) : false
        const serverValue = currentValue(cfg, f)
        // Client value: prefer the flat section||key, but fall back to the by-key
        // map so struct members (e.g. LandsraadSettings Data=(...) scalars) — which
        // aren't flat keys — are compared by their real client value instead of
        // always reading as missing (which made the mismatch never clear).
        const flat = clientInfo.effective?.[`${f.section}||${f.key}`]
        const raw = (flat === undefined || flat === null)
          ? clientInfo.effectiveByKey?.[f.key]
          : flat
        const clientValue = raw === undefined || raw === null ? null : String(raw)
        if (inStub) {
          if (clientValue !== null && valuesEqual(clientValue, serverValue)) continue
          out.push({ key: f.key, label: f.label, section: f.section, serverValue, clientValue, structural: true })
          continue
        }
        if (!isCustomized(cfg, f)) continue
        if (clientValue !== null && valuesEqual(clientValue, serverValue)) continue
        out.push({ key: f.key, label: f.label, section: f.section, serverValue, clientValue })
      }
    }
    return out
  }, [schema, cfg, clientInfo, structMemberGroups])

  // True when any mismatch comes from a stripped/incomplete client struct box —
  // drives the stronger "your client is missing part of a settings block" copy.
  const hasStructuralDrift = useMemo(() => clientMismatches.some(m => m.structural), [clientMismatches])

  // INI snippet of the SERVER values for the mismatched keys (manual-merge / share).
  const mismatchSnippet = useMemo(() => {
    if (clientMismatches.length === 0) return ''
    const bySection = new Map<string, string[]>()
    for (const m of clientMismatches) {
      const lines = bySection.get(m.section) ?? []
      lines.push(`${m.key}=${m.serverValue}`)
      bySection.set(m.section, lines)
    }
    return [...bySection.entries()]
      .map(([section, lines]) => [`[${section}]`, ...lines].join('\n'))
      .join('\n\n')
  }, [clientMismatches])

  // Stable signature of the current mismatch set: changes only when the set of
  // keys or their server/client values change. Drives "don't re-nag" logic.
  const mismatchSignature = useMemo(() => {
    if (clientMismatches.length === 0) return ''
    return clientMismatches
      .map(m => `${m.section}||${m.key}=${m.serverValue}>${m.clientValue ?? ''}`)
      .sort()
      .join('|')
  }, [clientMismatches])

  const onCopyMismatchSnippet = useCallback(async () => {
    if (!mismatchSnippet) return
    try {
      await navigator.clipboard.writeText(mismatchSnippet)
      setMismatchCopied(true)
      setTimeout(() => setMismatchCopied(false), 1500)
    } catch { /* clipboard may be unavailable; the snippet is still shown */ }
  }, [mismatchSnippet])

  // Auto-surface the popup once per detected mismatch set, but NOT if the user
  // already dismissed this exact set (persisted across reloads). When the
  // mismatch clears (e.g. after a fix), drop any saved dismissal so a future
  // genuine mismatch can surface again.
  useEffect(() => {
    if (mismatchSignature === '') {
      if (mismatchAutoShown) setMismatchAutoShown(false)
      if (mismatchOpen) setMismatchOpen(false)
      if (mismatchDismissedSig) persistMismatchDismissed('')
      return
    }
    if (!mismatchAutoShown && mismatchSignature !== mismatchDismissedSig) {
      setMismatchOpen(true)
      setMismatchAutoShown(true)
    }
  }, [mismatchSignature, mismatchAutoShown, mismatchOpen, mismatchDismissedSig, persistMismatchDismissed])

  // Close the modal without fixing; remember this exact mismatch set so it
  // doesn't auto-pop again until the underlying values change.
  const onDismissMismatch = useCallback(() => {
    persistMismatchDismissed(mismatchSignature)
    setMismatchOpen(false)
    setMismatchFallback(false)
    setMismatchErr(null)
  }, [mismatchSignature, persistMismatchDismissed])

  // Write the server's values into the local client Game.ini. The click itself is
  // the user's consent to edit that file; DST backs it up first. Falls back to a
  // copy-box if DST can't write (no folder / permission).
  const onFixClientMismatch = useCallback(async () => {
    if (clientMismatches.length === 0) return
    setMismatchErr(null)
    setMismatchMsg(null)
    setMismatchFixing(true)
    try {
      const items = clientMismatches.map(m => ({ key: m.key, label: m.label, section: m.section, value: m.serverValue }))
      const r = await applyGameConfigClient(items, clientInfo?.dir)
      setClientInfo(r.client)
      setMismatchMsg(describeClientApply(r, 'Synced'))
      window.setTimeout(() => setMismatchMsg(null), 9000)
      setMismatchOpen(false)
      setMismatchFallback(false)
    } catch (e) {
      setMismatchErr(e instanceof Error ? e.message : String(e))
      setMismatchFallback(true)
    } finally {
      setMismatchFixing(false)
    }
  }, [clientMismatches, clientInfo])

  const refreshClient = useCallback(async () => {
    try {
      const info = await getGameConfigClient()
      setClientInfo(info)
      setClientDirInput(prev => (prev ? prev : info.dir))
      return info
    } catch (e) {
      setClientErr(e instanceof Error ? e.message : String(e))
      return null
    }
  }, [])

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

  const onViewClient = useCallback(async () => {
    setClientErr(null)
    setClientViewOpen(true)
    await refreshClient()
  }, [refreshClient])

  // Open the local client Game.ini in Notepad on this PC (DST runs locally).
  const onOpenInEditor = useCallback(async () => {
    setClientErr(null)
    setClientMsg(null)
    setClientBusy(true)
    try {
      const r = await openGameConfigClientFile(clientInfo?.dir)
      setClientMsg(`Opened ${r.path} in Notepad.`)
      window.setTimeout(() => setClientMsg(null), 5000)
    } catch (e) {
      setClientErr(e instanceof Error ? e.message : String(e))
    } finally {
      setClientBusy(false)
    }
  }, [clientInfo])

  // Explicit permission gate: the admin opts in to having DST also write the
  // client-apply settings into THEIR OWN local client Game.ini.
  const onApplyToClient = useCallback(async () => {
    if (!clientApply || clientApply.items.length === 0) return
    setClientErr(null)
    setClientMsg(null)
    setApplying(true)
    try {
      const r = await applyGameConfigClient(clientApply.items, clientInfo?.dir)
      setClientInfo(r.client)
      setClientMsg(describeClientApply(r))
      setClientApply(null)
    } catch (e) {
      setClientErr(e instanceof Error ? e.message : String(e))
    } finally {
      setApplying(false)
    }
  }, [clientApply, clientInfo])

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

  const dirtyKeys = useMemo(() => {
    const keys: string[] = []
    for (const k of Object.keys(values)) {
      if ((values[k] ?? '') !== (originals[k] ?? '')) keys.push(k)
    }
    return keys
  }, [values, originals])

  // Flat key -> field lookup (for default values, struct flags, etc.).
  const fieldByKey = useMemo(() => {
    const m: Record<string, GameConfigField> = {}
    for (const cat of schema ?? []) for (const f of cat?.fields ?? []) if (f?.key) m[f.key] = f
    return m
  }, [schema])

  // For a client-apply item, decide whether mirroring it ADDS, UPDATES, or
  // REMOVES the key in the client Game.ini, so the modal can show it per-line.
  const clientApplyAction = useCallback((it: { key: string; section: string; value: string }): { label: 'Add' | 'Update' | 'Remove'; cls: string } => {
    const def = fieldByKey[it.key]?.default ?? ''
    if (def !== '' && valuesEqual(it.value, def)) return { label: 'Remove', cls: 'text-danger' }
    const flat = clientInfo?.effective?.[`${it.section}||${it.key}`]
    const cur = (flat === undefined || flat === null) ? clientInfo?.effectiveByKey?.[it.key] : flat
    if (cur === undefined || cur === null || String(cur) === '') return { label: 'Add', cls: 'text-success' }
    return { label: 'Update', cls: 'text-warning' }
  }, [fieldByKey, clientInfo])

  const filteredSchema = useMemo(() => {
    if (!schema) return null
    const q = search.trim().toLowerCase()
    if (!q) return schema
    return schema
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
  }, [schema, search])

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (dirtyKeys.length === 0) return
    setSaving(true)
    setSaveError(null)
    setSavedMsg(null)
    try {
      const updates: Record<string, string> = {}
      for (const k of dirtyKeys) updates[k] = values[k] ?? ''
      const out = await saveGameConfig(updates)
      const next: GameConfigResponse = { available: true, source: out.source, game: out.game, engine: out.engine }
      setCfg(next)
      const seeded = seedValues(schema ?? [], next)
      setValues(seeded)
      setOriginals(seeded)
      const n = out.applied ?? dirtyKeys.length
      setSavedMsg(`Saved ${n} change${n === 1 ? '' : 's'} into the DST-managed block. Tip: use “Backup settings” to snapshot before big changes — DST no longer auto-backs-up on every save.`)
      window.setTimeout(() => setSavedMsg(null), 8000)
      // Some settings (e.g. landclaim limits, building restrictions) are read by
      // BOTH server and client — remind the admin to mirror them on each client.
      const ca = out.clientApply
      setClientApply(ca && ca.items && ca.items.length > 0 ? ca : null)
    } catch (err) {
      setSaveError(err instanceof Error ? err.message : String(err))
    } finally {
      setSaving(false)
    }
  }

  function resetDirty() {
    setValues(originals)
    setSaveError(null)
    setSavedMsg(null)
  }

  const sourcePill = cfg && (
    <span
      className={
        cfg.source === 'live' ? 'pill-success' :
        cfg.source === 'cache' ? 'pill-info' : 'pill-warning'
      }
      title={cfg.source === 'template'
        ? 'No live BG yet — values from setup templates.'
        : cfg.source === 'cache'
          ? 'Paths cached from a prior request this session.'
          : 'Values from the live BG PVC.'}
    >
      <Icon
        name={cfg.source === 'live' ? 'CircleCheck' : cfg.source === 'cache' ? 'Info' : 'AlertTriangle'}
        size={12}
      />
      {cfg.source === 'live' ? 'Live' : cfg.source === 'cache' ? 'Cached' : 'Template'}
    </span>
  )

  return (
    <>
      <PageHeader
        title="Game Config"
        icon="Sliders"
        description="UserGame.ini + UserEngine.ini editor. Edits are tracked in a DST-managed block written to the live battlegroup."
        actions={
          <div className="flex items-center gap-2">
            {sourcePill}
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

      {/* Backup reminder */}
      <div className="card p-4 mb-4 border-ibad/40 bg-ibad/5 text-sm flex items-start gap-3">
        <Icon name="FlaskConical" size={18} className="mt-0.5 shrink-0 text-ibad" />
        <div className="flex-1 min-w-0">
          <p className="text-xs text-text-muted leading-relaxed">
            Game Config writes directly to your live battlegroup&apos;s <span className="font-mono">UserGame.ini</span> /{' '}
            <span className="font-mono">UserEngine.ini</span>. Values are written into a
            DST-managed block. <span className="text-text font-medium">Always click “Backup settings” before making changes</span> so
            you have a restore point — backups are saved on the server next to each file and can be restored via the File Browser.
          </p>
          <p className="text-xs text-warning/90 leading-relaxed mt-1.5">
            Some of these settings may require a battlegroup restart to take effect.
          </p>
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
      </div>

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

      {/* How-it-works note */}
      <div className="card p-3 mb-4 border-border bg-surface-2/40 text-xs text-text-muted flex items-start gap-2">
        <Icon name="Info" size={14} className="mt-0.5 shrink-0 text-accent-bright" />
        <div>
          When you change a setting, DST relocates that setting&apos;s entire section into a managed block at the
          bottom of the file and becomes its owner — keeping one clean copy, preserving structure, and migrating
          any existing managed block. The original file is backed up on the server before every write.
        </div>
      </div>

      {/* Local client config (this PC) */}
      <div className="card p-4 mb-4 border-border">
        <div className="flex items-center justify-between gap-2 mb-2">
          <div className="flex items-center gap-2 text-sm font-semibold text-text">
            <Icon name="MonitorSmartphone" size={15} className="text-accent-bright" />
            Your client config (this PC)
          </div>
          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={() => void onOpenInEditor()}
              disabled={clientBusy}
              className="btn-secondary"
              title="Open your local client Game.ini in Notepad"
            >
              <Icon name="ExternalLink" size={14} /> Open in Notepad
            </button>
            <button
              type="button"
              onClick={() => void onViewClient()}
              className="btn-secondary"
              title="View the contents of your local client Game.ini"
            >
              <Icon name="FileSearch" size={14} /> View client config
            </button>
          </div>
        </div>
        <p className="text-xs text-text-muted mb-3">
          A few settings (landclaim limits, building restrictions) are read by the game client too. DST can mirror
          those into your own client&apos;s <span className="font-mono">Game.ini</span> on this machine when you save —
          with your permission. Point this at your Dune client config folder.
        </p>
        <div className="flex items-center gap-2">
          <input
            type="text"
            value={clientDirInput}
            onChange={e => setClientDirInput(e.target.value)}
            spellCheck={false}
            placeholder={clientInfo?.default ?? '%LOCALAPPDATA%\\DuneSandbox\\Saved\\Config\\WindowsClient'}
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
          <div className="text-[11px] text-text-dim mt-2 font-mono break-all">
            {clientInfo.path}{' '}
            {clientInfo.exists
              ? <span className="text-success">• found</span>
              : clientInfo.dirExists
                ? <span className="text-warning">• Game.ini not present yet (will be created on apply)</span>
                : <span className="text-danger">• folder not found</span>}
          </div>
        )}
      </div>
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
      {saveError && (
        <div className="card p-3 mb-4 border-danger/40 bg-danger/10 text-danger text-sm flex items-center gap-2">
          <Icon name="AlertCircle" size={14} /> {saveError}
        </div>
      )}
      {savedMsg && (
        <div className="card p-3 mb-4 border-success/40 bg-success/10 text-success text-sm flex items-center gap-2">
          <Icon name="CheckCircle2" size={14} /> {savedMsg}
        </div>
      )}
      {mismatchMsg && (
        <div className="card p-3 mb-4 border-success/40 bg-success/10 text-success text-sm flex items-center gap-2">
          <Icon name="CheckCircle2" size={14} /> {mismatchMsg}
        </div>
      )}
      {clientMismatches.length > 0 && !mismatchOpen && (
        <button
          type="button"
          onClick={() => { setMismatchFallback(false); setMismatchErr(null); setMismatchOpen(true) }}
          className="card p-3 mb-4 w-full text-left border-warning/40 bg-warning/10 text-warning text-sm flex items-center gap-2 hover:bg-warning/15"
        >
          <Icon name="MonitorSmartphone" size={14} />
          {hasStructuralDrift
            ? <>Your client is missing part of a settings block — review &amp; fix</>
            : <>{clientMismatches.length} client setting{clientMismatches.length === 1 ? '' : 's'} {clientMismatches.length === 1 ? "doesn't" : "don't"} match the server — review &amp; fix</>}
        </button>
      )}
      {mismatchOpen && clientMismatches.length > 0 && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4"
          onClick={() => onDismissMismatch()}
        >
          <div
            className="card w-full max-w-xl max-h-[85vh] overflow-y-auto border-warning/40 bg-surface text-sm"
            onClick={e => e.stopPropagation()}
          >
            <div className="flex items-start gap-2 p-4">
              <Icon name="MonitorSmartphone" size={18} className="text-warning mt-0.5 shrink-0" />
              <div className="flex-1 min-w-0">
                <div className="font-semibold text-text mb-1">
                  {hasStructuralDrift
                    ? 'Your client is missing part of a settings block'
                    : 'Your client config doesn\u2019t match the server'}
                </div>
                {hasStructuralDrift && (
                  <p className="text-warning mb-2 flex items-start gap-1.5">
                    <Icon name="AlertTriangle" size={14} className="mt-0.5 shrink-0" />
                    <span>
                      Your local client{' '}
                      <span className="font-mono break-all">{clientInfo?.path ?? 'Game.ini'}</span>{' '}
                      has an <strong>incomplete</strong> settings block — it carries only some of the
                      entries the game expects, so the rest silently fall back to built-in defaults
                      in-game (a stripped struct from an older write). Fixing rewrites the whole block.
                    </span>
                  </p>
                )}
                <p className="text-text-muted mb-3">
                  {clientMismatches.length === 1 ? 'This setting is' : 'These settings are'} read by both the
                  server and the game client. Your server uses {clientMismatches.length === 1 ? 'this value' : 'these values'},
                  but your local client{' '}
                  <span className="font-mono break-all">{clientInfo?.path ?? 'Game.ini'}</span>{' '}
                  {hasStructuralDrift
                    ? 'is missing or differs on them'
                    : (clientMismatches.length === 1 ? 'has a different one' : 'has different ones')}. Until they match,
                  the change won&apos;t take full effect for you in-game.
                </p>

                <div className="rounded border border-border overflow-hidden mb-3">
                  <table className="w-full text-xs">
                    <thead className="bg-surface-2 text-text-muted">
                      <tr>
                        <th className="text-left font-medium px-2 py-1">Setting</th>
                        <th className="text-left font-medium px-2 py-1">Server (VM)</th>
                        <th className="text-left font-medium px-2 py-1">Your client</th>
                      </tr>
                    </thead>
                    <tbody>
                      {clientMismatches.map(m => (
                        <tr key={m.key} className="border-t border-border">
                          <td className="px-2 py-1">
                            <div className="text-text">{m.label}</div>
                            <div className="font-mono text-text-dim text-[11px] break-all">[{m.section}] {m.key}</div>
                          </td>
                          <td className="px-2 py-1 font-mono text-success whitespace-nowrap">{m.serverValue}</td>
                          <td className="px-2 py-1 font-mono text-danger whitespace-nowrap">{m.clientValue ?? '(not set)'}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>

                {mismatchErr && (
                  <div className="mb-2 text-danger text-xs flex items-start gap-1">
                    <Icon name="AlertCircle" size={13} className="mt-0.5 shrink-0" /> {mismatchErr}
                  </div>
                )}

                {!mismatchFallback ? (
                  <div className="flex items-center gap-2">
                    <button
                      type="button"
                      onClick={() => void onFixClientMismatch()}
                      disabled={mismatchFixing}
                      className="btn-primary"
                      title="Let DST write the server's values into your own client's Game.ini on this PC"
                    >
                      <Icon name={mismatchFixing ? 'Loader2' : 'MonitorCog'} size={14} className={mismatchFixing ? 'animate-spin' : ''} />
                      {mismatchFixing ? 'Fixing…' : 'Fix my client config'}
                    </button>
                    <button type="button" onClick={() => onDismissMismatch()} className="btn-ghost text-xs">
                      Not now
                    </button>
                  </div>
                ) : (
                  <div>
                    <div className="flex items-center justify-between gap-2 mb-1">
                      <span className="font-medium text-text">DST couldn&apos;t write the file — paste this in yourself</span>
                      <button
                        type="button"
                        onClick={() => void onCopyMismatchSnippet()}
                        className="btn-ghost text-xs"
                        title="Copy the correct INI lines"
                      >
                        <Icon name={mismatchCopied ? 'Check' : 'Copy'} size={13} />
                        {mismatchCopied ? 'Copied' : 'Copy'}
                      </button>
                    </div>
                    <p className="text-text-muted mb-1">
                      Merge these under the matching section headers in{' '}
                      <span className="font-mono break-all">{clientInfo?.path ?? 'your client Game.ini'}</span>:
                    </p>
                    <pre className="px-2 py-1.5 rounded bg-surface-2 text-text text-xs whitespace-pre-wrap break-all overflow-x-auto">{mismatchSnippet}</pre>
                    <button type="button" onClick={() => onDismissMismatch()} className="btn-ghost text-xs mt-2">
                      Close
                    </button>
                  </div>
                )}
                <p className="text-[11px] text-text-dim mt-2">
                  “Fix my client config” only changes{' '}
                  <span className="font-mono break-all">{clientInfo?.path ?? 'your local client Game.ini'}</span>{' '}
                  on this machine (backed up first). It never touches other players&apos; configs.
                </p>
              </div>
              <button
                type="button"
                className="btn-icon shrink-0"
                title="Dismiss"
                onClick={() => onDismissMismatch()}
              >
                <Icon name="X" size={14} />
              </button>
            </div>
          </div>
        </div>
      )}
      {clientApply && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4"
          onClick={() => setClientApply(null)}
        >
          <div
            className="card w-full max-w-lg max-h-[85vh] overflow-y-auto border-warning/40 bg-surface text-sm"
            onClick={e => e.stopPropagation()}
          >
            <div className="flex items-start gap-2 p-4">
              <Icon name="MonitorSmartphone" size={18} className="text-warning mt-0.5 shrink-0" />
              <div className="flex-1 min-w-0">
                <div className="font-semibold text-text mb-1">Also apply these on each player's client</div>
                <p className="text-text-muted mb-2">
                  The setting{clientApply.items.length === 1 ? '' : 's'} below {clientApply.items.length === 1 ? 'is' : 'are'} read by
                  both the server and the game client. The server is updated, but each player must mirror {clientApply.items.length === 1 ? 'it' : 'them'} in
                  their local client config for it to take full effect:
                </p>
                <ul className="space-y-1 mb-2">
                  {clientApply.items.map(it => {
                    const act = clientApplyAction(it)
                    return (
                      <li key={it.key} className="font-mono text-xs text-text flex items-start gap-1.5">
                        <span className={`shrink-0 font-sans font-semibold uppercase text-[10px] px-1.5 py-0.5 rounded bg-surface-2 ${act.cls}`}>{act.label}</span>
                        <span className="min-w-0">
                          <span className="text-text-muted">[{it.section}]</span>{' '}
                          {act.label === 'Remove' ? <span className="line-through text-text-dim">{it.key}={it.value}</span> : <>{it.key}={it.value}</>}
                          <span className="text-text-muted"> — {it.label}</span>
                        </span>
                      </li>
                    )
                  })}
                </ul>
                <p className="text-text-muted">
                  Add {clientApply.items.length === 1 ? 'it' : 'them'} under the matching section in each client's:
                </p>
                <code className="block mt-1 px-2 py-1 rounded bg-surface-2 text-text text-xs break-all">{clientApply.path}</code>

                <div className="mt-3 pt-3 border-t border-border">
                  <div className="flex items-center justify-between gap-2 mb-1">
                    <span className="font-medium text-text">Send this to your other players</span>
                    <button
                      type="button"
                      onClick={() => void onCopyClientSnippet()}
                      className="btn-ghost text-xs"
                      title="Copy the INI lines to share with players who don't run DST"
                    >
                      <Icon name={clientSnippetCopied ? 'Check' : 'Copy'} size={13} />
                      {clientSnippetCopied ? 'Copied' : 'Copy'}
                    </button>
                  </div>
                  <p className="text-text-muted mb-1">
                    Players who don&apos;t run DST can paste these exact lines into their own
                    {' '}<span className="font-mono">{clientApply.path}</span> (merge under the matching section headers):
                  </p>
                  <pre className="px-2 py-1.5 rounded bg-surface-2 text-text text-xs whitespace-pre-wrap break-all overflow-x-auto">{clientSnippet}</pre>
                </div>

                <div className="flex items-center gap-2 mt-3">
                  <button
                    type="button"
                    onClick={() => void onApplyToClient()}
                    disabled={applying}
                    className="btn-primary"
                    title="Let DST write these settings into your own client's Game.ini on this PC"
                  >
                    <Icon name={applying ? 'Loader2' : 'MonitorCog'} size={14} className={applying ? 'animate-spin' : ''} />
                    {applying ? 'Applying…' : 'Apply to my client'}
                  </button>
                  <button type="button" onClick={() => setClientApply(null)} className="btn-ghost text-xs">
                    I&apos;ll do it manually
                  </button>
                </div>
                <p className="text-[11px] text-text-dim mt-2">
                  “Apply to my client” only changes <span className="font-mono break-all">{clientInfo?.path ?? 'your local client Game.ini'}</span> on
                  this machine (backed up first). Other players still apply manually.
                </p>
              </div>
              <button
                type="button"
                className="btn-icon shrink-0"
                title="Dismiss"
                onClick={() => setClientApply(null)}
              >
                <Icon name="X" size={14} />
              </button>
            </div>
          </div>
        </div>
      )}

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
              placeholder="Filter settings…"
              className="w-full pl-9 pr-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm placeholder:text-text-dim focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
            />
          </div>

          <div className="space-y-5">
            {(filteredSchema ?? []).map(cat => (
              <CategoryCard key={cat.category} category={cat.category} count={(cat.fields ?? []).length}>
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
                      />
                    ) : null
                  ))}
                </div>
              </CategoryCard>
            ))}
            {filteredSchema && filteredSchema.length === 0 && (
              <div className="card p-6 text-text-muted text-sm">No settings match “{search}”.</div>
            )}

            <SpicefieldsCard vmRunning={vmRunning} />

            <DefaultsCatalogBrowser vmRunning={vmRunning} onSaved={() => void loadAll()} />

            {cfg && <AdvancedIniBrowser cfg={cfg} />}
          </div>

          <div className="sticky bottom-0 mt-6 -mx-6 px-6 py-3 bg-surface/95 border-t border-border backdrop-blur-sm flex items-center justify-between">
            <div className="text-xs text-text-muted flex items-center gap-4">
              {cfg && (
                <>
                  <span className="font-mono truncate max-w-xs" title={cfg.game.path}>game: {cfg.game.path}</span>
                  <span className="font-mono truncate max-w-xs" title={cfg.engine.path}>engine: {cfg.engine.path}</span>
                </>
              )}
            </div>
            <div className="flex items-center gap-2">
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
                and copy it back over the live file.
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

      {clientViewOpen && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
          onClick={() => setClientViewOpen(false)}
        >
          <div
            className="card w-full max-w-3xl max-h-[85vh] flex flex-col p-0 overflow-hidden"
            onClick={e => e.stopPropagation()}
          >
            <div className="flex items-center justify-between px-5 py-3 border-b border-border">
              <h2 className="text-sm font-semibold text-text flex items-center gap-2">
                <Icon name="MonitorSmartphone" size={16} className="text-accent-bright" />
                Your client config
              </h2>
              <button type="button" className="btn-icon" title="Close" onClick={() => setClientViewOpen(false)}>
                <Icon name="X" size={16} />
              </button>
            </div>
            <div className="px-5 py-4 overflow-y-auto">
              <div className="text-[11px] text-text-dim font-mono break-all mb-3">
                {clientInfo?.path}{' '}
                {clientInfo?.exists
                  ? <span className="text-success">• found</span>
                  : <span className="text-warning">• not present yet</span>}
              </div>
              {!clientInfo?.exists && (
                <div className="text-sm text-text-muted py-4 text-center">
                  No client <span className="font-mono">Game.ini</span> at this location yet. It will be created the
                  first time you apply a client-side setting.
                </div>
              )}
              {clientInfo?.exists && (
                <pre className="text-xs font-mono text-text bg-[#1e1e1e] border border-border rounded-lg p-3 overflow-x-auto max-h-[60vh] overflow-y-auto whitespace-pre leading-relaxed">
                  {clientInfo.raw || '(empty file)'}
                </pre>
              )}
            </div>
            <div className="px-5 py-3 border-t border-border flex items-center justify-between gap-2">
              <span className="text-[11px] text-text-dim">Read-only preview. “Open in Notepad” edits the real file.</span>
              <div className="flex items-center gap-2">
                <button type="button" onClick={() => void onOpenInEditor()} disabled={clientBusy} className="btn-secondary" title="Open this file in Notepad">
                  <Icon name="ExternalLink" size={14} /> Open in Notepad
                </button>
                <button type="button" onClick={() => void refreshClient()} className="btn-secondary" title="Reload">
                  <Icon name="RefreshCw" size={14} /> Refresh
                </button>
                <button type="button" className="btn-primary" onClick={() => setClientViewOpen(false)}>Close</button>
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

function CategoryCard({ category, count, children }: { category: string; count: number; children: React.ReactNode }) {
  return (
    <div className="card p-5">
      <h2 className="text-sm font-semibold uppercase tracking-wider text-accent-bright mb-4 flex items-center gap-2">
        <Icon name="ChevronRight" size={14} /> {category}
        <span className="text-[10px] font-normal text-text-dim normal-case tracking-normal">({count})</span>
      </h2>
      {children}
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
}

// Human-friendly rendering of a raw default value for the grayed "Default:" line.
function formatDefaultDisplay(field: GameConfigField, def: string): string {
  if (def === '') return '(unset)'
  if (field.type === 'select' && field.options) {
    const opt = field.options.find(o => o.value === def)
    return opt ? opt.label : def
  }
  const pair = boolPair(field.type)
  if (pair) return def === pair.on ? 'On' : def === pair.off ? 'Off' : def
  return def
}

function FieldRow({ field, value, onChange, disabled, isDirty, isSet, isCustom, defaultValue, managed }: FieldRowProps) {
  const inputBase =
    'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm ' +
    'placeholder:text-text-dim focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50 ' +
    'disabled:opacity-50 disabled:cursor-not-allowed'

  const pair = boolPair(field.type)
  const isNumber = field.type === 'int' || field.type === 'float'
  const wide = field.wide

  // Whether the current input already equals the Funcom default (numeric/bool
  // aware), so the reset button can be disabled when there's nothing to reset.
  const atDefault = valuesEqual(value, defaultValue)
  const resetToDefault = () => { if (!disabled && !atDefault) onChange(defaultValue) }

  return (
    <div className={wide ? 'md:col-span-2' : ''}>
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

      {field.type === 'select' && field.options ? (
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
        {field.help && <p className="text-xs text-text-dim">{field.help}</p>}
        <span className="text-[10px] font-mono text-text-dim ml-auto truncate" title={`${field.section} / ${field.key}`}>{field.key}</span>
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
  vmRunning, onSaved,
}: {
  vmRunning: boolean
  onSaved: () => void
}) {
  const [open, setOpen] = useState(false)
  const [data, setData] = useState<GameConfigDefaultsResponse | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [fileFilter, setFileFilter] = useState<'all' | 'game' | 'engine'>('all')
  const [expanded, setExpanded] = useState<Set<string>>(() => new Set())
  // sectionName||key  ->  edited value (string). Empty when nothing pending.
  const [edits, setEdits] = useState<Map<string, string>>(() => new Map())
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

  const dirtyCount = edits.size
  const sectionEditCount = (sectionName: string): number => {
    let n = 0
    edits.forEach((_v, k) => { if (k.startsWith(sectionName + '||')) n++ })
    return n
  }

  const sectionsFiltered = useMemo(() => {
    if (!data) return [] as GameConfigDefaultSection[]
    const q = search.trim().toLowerCase()
    return data.sections.filter(s => {
      if (fileFilter !== 'all' && s.file !== fileFilter) return false
      if (!q) return true
      if (s.name.toLowerCase().includes(q)) return true
      return s.keys.some(k => k.key.toLowerCase().includes(q))
    })
  }, [data, search, fileFilter])

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

  const resetEdits = () => { setEdits(new Map()); setSavedMsg(null); setSaveErr(null) }

  const onSave = async () => {
    if (!data || edits.size === 0) return
    setSaving(true); setSaveErr(null); setSavedMsg(null)
    try {
      // Map each pending edit back to its section.file via the loaded catalog.
      const sectionFile = new Map<string, 'game' | 'engine'>()
      for (const s of data.sections) sectionFile.set(s.name, s.file)
      const updates: GameConfigRawUpdate[] = []
      edits.forEach((value, id) => {
        const ix = id.indexOf('||')
        if (ix < 0) return
        const section = id.slice(0, ix)
        const key = id.slice(ix + 2)
        const file = sectionFile.get(section)
        if (!file) return
        updates.push({ file, section, key, value })
      })
      if (updates.length === 0) return
      await saveGameConfigRaw(updates)
      setSavedMsg(`Saved ${updates.length} change${updates.length === 1 ? '' : 's'}.`)
      setEdits(new Map())
      await load(false)
      onSaved()
    } catch (e) {
      setSaveErr(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="card p-5">
      <button
        type="button"
        onClick={() => setOpen(o => !o)}
        className="w-full flex items-center justify-between text-sm font-semibold uppercase tracking-wider text-accent-bright"
      >
        <span className="flex items-center gap-2">
          <Icon name={open ? 'ChevronDown' : 'ChevronRight'} size={14} />
          All default settings (browse &amp; override)
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
  section, expanded, onToggle, editsCount, getEdit, onEdit, searchTerm,
}: {
  section: GameConfigDefaultSection
  expanded: boolean
  onToggle: () => void
  editsCount: number
  getEdit: (key: string) => string | undefined
  onEdit: (key: string, value: string, original: string) => void
  searchTerm: string
}) {
  // If the user is searching for a key, filter the section's visible keys too
  // so deep sections aren't a wall of noise.
  const visibleKeys = useMemo(() => {
    if (!searchTerm) return section.keys
    if (section.name.toLowerCase().includes(searchTerm)) return section.keys
    return section.keys.filter(k => k.key.toLowerCase().includes(searchTerm))
  }, [section, searchTerm])

  return (
    <div className="border border-border rounded-lg overflow-hidden">
      <button
        type="button"
        onClick={onToggle}
        className="w-full flex items-center justify-between px-3 py-2 bg-surface-2 hover:bg-surface-3 transition-colors text-left"
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
          {visibleKeys.map((k, i) => (
            <DefaultsKeyRow
              key={`${k.key}-${i}`}
              k={k}
              pending={getEdit(k.key)}
              onChange={(v) => onEdit(k.key, v, k.current)}
            />
          ))}
        </div>
      )}
    </div>
  )
}

function DefaultsKeyRow({
  k, pending, onChange,
}: {
  k: GameConfigDefaultKey
  pending: string | undefined
  onChange: (v: string) => void
}) {
  const displayed = pending ?? k.current
  const isDirty = pending !== undefined
  // Array keys (+/-) need multi-line edits that the explicit-array save path
  // doesn't model; surface them read-only with a hint for now.
  const isArray = k.isArray

  const inputCls =
    'w-full px-2 py-1 rounded bg-surface border border-border text-text text-xs font-mono ' +
    'focus:outline-none focus:ring-2 focus:ring-accent/40 disabled:opacity-60'

  let control: ReactElement
  if (isArray) {
    control = (
      <span className="text-[11px] font-mono text-text-dim break-all">
        {displayed} <span className="text-warning">[array — edit in INI]</span>
      </span>
    )
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
    <div className="px-3 py-2 grid grid-cols-[minmax(0,2fr)_minmax(0,3fr)_minmax(0,2fr)] gap-3 items-center">
      <span className="font-mono text-[11px] text-text truncate" title={k.key}>
        {isArray && <span className="text-warning mr-1" title="Array entry">[]</span>}
        {k.key}
      </span>
      <div>{control}</div>
      <div className="text-[10px] font-mono text-text-dim truncate flex items-center gap-2" title={`default: ${k.default}`}>
        {isDirty && <span className="px-1 rounded bg-success/15 text-success font-semibold uppercase">edited</span>}
        {!isDirty && k.overridden && <span className="px-1 rounded bg-accent/15 text-accent-bright font-semibold uppercase">overridden</span>}
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
  const [open, setOpen] = useState(false)
  const [file, setFile] = useState<'game' | 'engine'>('game')
  const [showRaw, setShowRaw] = useState(false)

  const bundle = file === 'game' ? cfg.game : cfg.engine

  return (
    <div className="card p-5">
      <button
        type="button"
        onClick={() => setOpen(o => !o)}
        className="w-full flex items-center justify-between text-sm font-semibold uppercase tracking-wider text-accent-bright"
      >
        <span className="flex items-center gap-2">
          <Icon name={open ? 'ChevronDown' : 'ChevronRight'} size={14} /> Advanced — full INI contents
        </span>
        <span className="text-[10px] font-normal text-text-dim normal-case tracking-normal">read-only</span>
      </button>

      {open && (
        <div className="mt-4">
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
      <div className="flex items-center justify-between px-3 py-2 bg-surface-2">
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

