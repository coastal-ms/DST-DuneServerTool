import { useEffect, useMemo, useRef, useState } from 'react'
import { Icon } from '../components/Icon'
import { PageHeader } from '../components/PageHeader'
import { CollapsibleCard } from '../components/CollapsibleCard'
import { ItemPicker } from '../components/ItemPicker'
import { useApi } from '../hooks/useApi'
import {
  connectSolo,
  createSoloBackup,
  deleteSoloBackup,
  discoverSolo,
  fillSoloWaterContainer,
  completeSoloFindTheFremen,
  enableSoloAllSkills,
  grantSoloItems,
  maxSoloAugmentAttributes,
  restoreSoloBackup,
  saveSoloSettings,
  setSoloCurrencies,
  maxSoloSpecializations,
  type SoloBackup,
  type SoloBackupsResponse,
  type SoloInventoryDestination,
  type SoloProfile,
  type SoloRuntime,
  type SoloSettingsResponse,
  type SoloStatus,
} from '../api/solo'
import {
  filterCosmeticsCatalog,
  getCosmeticsCatalog,
  getVehicleKitCatalog,
  type CatalogItem,
  type CosmeticEntry,
  type VehicleKitCatalog,
} from '../api/gameplay'
import { pickLocalFolder } from '../util/pathPicker'

type Tab = 'overview' | 'settings' | 'backups' | 'character' | 'inventory' | 'progression'

const TABS: Array<{ id: Tab; label: string; icon: string }> = [
  { id: 'overview', label: 'Overview', icon: 'LayoutGrid' },
  { id: 'settings', label: 'Settings', icon: 'SlidersHorizontal' },
  { id: 'backups', label: 'Backups', icon: 'ArchiveRestore' },
  { id: 'character', label: 'Character', icon: 'UserRound' },
  { id: 'inventory', label: 'Inventory', icon: 'Package' },
  { id: 'progression', label: 'Progression', icon: 'ChartNoAxesCombined' },
]

export const SOLO_FIRST_USE_STEPS = [
  'Launch Dune: Awakening PTC (or the supported retail build) at least once.',
  'Start or load Solo Mode, enter the world, and wait until the character finishes loading so the game creates and saves game.db.',
  'Quit all the way to the desktop. Do not leave the game, launcher handoff, or anti-cheat process running.',
  'Open DST Solo Mode, select the DuneSandbox Saved folder or exact profile folder, then choose Connect and validate.',
] as const

export const SOLO_ACTION_RULES = [
  {
    title: 'Connect and inspect',
    state: 'Game may be open',
    detail: 'DST reads a shared snapshot and never edits the live save.',
  },
  {
    title: 'Create save backup',
    state: 'Game may be open',
    detail: 'DST takes a stable shared copy and validates it. For a clean milestone backup, exiting the game first is still preferred.',
  },
  {
    title: 'Apply Solo settings',
    state: 'Game must be closed',
    detail: 'DST checks Dune processes, retains the prior INI, writes atomically, and verifies only changed settings.',
  },
  {
    title: 'Items, currencies, and fillables',
    state: 'Game must be closed',
    detail: 'DST retains game.db, performs one verified transaction, and rolls back automatically if replacement verification fails.',
  },
  {
    title: 'Progression actions',
    state: 'Game must be closed',
    detail: 'Each proven PTC progression action runs as one transaction with its own retained pre-progression backup.',
  },
  {
    title: 'Restore save',
    state: 'Game must be closed',
    detail: 'DST validates the selected backup and retains the current game.db as a separate pre-restore backup.',
  },
] as const

const SOLO_INPUT_CLASS = 'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50 disabled:opacity-50 disabled:cursor-not-allowed'
const SOLO_DISABLED_PRIMARY_CLASS = 'disabled:bg-surface-2 disabled:text-text-dim disabled:border disabled:border-border disabled:opacity-100'
export const SOLO_READ_ONLY_SETTINGS = new Set(['DifficultyLevel'])
export const SOLO_HIDDEN_SETTINGS = new Set(['PVPMode'])

const SETTING_GROUPS: Array<{ title: string; keys: string[] }> = [
  {
    title: 'World and economy',
    keys: [
      'DifficultyLevel', 'GatheringAmount', 'CraftingCost',
      'WaterExtractionRate', 'CraftingTimeMultiplier', 'BuildingCostMultiplier',
      'ResourceRespawnSpeed', 'LootRespawnSpeed', 'FuelBurnTimeMultiplier',
      'InventoryVolumeMultiplier',
    ],
  },
  {
    title: 'Player and NPC balance',
    keys: [
      'PlayerDamageToPlayer', 'PlayerDamageToNPC', 'PlayerDamageToVehicle',
      'PlayerStaminaDrain', 'IntelPointsGainMultiplier', 'NPCHealth',
      'NPCDamageToPlayer', 'NPCDamageToNPC', 'NPCRespawnMultiplier',
      'PVPDamageStructures', 'PlayerShieldDamageAbsorptionMultiplier',
      'NPCShieldDamageAbsorptionMultiplier',
    ],
  },
  {
    title: 'Experience and survival',
    keys: [
      'GlobalXpMultiplier', 'CombatXp', 'GatheringXp', 'MissionXp',
      'ItemDurabilityDrainMultiplier', 'bEnableItemMaxDurabilityLoss',
      'HeatBuildupRate', 'ColdBuildupRate', 'ThirstMultiplier',
      'DropEquipmentOnDeath', 'PlayerDeathLootRule',
    ],
  },
  {
    title: 'World threats and building',
    keys: [
      'bAllowDynamicBuildingDamage', 'bAllowSandstorms', 'bAllowSandworms',
      'SandwormConsequences', 'bIsBuildingRestrictionsEnabled', 'FiefdomLimit',
      'BuildingPieceLimitMultiplier', 'MaxLandclaimSegments',
      'bBuildingInfiniteStability', 'BaseBackupToolTimeRestriction',
    ],
  },
  {
    title: 'Landsraad',
    keys: [
      'LandsraadContributionMultiplier', 'LandsraadSpecializationXpMultiplier',
      'LandsraadFactionStandingMultiplier', 'bLandsraadDisableDecreeRerollLimit',
    ],
  },
]

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B'
  const units = ['B', 'KB', 'MB', 'GB']
  let value = bytes
  let unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit += 1
  }
  return `${value.toFixed(unit === 0 ? 0 : 2)} ${units[unit]}`
}

function shortHash(value?: string): string {
  if (!value) return 'Unavailable'
  return `${value.slice(0, 12)}...${value.slice(-8)}`
}

function normalizeWindowsPath(value: string): string {
  return value.replaceAll('/', '\\').replace(/\\+$/, '').toLowerCase()
}

function StatusPill({ ok, children }: { ok: boolean; children: React.ReactNode }) {
  return (
    <span className={`inline-flex items-center gap-1.5 px-2 py-1 rounded border text-xs font-medium ${
      ok
        ? 'bg-success/10 border-success/30 text-success'
        : 'bg-warning/10 border-warning/30 text-warning'
    }`}>
      <span className={`w-1.5 h-1.5 rounded-full ${ok ? 'bg-success' : 'bg-warning'}`} />
      {children}
    </span>
  )
}

export const SOLO_COSMETIC_ENTITLEMENT_WARNING =
  'Grants apply only to this Solo save. They do not create Funcom account ownership or unlock content on official servers.'

export function groupSoloCosmetics(
  catalog: CosmeticEntry[],
  query: string,
): Array<[string, CosmeticEntry[]]> {
  const groups = new Map<string, CosmeticEntry[]>()
  for (const entry of filterCosmeticsCatalog(catalog, query)) {
    const current = groups.get(entry.group)
    if (current) current.push(entry)
    else groups.set(entry.group, [entry])
  }
  return Array.from(groups.entries()).sort(([left], [right]) => left.localeCompare(right))
}

export function getSoloCosmeticBackpackDestination(
  inventories: SoloInventoryDestination[],
): string {
  return inventories.find(inventory => inventory.kind === 'backpack')?.key ?? ''
}

export function getPreferredSoloInventoryDestination(
  inventories: SoloInventoryDestination[],
): string {
  return inventories.find(inventory => inventory.kind === 'backpack')?.key
    ?? inventories[0]?.key
    ?? ''
}

export function buildSoloCosmeticGrant(
  templateId: string,
  inventories: SoloInventoryDestination[],
): {
  destination: string
  items: Array<{ templateId: string; quantity: number; quality: number }>
} {
  return {
    destination: getSoloCosmeticBackpackDestination(inventories),
    items: [{ templateId, quantity: 1, quality: 0 }],
  }
}

export function SoloCosmeticGrantCard({
  busy,
  disabled,
  loadCatalog = getCosmeticsCatalog,
  onGrant,
}: {
  busy: boolean
  disabled: boolean
  loadCatalog?: () => Promise<CosmeticEntry[]>
  onGrant: (templateId: string, label: string) => Promise<void>
}) {
  const [catalog, setCatalog] = useState<CosmeticEntry[] | null>(null)
  const [catalogError, setCatalogError] = useState('')
  const [query, setQuery] = useState('')
  const [selected, setSelected] = useState('')

  useEffect(() => {
    let active = true
    loadCatalog()
      .then(entries => {
        if (active) setCatalog(entries)
      })
      .catch(error => {
        if (active) setCatalogError(error instanceof Error ? error.message : String(error))
      })
    return () => { active = false }
  }, [loadCatalog])

  const groups = useMemo(() => groupSoloCosmetics(catalog ?? [], query), [catalog, query])
  const matches = useMemo(() => groups.flatMap(([, entries]) => entries), [groups])
  const chosen = matches.find(entry => entry.template === selected)
  const controlsDisabled = disabled || busy

  return (
    <div className="card p-5 xl:col-span-2">
      <h3 className="font-semibold mb-1">Grant Cosmetic / Building Set</h3>
      <p className="text-xs text-text-muted mb-4">
        Delivers one unlock item to the Solo backpack for processing on next login.
      </p>
      <div className="rounded border border-warning/30 bg-warning/5 p-3 mb-4 text-xs text-text-muted">
        {SOLO_COSMETIC_ENTITLEMENT_WARNING} Some developer or entitlement entries may remain ordinary inventory items and do nothing. Owned-state detection is not available for Solo yet, so the full catalog is shown and duplicate grants are possible.
      </div>
      {catalogError ? (
        <div className="text-xs text-danger">Cosmetics catalog failed to load: {catalogError}</div>
      ) : !catalog ? (
        <div className="text-xs text-text-dim flex items-center gap-2">
          <Icon name="LoaderCircle" size={13} className="animate-spin" /> Loading cosmetics catalog...
        </div>
      ) : (
        <>
          <input
            type="text"
            value={query}
            disabled={controlsDisabled}
            placeholder="Search name, template id, or group"
            onChange={event => setQuery(event.target.value)}
            className={SOLO_INPUT_CLASS}
          />
          <select
            value={selected}
            disabled={controlsDisabled}
            onChange={event => setSelected(event.target.value)}
            className={`${SOLO_INPUT_CLASS} mt-3`}
            style={{ colorScheme: 'dark' }}
          >
            <option value="">Choose a cosmetic or building set... ({matches.length})</option>
            {groups.map(([group, entries]) => (
              <optgroup key={group} label={`${group} (${entries.length})`}>
                {entries.map(entry => (
                  <option key={entry.template} value={entry.template}>{entry.name}</option>
                ))}
              </optgroup>
            ))}
          </select>
          {chosen && <p className="text-[11px] font-mono text-text-dim truncate mt-2">{chosen.template}</p>}
          <button
            className={`btn-primary w-full mt-4 justify-center ${SOLO_DISABLED_PRIMARY_CLASS}`}
            disabled={controlsDisabled || !chosen}
            onClick={() => {
              if (chosen) void onGrant(chosen.template, chosen.name)
            }}
          >
            <Icon name={busy ? 'LoaderCircle' : 'Shirt'} size={14} className={busy ? 'animate-spin' : ''} />
            Grant unlock
          </button>
        </>
      )}
    </div>
  )
}

export function SoloMode() {
  const [tab, setTab] = useState<Tab>('overview')
  const statusState = useApi<SoloStatus>('/api/solo/status')
  const runtimeState = useApi<SoloRuntime>('/api/solo/runtime', { intervalMs: 3000 })
  const connected = statusState.data?.connected === true
  const settingsState = useApi<SoloSettingsResponse>('/api/solo/settings', { enabled: connected })
  const backupsState = useApi<SoloBackupsResponse>('/api/solo/backups', { enabled: connected })
  const [dataRoot, setDataRoot] = useState('')
  const [selectedDb, setSelectedDb] = useState('')
  const [discoveredProfiles, setDiscoveredProfiles] = useState<SoloProfile[]>([])
  const [draft, setDraft] = useState<Record<string, string>>({})
  const [busy, setBusy] = useState<string | null>(null)
  const [notice, setNotice] = useState<{ kind: 'ok' | 'warn' | 'err'; text: string } | null>(null)
  const [itemTemplate, setItemTemplate] = useState('')
  const [itemDisplay, setItemDisplay] = useState<string | undefined>()
  const [itemQuantity, setItemQuantity] = useState(1)
  const [itemQuality, setItemQuality] = useState(0)
  const [inventoryDestination, setInventoryDestination] = useState('')
  const [vehicleKits, setVehicleKits] = useState<VehicleKitCatalog | null>(null)
  const [vehicleKitId, setVehicleKitId] = useState('')
  const [solariDraft, setSolariDraft] = useState(0)
  const [scripDraft, setScripDraft] = useState(0)
  const initializedFromStatus = useRef(false)

  useEffect(() => {
    if (!statusState.data || initializedFromStatus.current) return
    initializedFromStatus.current = true
    setDataRoot(statusState.data.dataRoot)
    setSelectedDb(statusState.data.dbPath)
    setDiscoveredProfiles(statusState.data.profiles)
  }, [statusState.data])

  useEffect(() => {
    if (!settingsState.data) return
    setDraft(Object.fromEntries(settingsState.data.entries.map(entry => [entry.key, entry.value])))
  }, [settingsState.data])

  useEffect(() => {
    const inventories = statusState.data?.inspection?.inventories ?? []
    if (inventories.length === 0) {
      setInventoryDestination('')
      return
    }
    if (!inventories.some(inventory => inventory.key === inventoryDestination)) {
      setInventoryDestination(getPreferredSoloInventoryDestination(inventories))
    }
  }, [statusState.data?.inspection?.inventories, inventoryDestination])

  useEffect(() => {
    const currencies = statusState.data?.inspection?.currencies
    if (!currencies) return
    setSolariDraft(currencies.solari)
    setScripDraft(currencies.scrip)
  }, [statusState.data?.inspection?.currencies])

  useEffect(() => {
    if (!connected || vehicleKits) return
    getVehicleKitCatalog()
      .then(setVehicleKits)
      .catch(() => setVehicleKits(null))
  }, [connected, vehicleKits])

  const settingsByKey = useMemo(
    () => new Map((settingsState.data?.entries ?? []).map(entry => [entry.key, entry])),
    [settingsState.data],
  )
  const changedSettings = useMemo(() => {
    const changed: Record<string, string> = {}
    for (const entry of settingsState.data?.entries ?? []) {
      if (SOLO_READ_ONLY_SETTINGS.has(entry.key) || SOLO_HIDDEN_SETTINGS.has(entry.key)) continue
      const next = draft[entry.key] ?? ''
      if (next !== entry.value) changed[entry.key] = next
    }
    return changed
  }, [draft, settingsState.data])

  const scanPath = async (path: string) => {
    const discovery = await discoverSolo(path)
    setDataRoot(discovery.dataRoot)
    setDiscoveredProfiles(discovery.profiles)
    setSelectedDb(discovery.suggestedDbPath)
    return discovery
  }

  const browse = async () => {
    const path = await pickLocalFolder({
      initialPath: dataRoot,
      description: 'Select Dune Solo Saved folder or the exact profile folder containing game.db',
    })
    if (path) {
      setBusy('discover')
      setNotice(null)
      try {
        const discovery = await scanPath(path)
        if (discovery.profiles.length > 1 && !discovery.suggestedDbPath) {
          setNotice({ kind: 'ok', text: `Found ${discovery.profiles.length} Solo saves. Choose the profile to connect.` })
        }
      } catch (error) {
        setDataRoot(path)
        setSelectedDb('')
        setDiscoveredProfiles([])
        setNotice({ kind: 'err', text: error instanceof Error ? error.message : String(error) })
      } finally {
        setBusy(null)
      }
    }
  }

  const connect = async () => {
    setBusy('connect')
    setNotice(null)
    try {
      const discovery = await scanPath(dataRoot)
      const dbPath = selectedDb || discovery.suggestedDbPath
      if (!dbPath && discovery.profiles.length > 1) {
        setNotice({ kind: 'err', text: 'Choose which Solo profile to connect.' })
        return
      }
      const result = await connectSolo(discovery.dataRoot, dbPath)
      setDataRoot(result.dataRoot)
      setSelectedDb(result.dbPath)
      setDiscoveredProfiles(result.profiles)
      setNotice({ kind: 'ok', text: 'Solo save connected and validated.' })
      await statusState.refresh()
      await runtimeState.refresh()
      await settingsState.refresh()
      await backupsState.refresh()
    } catch (error) {
      setNotice({ kind: 'err', text: error instanceof Error ? error.message : String(error) })
    } finally {
      setBusy(null)
    }
  }

  const gameRunning = runtimeState.data?.gameRunning ?? statusState.data?.gameRunning ?? false
  const selectionMatchesActive = connected
    && normalizeWindowsPath(dataRoot) === normalizeWindowsPath(statusState.data?.dataRoot ?? '')
    && normalizeWindowsPath(selectedDb) === normalizeWindowsPath(statusState.data?.dbPath ?? '')
  const canMutateActiveProfile = selectionMatchesActive && busy === null

  const saveSettings = async () => {
    if (!selectionMatchesActive) {
      setNotice({ kind: 'err', text: 'Connect and validate the selected Solo profile before applying settings.' })
      return
    }
    if (gameRunning) {
      setNotice({ kind: 'err', text: 'Close Dune: Awakening completely before applying Solo settings.' })
      return
    }
    if (!window.confirm(
      'Confirm Dune: Awakening is fully closed.\n\n'
      + 'DST will retain a copy of ServerCustomSettings.ini, replace the file, and verify every changed value.',
    )) return
    setBusy('settings')
    setNotice(null)
    try {
      const result = await saveSoloSettings(changedSettings, statusState.data?.profileToken ?? '')
      setNotice({
        kind: 'ok',
        text: result.backupPath
          ? `Solo settings applied and verified. Backup: ${result.backupPath}`
          : 'Solo settings created and verified.',
      })
      await settingsState.refresh()
      await statusState.refresh()
      await runtimeState.refresh()
    } catch (error) {
      setNotice({ kind: 'err', text: error instanceof Error ? error.message : String(error) })
    } finally {
      setBusy(null)
    }
  }

  const createBackup = async () => {
    if (!selectionMatchesActive) {
      setNotice({ kind: 'err', text: 'Connect and validate the selected Solo profile before creating a backup.' })
      return
    }
    setBusy('backup')
    setNotice(null)
    try {
      const result = await createSoloBackup(statusState.data?.profileToken ?? '')
      setNotice({ kind: 'ok', text: `Validated Solo backup created: ${result.path}` })
      await backupsState.refresh()
    } catch (error) {
      setNotice({ kind: 'err', text: error instanceof Error ? error.message : String(error) })
    } finally {
      setBusy(null)
    }
  }

  const restoreBackup = async (backup: SoloBackup) => {
    if (!selectionMatchesActive) {
      setNotice({ kind: 'err', text: 'Connect and validate the selected Solo profile before restoring a backup.' })
      return
    }

    if (gameRunning) {
      setNotice({ kind: 'err', text: 'Close Dune: Awakening completely before restoring a Solo save.' })
      return
    }
    if (!window.confirm(
      `Restore ${backup.name}?\n\n`
      + 'DST will validate this backup, preserve the current save as a separate pre-restore backup, '
      + 'atomically replace game.db, and verify the restored wrapper and SQLite database.',
    )) return
    setBusy(`restore:${backup.relativePath}`)
    setNotice(null)
    try {
      const result = await restoreSoloBackup(backup.relativePath, statusState.data?.profileToken ?? '')
      setNotice({ kind: 'ok', text: `Restore verified. Previous save retained at ${result.safetyBackup}` })
      await Promise.all([statusState.refresh(), runtimeState.refresh(), backupsState.refresh()])
    } catch (error) {
      setNotice({ kind: 'err', text: error instanceof Error ? error.message : String(error) })
    } finally {
      setBusy(null)
    }
  }

  const deleteBackup = async (backup: SoloBackup) => {
    if (!selectionMatchesActive) {
      setNotice({ kind: 'err', text: 'Connect and validate the selected Solo profile before deleting a backup.' })
      return
    }
    if (!window.confirm(
      `Permanently delete ${backup.name}?\n\n`
      + 'This removes only this retained backup. It does not change the live Solo save and cannot be undone.',
    )) return
    setBusy(`delete:${backup.relativePath}`)
    setNotice(null)
    try {
      await deleteSoloBackup(
        backup.relativePath,
        statusState.data?.profileToken ?? '',
      )
      setNotice({ kind: 'ok', text: `Deleted Solo backup ${backup.name}.` })
      await backupsState.refresh()
    } catch (error) {
      setNotice({ kind: 'err', text: error instanceof Error ? error.message : String(error) })
    } finally {
      setBusy(null)
    }
  }

  const giveSoloItems = async (
    items: Array<{ templateId: string; quantity: number; quality: number }>,
    label: string,
    destination = inventoryDestination,
    targetLabel = 'selected Solo inventory',
  ) => {
    if (!selectionMatchesActive) {
      setNotice({ kind: 'err', text: 'Connect and validate the selected Solo profile before giving items.' })
      return
    }
    if (gameRunning) {
      setNotice({ kind: 'err', text: 'Close Dune: Awakening completely before giving Solo items.' })
      return
    }
    if (!destination) {
      setNotice({ kind: 'err', text: 'Choose a backpack or Developer Storage destination.' })
      return
    }
    if (!window.confirm(
      `Give ${label} to the ${targetLabel}?\n\n`
      + 'Dune: Awakening must be fully closed. DST will retain the current game.db, '
      + 'apply the item grant transactionally, run integrity and foreign-key checks, '
      + 'replace the save atomically, and verify the result.',
    )) return

    setBusy('give-items')
    setNotice(null)
    try {
      const result = await grantSoloItems(
        destination,
        items,
        statusState.data?.profileToken ?? '',
      )
      setNotice({
        kind: 'ok',
        text: `${label} granted and verified. Previous save retained at ${result.safetyBackup}`,
      })
      await Promise.all([statusState.refresh(), runtimeState.refresh(), backupsState.refresh()])
    } catch (error) {
      setNotice({ kind: 'err', text: error instanceof Error ? error.message : String(error) })
    } finally {
      setBusy(null)
    }
  }

  const giveOneItem = async () => {
    if (!itemTemplate.trim()) {
      setNotice({ kind: 'err', text: 'Choose an item from the catalog.' })
      return
    }
    const quantity = Math.max(1, Math.min(100000, Math.trunc(itemQuantity || 1)))
    const quality = Math.max(0, Math.min(5, Math.trunc(itemQuality || 0)))
    await giveSoloItems(
      [{
        templateId: itemTemplate.trim(),
        quantity,
        quality,
      }],
      itemDisplay ? `${quantity} x ${itemDisplay}` : `${quantity} x ${itemTemplate}`,
    )
  }

  const giveVehicleKit = async () => {
    const kit = vehicleKits?.vehicles.find(vehicle => vehicle.id === vehicleKitId)
    if (!kit || kit.kit.length === 0) {
      setNotice({ kind: 'err', text: 'Choose a vehicle kit with deliverable parts.' })
      return
    }
    const templates = [...kit.kit, ...kit.unique, vehicleKits!.fuelTemplate, vehicleKits!.torchTemplate]
    const uniqueTemplates = [...new Set(templates)]
    await giveSoloItems(
      uniqueTemplates.map(templateId => ({
        templateId,
        quantity: Math.max(1, Math.trunc(kit.qty?.[templateId] ?? 1)),
        quality: 0,
      })),
      `${kit.label} vehicle kit`,
    )
  }

  const saveCurrencies = async () => {
    if (!selectionMatchesActive) {
      setNotice({ kind: 'err', text: 'Connect and validate the selected Solo profile before setting currencies.' })
      return
    }

    if (gameRunning) {
      setNotice({ kind: 'err', text: 'Close Dune: Awakening completely before setting Solo currencies.' })
      return
    }
    const solari = Math.max(0, Math.min(2_000_000_000, Math.trunc(solariDraft || 0)))
    const scrip = Math.max(0, Math.min(2_000_000_000, Math.trunc(scripDraft || 0)))
    if (!window.confirm(
      `Set Solo balances to ${solari.toLocaleString()} Solari and ${scrip.toLocaleString()} Landsraad Scrip?\n\n`
      + 'DST will retain the current game.db and verify both balances before replacing the save.',
    )) return
    setBusy('currencies')
    setNotice(null)
    try {
      const result = await setSoloCurrencies(
        solari,
        scrip,
        statusState.data?.profileToken ?? '',
      )
      setNotice({
        kind: 'ok',
        text: `Currencies set and verified. Previous save retained at ${result.safetyBackup}`,
      })
      await Promise.all([statusState.refresh(), runtimeState.refresh(), backupsState.refresh()])
    } catch (error) {
      setNotice({ kind: 'err', text: error instanceof Error ? error.message : String(error) })
    } finally {
      setBusy(null)
    }
  }

  const fillWaterContainer = async (itemId: number, label: string, capacity: number) => {
    if (!selectionMatchesActive) {
      setNotice({ kind: 'err', text: 'Connect and validate the selected Solo profile before filling an item.' })
      return
    }
    if (gameRunning) {
      setNotice({ kind: 'err', text: 'Close Dune: Awakening completely before filling a Solo item.' })
      return
    }
    if (!window.confirm(
      `Fill ${label} to ${capacity.toLocaleString()} mL?\n\n`
      + 'DST will retain the current game.db, update only this item, and verify the result.',
    )) return
    setBusy(`fill:${itemId}`)
    setNotice(null)
    try {
      const result = await fillSoloWaterContainer(
        itemId,
        statusState.data?.profileToken ?? '',
      )
      setNotice({
        kind: 'ok',
        text: `${label} filled and verified. Previous save retained at ${result.safetyBackup}`,
      })
      await Promise.all([statusState.refresh(), runtimeState.refresh(), backupsState.refresh()])
    } catch (error) {
      setNotice({ kind: 'err', text: error instanceof Error ? error.message : String(error) })
    } finally {
      setBusy(null)
    }
  }

  const maxAugmentAttributes = async () => {
    if (!selectionMatchesActive) {
      setNotice({ kind: 'err', text: 'Connect and validate the selected Solo profile before changing augments.' })
      return
    }
    if (gameRunning) {
      setNotice({ kind: 'err', text: 'Close Dune: Awakening completely before changing Solo augments.' })
      return
    }
    if (!window.confirm(
      'Max every non-zero attribute roll on the Solo character’s carried augments?\n\n'
      + 'This action preserves zero and non-numeric entries, excludes Developer Storage, '
      + 'retains the current game.db, and verifies the write before replacing the save. Relog required.',
    )) return
    setBusy('max-augments')
    setNotice(null)
    try {
      const result = await maxSoloAugmentAttributes(statusState.data?.profileToken ?? '')
      setNotice(result.updated > 0
        ? {
            kind: 'ok',
            text: `Maximized attributes on ${result.updated} carried augment(s). Previous save retained at ${result.safetyBackup}`,
          }
        : {
            kind: 'warn',
            text: 'No carried augments with attribute rolls were found. Developer Storage is intentionally excluded.',
          })
      await Promise.all([statusState.refresh(), runtimeState.refresh(), backupsState.refresh()])
    } catch (error) {
      setNotice({ kind: 'err', text: error instanceof Error ? error.message : String(error) })
    } finally {
      setBusy(null)
    }
  }

  const runProgressionAction = async (
    key: string,
    label: string,
    action: (profileToken: string) => Promise<{ safetyBackup: string }>,
  ) => {
    if (!selectionMatchesActive) {
      setNotice({ kind: 'err', text: 'Connect and validate the selected Solo profile before changing progression.' })
      return
    }
    if (gameRunning) {
      setNotice({ kind: 'err', text: 'Close Dune: Awakening completely before changing Solo progression.' })
      return
    }
    if (!window.confirm(
      `${label}?\n\n`
      + 'This PTC-only action retains the current game.db, writes one transaction, verifies progression semantics and SQLite integrity, then replaces the save atomically.',
    )) return
    setBusy(`progression:${key}`)
    setNotice(null)
    try {
      const result = await action(statusState.data?.profileToken ?? '')
      setNotice({
        kind: 'ok',
        text: `${label} completed and verified. Previous save retained at ${result.safetyBackup}`,
      })
      await Promise.all([statusState.refresh(), runtimeState.refresh(), backupsState.refresh()])
    } catch (error) {
      setNotice({ kind: 'err', text: error instanceof Error ? error.message : String(error) })
    } finally {
      setBusy(null)
    }
  }

  const status = statusState.data
  const runtime = runtimeState.data
  const inspection = status?.inspection

  return (
    <>
      <PageHeader
        title="Solo Mode"
        icon="Orbit"
        description="Manage one local Dune: Awakening Solo save without a VM, battlegroup, or server injection."
        actions={
          <button
            className="btn-secondary"
            onClick={() => void Promise.all([statusState.refresh(), runtimeState.refresh()])}
            disabled={statusState.loading}
          >
            <Icon name="RefreshCw" size={14} className={statusState.loading ? 'animate-spin' : ''} />
            Refresh
          </button>
        }
      />

      <div className="rounded-lg border border-sky-400/30 bg-sky-400/5 px-4 py-3 mb-5 text-sm">
        <div className="flex items-start gap-2">
          <Icon name="FlaskConical" size={16} className="text-sky-400 mt-0.5 shrink-0" />
          <div>
            <div className="font-medium text-sky-300">PTC preview adapter</div>
            <p className="text-text-muted mt-0.5">
              Current support targets the proven PTC wrapper-v1 save. Retail will use a separate versioned adapter after its paths and schema are verified.
            </p>
          </div>
        </div>
      </div>

      {notice && (
        <div role="alert" className={`card p-3 mb-4 text-sm flex items-start gap-2 ${
          notice.kind === 'ok'
            ? 'border-success/40 text-success'
            : notice.kind === 'warn'
              ? 'border-warning/40 text-warning'
              : 'border-danger/40 text-danger'
        }`}>
          <Icon name={notice.kind === 'ok' ? 'CheckCircle2' : notice.kind === 'warn' ? 'ShieldAlert' : 'AlertCircle'} size={15} className="mt-0.5 shrink-0" />
          <span className="whitespace-pre-wrap break-words">{notice.text}</span>
        </div>
      )}

      {connected && !selectionMatchesActive && (
        <div role="status" className="card p-3 mb-4 text-sm border-warning/40 text-warning flex items-start gap-2">
          <Icon name="ShieldAlert" size={15} className="mt-0.5 shrink-0" />
          <span>
            Folder or profile selection changed. Existing settings and backups remain read-only until the new selection is connected and validated.
          </span>
        </div>
      )}

      <CollapsibleCard
        id="solo-first-use"
        title="Before first use"
        icon="ListChecks"
        subtitle="Create a real Solo save once before asking DST to manage it."
        summary="Launch once, enter Solo, exit fully"
      >
        <div className="grid grid-cols-1 xl:grid-cols-[1.15fr_1fr] gap-5">
          <ol className="space-y-3">
            {SOLO_FIRST_USE_STEPS.map((step, index) => (
              <li key={step} className="flex items-start gap-3 text-sm">
                <span className="w-6 h-6 rounded-full border border-accent/35 bg-accent/10 text-accent-bright flex items-center justify-center text-xs font-semibold shrink-0">
                  {index + 1}
                </span>
                <span className="pt-0.5">{step}</span>
              </li>
            ))}
          </ol>
          <div className="rounded-lg border border-border bg-surface-2/50 p-4">
            <div className="font-medium text-sm mb-3">When the game can be open</div>
            <div className="space-y-3">
              {SOLO_ACTION_RULES.map(rule => {
                const closed = rule.state.includes('must')
                return (
                  <div key={rule.title} className="text-sm">
                    <div className="flex items-center justify-between gap-3">
                      <span className="font-medium">{rule.title}</span>
                      <span className={`text-[10px] uppercase tracking-wider px-1.5 py-0.5 rounded border ${
                        closed
                          ? 'border-warning/35 bg-warning/10 text-warning'
                          : 'border-success/35 bg-success/10 text-success'
                      }`}>
                        {rule.state}
                      </span>
                    </div>
                    <p className="text-xs text-text-muted mt-1">{rule.detail}</p>
                  </div>
                )
              })}
            </div>
          </div>
        </div>
        <div className="mt-4 rounded border border-warning/30 bg-warning/5 px-3 py-2 text-xs text-text-muted flex items-start gap-2">
          <Icon name="ShieldCheck" size={14} className="text-warning mt-0.5 shrink-0" />
          <span>
            After applying settings or restoring a save, launch Solo Mode and verify the result in game before removing any retained backup. DST does not automatically prune Solo backups.
          </span>
        </div>
      </CollapsibleCard>

      <CollapsibleCard
        id="solo-connection"
        title="Solo save connection"
        icon="FolderCog"
        subtitle="Auto-detect the PTC save or choose a future retail/custom data folder."
        summary={connected ? 'Connected' : 'Not connected'}
      >
        <div className="space-y-3">
          <label className="block">
            <span className="text-xs text-text-muted">Solo data folder</span>
            <div className="flex gap-2 mt-1">
              <input
                className={`${SOLO_INPUT_CLASS} font-mono text-xs flex-1`}
                value={dataRoot}
                onChange={event => {
                  setDataRoot(event.target.value)
                  setSelectedDb('')
                  setDiscoveredProfiles([])
                }}
                placeholder="%LOCALAPPDATA%\DuneSandbox\Saved"
              />
              <button type="button" className="btn-secondary" onClick={() => void browse()}>
                <Icon name="FolderOpen" size={14} /> Browse
              </button>
            </div>
          </label>

          {discoveredProfiles.length > 1 && (
            <label className="block">
              <span className="text-xs text-text-muted">Solo profile</span>
              <select
                className={`${SOLO_INPUT_CLASS} mt-1`}
                style={{ colorScheme: 'dark' }}
                value={selectedDb}
                onChange={event => setSelectedDb(event.target.value)}
              >
                <option value="">Choose one save...</option>
                {discoveredProfiles.map(profile => (
                  <option key={profile.dbPath} value={profile.dbPath}>
                    {profile.channel} / {profile.id}
                  </option>
                ))}
              </select>
            </label>
          )}

          <div className="flex items-center justify-between gap-3">
            <div className="text-xs text-text-dim break-all">
              {status?.dbPath || 'No game.db selected.'}
            </div>
            <button className={`btn-primary shrink-0 ${SOLO_DISABLED_PRIMARY_CLASS}`} onClick={() => void connect()} disabled={!dataRoot || busy !== null}>
              <Icon name={busy === 'connect' ? 'LoaderCircle' : 'PlugZap'} size={14} className={busy === 'connect' ? 'animate-spin' : ''} />
              Connect and validate
            </button>
          </div>
        </div>
      </CollapsibleCard>

      <div className="flex items-center gap-1 mb-5 border-b border-border overflow-x-auto">
        {TABS.map(item => (
          <button
            key={item.id}
            onClick={() => setTab(item.id)}
            className={`flex items-center gap-2 px-4 py-2.5 text-sm font-medium border-b-2 -mb-px transition-colors whitespace-nowrap ${
              tab === item.id
                ? 'border-accent text-accent-bright'
                : 'border-transparent text-text-muted hover:text-text'
            }`}
          >
            <Icon name={item.icon} size={15} /> {item.label}
          </button>
        ))}
      </div>

      {tab === 'overview' && (
        <div className="grid grid-cols-1 xl:grid-cols-2 gap-4">
          <div className="card p-5">
            <div className="flex items-center justify-between gap-3 mb-4">
              <h2 className="font-semibold flex items-center gap-2"><Icon name="Activity" size={16} /> Runtime safety</h2>
              <StatusPill ok={!gameRunning}>{gameRunning ? 'Game running - writes locked' : 'Game closed - writes available'}</StatusPill>
            </div>
            <dl className="grid grid-cols-[9rem_1fr] gap-x-3 gap-y-2 text-sm">
              <dt className="text-text-muted">Adapter</dt><dd className="font-mono">{status?.adapter ?? 'ptc-auto'}</dd>
              <dt className="text-text-muted">Platform</dt><dd>{status?.platform || runtime?.platform || 'Unknown'}</dd>
              <dt className="text-text-muted">Helper</dt><dd>{(runtime?.helperAvailable ?? status?.helperAvailable) ? 'Available' : 'Missing'}</dd>
              <dt className="text-text-muted">Profiles found</dt><dd>{discoveredProfiles.length}</dd>
              <dt className="text-text-muted">Map seed</dt>
              <dd className="font-mono">{inspection?.mapSeed ?? 'Unavailable'}</dd>
              <dt className="text-text-muted">Process state</dt>
              <dd>{runtime?.processes.length ? runtime.processes.map(process => `${process.name} (${process.pid})`).join(', ') : 'No Dune process detected'}</dd>
            </dl>
          </div>

          <div className="card p-5">
            <div className="flex items-center justify-between gap-3 mb-4">
              <h2 className="font-semibold flex items-center gap-2"><Icon name="Database" size={16} /> Save health</h2>
              <StatusPill ok={inspection?.integrity === 'ok' && inspection?.foreignKeyViolations === 0 && inspection?.characterCount === 1}>
                {inspection ? 'Validated' : 'Unavailable'}
              </StatusPill>
            </div>
            {inspection ? (
              <dl className="grid grid-cols-[9rem_1fr] gap-x-3 gap-y-2 text-sm">
                <dt className="text-text-muted">Wrapper</dt><dd>v{inspection.wrapperVersion}</dd>
                <dt className="text-text-muted">SQLite</dt><dd>{formatBytes(inspection.actualSqliteBytes)}</dd>
                <dt className="text-text-muted">Tables</dt><dd>{inspection.tableCount}</dd>
                <dt className="text-text-muted">Characters</dt><dd>{inspection.characterCount}</dd>
                <dt className="text-text-muted">Integrity</dt><dd>{inspection.integrity}</dd>
                <dt className="text-text-muted">Foreign keys</dt><dd>{inspection.foreignKeyViolations} violation(s)</dd>
                <dt className="text-text-muted">Schema</dt><dd className="font-mono text-xs" title={inspection.schemaFingerprint}>{shortHash(inspection.schemaFingerprint)}</dd>
              </dl>
            ) : (
              <p className="text-sm text-text-muted">{status?.inspectionError || 'Connect a Solo save to inspect it.'}</p>
            )}
          </div>
        </div>
      )}

      {tab === 'settings' && (
        <div className="space-y-4">
          {!connected ? (
            <div className="card p-5 text-sm text-text-muted">Connect a Solo save first.</div>
          ) : settingsState.loading && !settingsState.data ? (
            <div className="card p-5 text-sm text-text-muted">Loading Solo settings...</div>
          ) : (
            <>
              {SETTING_GROUPS.map(group => (
                <CollapsibleCard key={group.title} id={`solo-settings-${group.title.toLowerCase().replaceAll(' ', '-')}`} title={group.title} icon="SlidersHorizontal">
                  <div className="grid grid-cols-1 lg:grid-cols-2 gap-3">
                    {group.keys.map(key => (
                      <label key={key} className="block">
                        <span className="text-xs text-text-muted">
                          {key}{SOLO_READ_ONLY_SETTINGS.has(key) ? ' (set in game)' : ''}
                        </span>
                        <input
                          className={`${SOLO_INPUT_CLASS} mt-1 font-mono text-xs`}
                          value={draft[key] ?? ''}
                          onChange={event => setDraft(current => ({ ...current, [key]: event.target.value }))}
                          placeholder={settingsByKey.get(key)?.present ? '' : 'Not currently written'}
                          disabled={SOLO_READ_ONLY_SETTINGS.has(key)}
                        />
                      </label>
                    ))}
                  </div>
                </CollapsibleCard>
              ))}
              <div className="sticky bottom-0 card p-3 flex items-center justify-between gap-3 bg-surface/95 backdrop-blur">
                <div className="text-xs text-text-muted">
                  {gameRunning
                    ? 'Close Dune: Awakening before applying settings.'
                    : `${Object.keys(changedSettings).length} changed setting(s). Apply creates a retained INI backup and verifies each change.`}
                </div>
                <button
                  className={`btn-primary shrink-0 ${SOLO_DISABLED_PRIMARY_CLASS}`}
                  onClick={() => void saveSettings()}
                  disabled={!canMutateActiveProfile || gameRunning || Object.keys(changedSettings).length === 0}
                >
                  <Icon name={busy === 'settings' ? 'LoaderCircle' : 'Save'} size={14} className={busy === 'settings' ? 'animate-spin' : ''} />
                  Apply Solo settings
                </button>
              </div>
            </>
          )}
        </div>
      )}

      {tab === 'backups' && (
        <div className="card p-5">
          <div className="flex items-start justify-between gap-4 mb-4">
            <div>
              <h2 className="font-semibold flex items-center gap-2"><Icon name="ArchiveRestore" size={16} /> Retained save backups</h2>
              <p className="text-sm text-text-muted mt-1">
                Backups validate the wrapper, SQLite integrity, foreign keys, and one-character invariant. Restore always preserves the current save first.
              </p>
            </div>
            <button className={`btn-primary shrink-0 ${SOLO_DISABLED_PRIMARY_CLASS}`} onClick={() => void createBackup()} disabled={!canMutateActiveProfile}>
              <Icon name={busy === 'backup' ? 'LoaderCircle' : 'Archive'} size={14} className={busy === 'backup' ? 'animate-spin' : ''} />
              Create backup
            </button>
          </div>
          <div className="text-xs text-text-dim font-mono break-all mb-4">{backupsState.data?.root ?? status?.backupRoot}</div>
          {(backupsState.data?.backups.length ?? 0) === 0 ? (
            <p className="text-sm text-text-muted">No Solo backups created by DST yet.</p>
          ) : (
            <div className="divide-y divide-border">
              {backupsState.data!.backups.map(backup => (
                <div key={backup.relativePath} className="py-3 flex items-center justify-between gap-4">
                  <div className="min-w-0">
                    <div className="font-medium text-sm truncate">{backup.name}</div>
                    <div className="text-xs text-text-muted">
                      {formatBytes(backup.bytes)} - {new Date(backup.modifiedAt).toLocaleString()}
                    </div>
                    <div className="text-[11px] text-text-dim font-mono truncate">{backup.relativePath}</div>
                  </div>
                  <div className="flex items-center gap-2 shrink-0">
                    <button
                      className="btn-secondary"
                      disabled={!canMutateActiveProfile || gameRunning}
                      onClick={() => void restoreBackup(backup)}
                    >
                      <Icon name={busy === `restore:${backup.relativePath}` ? 'LoaderCircle' : 'RotateCcw'} size={14} className={busy === `restore:${backup.relativePath}` ? 'animate-spin' : ''} />
                      Restore
                    </button>
                    <button
                      className="btn-danger"
                      disabled={!canMutateActiveProfile}
                      onClick={() => void deleteBackup(backup)}
                    >
                      <Icon name={busy === `delete:${backup.relativePath}` ? 'LoaderCircle' : 'Trash2'} size={14} className={busy === `delete:${backup.relativePath}` ? 'animate-spin' : ''} />
                      Delete
                    </button>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {tab === 'character' && (
        <div className="grid grid-cols-1 xl:grid-cols-2 gap-4">
          <div className="card p-5">
            <div className="flex items-start justify-between gap-4 mb-4">
              <div>
                <h2 className="font-semibold flex items-center gap-2">
                  <Icon name="Coins" size={16} /> Currencies
                </h2>
                <p className="text-sm text-text-muted mt-1">
                  Exact Solari and Landsraad Scrip balances are field-confirmed in PTC.
                </p>
              </div>
              <StatusPill ok={!gameRunning}>
                {gameRunning ? 'Close game to write' : 'Offline writes available'}
              </StatusPill>
            </div>
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <label>
                <span className="text-xs text-text-muted">Solari</span>
                <input
                  type="number"
                  min={0}
                  max={2_000_000_000}
                  className={`${SOLO_INPUT_CLASS} mt-1`}
                  value={solariDraft}
                  onChange={event => setSolariDraft(Number(event.target.value))}
                  disabled={!canMutateActiveProfile || gameRunning}
                />
              </label>
              <label>
                <span className="text-xs text-text-muted">Landsraad Scrip</span>
                <input
                  type="number"
                  min={0}
                  max={2_000_000_000}
                  className={`${SOLO_INPUT_CLASS} mt-1`}
                  value={scripDraft}
                  onChange={event => setScripDraft(Number(event.target.value))}
                  disabled={!canMutateActiveProfile || gameRunning}
                />
              </label>
            </div>
            <button
              className={`btn-primary w-full mt-4 justify-center ${SOLO_DISABLED_PRIMARY_CLASS}`}
              disabled={!canMutateActiveProfile || gameRunning}
              onClick={() => void saveCurrencies()}
            >
              <Icon name={busy === 'currencies' ? 'LoaderCircle' : 'Save'} size={14} className={busy === 'currencies' ? 'animate-spin' : ''} />
              Set currency balances
            </button>
          </div>

          <div className="card p-5">
            <div className="flex items-start justify-between gap-4 mb-4">
              <div>
                <h2 className="font-semibold flex items-center gap-2">
                  <Icon name="Droplets" size={16} /> Character fillables
                </h2>
                <p className="text-sm text-text-muted mt-1">
                  Fill carried water containers to their exact stored or verified capacity.
                </p>
              </div>
              <StatusPill ok={!gameRunning}>
                {gameRunning ? 'Close game to write' : 'Offline writes available'}
              </StatusPill>
            </div>
            {(inspection?.fillables.length ?? 0) === 0 ? (
              <p className="text-sm text-text-muted">
                No supported carried water container was found. Put a Literjon, Dewpack, or Decajon in the character inventory, exit fully, then Refresh.
              </p>
            ) : (
              <div className="space-y-2">
                {inspection!.fillables.map(item => (
                  <div key={item.itemId} className="rounded border border-border bg-surface-2/50 px-3 py-3 flex items-center justify-between gap-4">
                    <div>
                      <div className="font-medium text-sm">{item.label}</div>
                      <div className="text-xs text-text-muted">
                        {item.currentAmount.toLocaleString()} / {item.capacity.toLocaleString()} mL
                      </div>
                    </div>
                    <button
                      className={`btn-primary shrink-0 ${SOLO_DISABLED_PRIMARY_CLASS}`}
                      disabled={!canMutateActiveProfile || gameRunning || item.currentAmount >= item.capacity}
                      onClick={() => void fillWaterContainer(item.itemId, item.label, item.capacity)}
                    >
                      <Icon name={busy === `fill:${item.itemId}` ? 'LoaderCircle' : 'Droplet'} size={14} className={busy === `fill:${item.itemId}` ? 'animate-spin' : ''} />
                      Fill to capacity
                    </button>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      )}
      {tab === 'inventory' && (
        <div className="space-y-4">
          <div className="card p-5">
            <div className="flex items-start justify-between gap-4 mb-4">
              <div>
                <h2 className="font-semibold flex items-center gap-2">
                  <Icon name="PackageOpen" size={16} /> Item delivery
                </h2>
                <p className="text-sm text-text-muted mt-1">
                  Field-confirmed PTC path. The game must be fully closed before every grant.
                </p>
              </div>
              <StatusPill ok={!gameRunning}>
                {gameRunning ? 'Close game to give items' : 'Offline writes available'}
              </StatusPill>
            </div>

            {(inspection?.inventories.length ?? 0) === 0 ? (
              <div className="rounded border border-warning/30 bg-warning/5 p-3 text-sm text-text-muted">
                No supported inventory was found. Enter the Solo world once, let the character load, exit fully, then Refresh.
              </div>
            ) : (
              <label className="block">
                <span className="text-xs text-text-muted">Destination</span>
                <select
                  className={`${SOLO_INPUT_CLASS} mt-1`}
                  style={{ colorScheme: 'dark' }}
                  value={inventoryDestination}
                  onChange={event => setInventoryDestination(event.target.value)}
                  disabled={busy !== null}
                >
                  {inspection!.inventories.map(inventory => (
                    <option key={inventory.key} value={inventory.key}>
                      {inventory.label} - {inventory.itemRows}/{inventory.maxItemCount || 'unlimited'} slots
                      {inventory.maxItemVolume > 0
                        ? ` - ${inventory.usedVolume.toFixed(2)}/${inventory.maxItemVolume.toFixed(2)} volume`
                        : ''}
                    </option>
                  ))}
                </select>
                <p className="text-xs text-text-dim mt-1">
                  DST checks current rows against slot capacity and calculates used volume from item metadata plus DB overrides before every grant.
                </p>
              </label>
            )}
          </div>

          <div className="grid grid-cols-1 xl:grid-cols-2 gap-4">
            <div className="card p-5">
              <h3 className="font-semibold mb-1">Give Item</h3>
              <p className="text-xs text-text-muted mb-4">Search the same DST item catalog used by Self-Hosted Gameplay Admin.</p>
              <ItemPicker
                value={itemTemplate}
                displayValue={itemDisplay}
                onChange={(templateId: string, item?: CatalogItem) => {
                  setItemTemplate(templateId)
                  setItemDisplay(item?.name)
                }}
                label="Item"
                placeholder="Search name or template id"
                disabled={!canMutateActiveProfile || gameRunning}
              />
              <div className="grid grid-cols-2 gap-3 mt-3">
                <label>
                  <span className="text-xs text-text-muted">Quantity</span>
                  <input
                    type="number"
                    min={1}
                    max={100000}
                    className={`${SOLO_INPUT_CLASS} mt-1`}
                    value={itemQuantity}
                    onChange={event => setItemQuantity(Number(event.target.value))}
                    disabled={!canMutateActiveProfile || gameRunning}
                  />
                </label>
                <label>
                  <span className="text-xs text-text-muted">Quality 0-5</span>
                  <input
                    type="number"
                    min={0}
                    max={5}
                    className={`${SOLO_INPUT_CLASS} mt-1`}
                    value={itemQuality}
                    onChange={event => setItemQuality(Number(event.target.value))}
                    disabled={!canMutateActiveProfile || gameRunning}
                  />
                </label>
              </div>
              <button
                className={`btn-primary w-full mt-4 justify-center ${SOLO_DISABLED_PRIMARY_CLASS}`}
                disabled={!canMutateActiveProfile || gameRunning || !itemTemplate.trim()}
                onClick={() => void giveOneItem()}
              >
                <Icon name={busy === 'give-items' ? 'LoaderCircle' : 'PackagePlus'} size={14} className={busy === 'give-items' ? 'animate-spin' : ''} />
                Give item
              </button>
            </div>

            <div className="card p-5">
              <h3 className="font-semibold mb-1">Give Vehicle Kit</h3>
              <p className="text-xs text-text-muted mb-4">
                Delivers the canonical parts, unique modules, fuel cells, and repair torch already field-tested in PTC.
              </p>
              <label>
                <span className="text-xs text-text-muted">Vehicle</span>
                <select
                  className={`${SOLO_INPUT_CLASS} mt-1`}
                  style={{ colorScheme: 'dark' }}
                  value={vehicleKitId}
                  onChange={event => setVehicleKitId(event.target.value)}
                  disabled={!canMutateActiveProfile || gameRunning}
                >
                  <option value="">Choose a vehicle...</option>
                  {(vehicleKits?.vehicles ?? [])
                    .filter(vehicle => vehicle.kit.length > 0)
                    .map(vehicle => (
                      <option key={vehicle.id} value={vehicle.id}>{vehicle.label}</option>
                    ))}
                </select>
              </label>
              <div className="rounded border border-border bg-surface-2/50 p-3 mt-4 text-xs text-text-muted">
                Kit contents come from DST's versioned vehicle catalog. Each non-stackable part needs a free slot; DST checks current contents before writing. If the package is not delivered, check the selected destination's free slots and volume.
              </div>
              <button
                className={`btn-primary w-full mt-4 justify-center ${SOLO_DISABLED_PRIMARY_CLASS}`}
                disabled={!canMutateActiveProfile || gameRunning || !vehicleKitId}
                onClick={() => void giveVehicleKit()}
              >
                <Icon name={busy === 'give-items' ? 'LoaderCircle' : 'Truck'} size={14} className={busy === 'give-items' ? 'animate-spin' : ''} />
                Give vehicle kit
              </button>
            </div>

            <SoloCosmeticGrantCard
              busy={busy === 'give-items'}
              disabled={
                !canMutateActiveProfile
                || gameRunning
                || !inspection?.inventories.some(inventory => inventory.kind === 'backpack')
              }
              onGrant={async (templateId, label) => {
                const grant = buildSoloCosmeticGrant(templateId, inspection?.inventories ?? [])
                await giveSoloItems(
                  grant.items,
                  label,
                  grant.destination,
                  'Solo backpack',
                )
              }}
            />

            <div className="card p-5 xl:col-span-2">
              <h3 className="font-semibold mb-1">Max Augment Attributes</h3>
              <p className="text-xs text-text-muted">
                Matches DST’s Self-Hosted action: sets every non-zero numeric roll on carried augments to
                the confirmed maximum while preserving zero and non-numeric entries. Developer Storage is excluded.
              </p>
              <div className="rounded border border-warning/30 bg-warning/5 p-3 mt-4 text-xs text-text-muted">
                Field-confirmed in PTC. Close the game fully; DST retains the current save before writing. Relog after the action.
              </div>
              <button
                className={`btn-primary w-full mt-4 justify-center ${SOLO_DISABLED_PRIMARY_CLASS}`}
                disabled={!canMutateActiveProfile || gameRunning}
                onClick={() => void maxAugmentAttributes()}
              >
                <Icon name={busy === 'max-augments' ? 'LoaderCircle' : 'Sparkles'} size={14} className={busy === 'max-augments' ? 'animate-spin' : ''} />
                Max carried augment attributes
              </button>
            </div>
          </div>

          <div className="rounded border border-border bg-surface-2/40 px-4 py-3 text-xs text-text-muted">
            Saved multi-item packages are not enabled yet. They will use this same backup-safe transaction path before joining a future Solo preview build.
          </div>
        </div>
      )}
      {tab === 'progression' && (
        <div className="space-y-4">
          <div className="rounded-lg border border-warning/30 bg-warning/5 px-4 py-3 text-sm flex items-start gap-2">
            <Icon name="ShieldAlert" size={15} className="text-warning mt-0.5 shrink-0" />
            <span>
              PTC adapter only. Close the game fully before every action. Each action creates its own retained pre-progression backup.
            </span>
          </div>
          <div className="grid grid-cols-1 xl:grid-cols-3 gap-4">
            <ProgressionActionCard
              icon="Medal"
              title="Max specializations"
              description="Set all five tracks to level 100, grant all 205 rewards, and reconcile the 54 specialization skill points idempotently."
              status={`${inspection?.progression.specializations.filter(track => track.level >= 100).length ?? 0}/5 tracks at 100 · ${inspection?.progression.purchasedRewards ?? 0}/205 rewards`}
              busy={busy === 'progression:specializations'}
              disabled={!canMutateActiveProfile || gameRunning}
              onRun={() => void runProgressionAction(
                'specializations',
                'Max all Solo specializations',
                maxSoloSpecializations,
              )}
            />
            <ProgressionActionCard
              icon="Route"
              title="Complete Find the Fremen"
              description="Complete all 59 verified nodes, add 14 reward tags and five Fremkit recipes, then enable Prescience and the third ability slot."
              status={`${inspection?.progression.fremenNodesComplete ?? 0}/${inspection?.progression.fremenNodesTotal ?? 0} nodes · Prescience ${inspection?.progression.spiceSystemStatus === 'FullyEnabled' ? 'enabled' : 'locked'}`}
              busy={busy === 'progression:fremen'}
              disabled={!canMutateActiveProfile || gameRunning}
              onRun={() => void runProgressionAction(
                'fremen',
                'Complete Find the Fremen',
                completeSoloFindTheFremen,
              )}
            />
            <ProgressionActionCard
              icon="Sparkles"
              title="Enable all skills"
              description="Raise 144 approved skills to value 7, skip Voice Ignore, preserve unknown PTC keys, keep 20 unspent points, and raise Intel to 100."
              status={`${inspection?.progression.skillsAtSeven ?? 0}/144 enabled · ${inspection?.progression.unspentSkillPoints ?? 0} unspent · ${inspection?.progression.intel ?? 0} Intel`}
              busy={busy === 'progression:skills'}
              disabled={!canMutateActiveProfile || gameRunning}
              onRun={() => void runProgressionAction(
                'skills',
                'Enable all approved Solo skills',
                enableSoloAllSkills,
              )}
            />
          </div>
        </div>
      )}
    </>
  )
}

function ProgressionActionCard({
  icon,
  title,
  description,
  status,
  busy,
  disabled,
  onRun,
}: {
  icon: string
  title: string
  description: string
  status: string
  busy: boolean
  disabled: boolean
  onRun: () => void
}) {
  return (
    <div className="card p-5 flex flex-col">
      <div className="w-9 h-9 rounded-lg bg-accent/10 border border-accent/25 flex items-center justify-center text-accent-bright mb-3">
        <Icon name={icon} size={17} />
      </div>
      <h2 className="font-semibold">{title}</h2>
      <p className="text-sm text-text-muted mt-1 flex-1">{description}</p>
      <div className="rounded border border-border bg-surface-2/50 px-3 py-2 text-xs text-text-muted mt-4">
        {status}
      </div>
      <button
        className={`btn-primary w-full justify-center mt-4 ${SOLO_DISABLED_PRIMARY_CLASS}`}
        disabled={disabled}
        onClick={onRun}
      >
        <Icon name={busy ? 'LoaderCircle' : 'Play'} size={14} className={busy ? 'animate-spin' : ''} />
        {busy ? 'Applying...' : title}
      </button>
    </div>
  )
}
