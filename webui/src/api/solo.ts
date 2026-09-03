import { api } from './client'
import type { BlueprintFile } from './gameplay'

export interface SoloProcess {
  name: string
  pid: number
}

export interface SoloProfile {
  id: string
  channel: string
  dbPath: string
  modifiedAt: string
  bytes: number
}

export interface SoloInspection {
  ok: boolean
  sourcePath: string
  wrappedBytes: number
  wrappedSha256: string
  wrapperVersion: number
  declaredSqliteBytes: number
  actualSqliteBytes: number
  integrity: string
  foreignKeyViolations: number
  tableCount: number
  characterCount: number
  schemaFingerprint: string
  mapSeed: number | null
  inventories: SoloInventoryDestination[]
  inventoryItems: SoloInventoryItemGroup[]
  rangedWeapons: SoloRangedWeapon[]
  currencies: {
    solari: number
    scrip: number
  }
  fillables: SoloFillableItem[]
  progression: SoloProgressionSummary
}

export interface SoloProgressionSummary {
  specializations: Array<{
    trackType: number
    level: number
    xp: number
  }>
  purchasedRewards: number
  fremenNodesTotal: number
  fremenNodesComplete: number
  npeNodesTotal: number
  npeNodesComplete: number
  npeTagPresent: boolean
  spiceSystemStatus: string
  spiceVisionStatus: string
  skillsAtSeven: number
  moduleKeyCount: number
  totalSkillPoints: number
  unspentSkillPoints: number
  keystoneBonusSkillPoints: number
  intel: number
}

export interface SoloFillableItem {
  itemId: number
  templateId: string
  label: string
  currentAmount: number
  capacity: number
}

export interface SoloInventoryDestination {
  id: number
  key: string
  label: string
  kind: 'backpack' | 'developer-storage' | 'storage'
  itemRows: number
  maxItemCount: number
  maxItemVolume: number
  usedVolume: number
}

export interface SoloInventoryItemGroup {
  inventoryId: number
  destinationKey: string
  destinationLabel: string
  destinationKind: SoloInventoryDestination['kind']
  templateId: string
  displayName: string
  totalQuantity: number
  occurrenceCount: number
  minQuality: number
  maxQuality: number
}

export interface SoloRangedWeapon {
  itemId: number
  inventoryId: number
  destinationKey: string
  destinationLabel: string
  templateId: string
  displayName: string
  currentAmmo: number
}

export interface SoloStatus {
  ok: boolean
  supported: boolean
  platform: string
  connected: boolean
  dataRoot: string
  dbPath: string
  profileToken: string
  settingsPath: string
  adapter: string
  profiles: SoloProfile[]
  gameRunning: boolean
  processes: SoloProcess[]
  helperAvailable: boolean
  inspection: SoloInspection | null
  inspectionError: string
  backupRoot: string
}

export interface SoloRuntime {
  ok: boolean
  supported: boolean
  platform: string
  gameRunning: boolean
  processes: SoloProcess[]
  helperAvailable: boolean
}

export interface SoloDiscovery {
  ok: boolean
  dataRoot: string
  settingsPath: string
  profiles: SoloProfile[]
  suggestedDbPath: string
}

export interface SoloSetting {
  key: string
  value: string
  present: boolean
}

export interface SoloSettingsResponse {
  ok: boolean
  path: string
  exists: boolean
  section: string
  entries: SoloSetting[]
}

export interface SoloConsoleSetting extends SoloSetting {
  type: 'bool01' | 'int'
  default: string
  min: number | null
  max: number | null
  label: string
  help: string
  status: 'Confirmed' | 'Unconfirmed'
}

export interface SoloConsoleSettingsResponse {
  ok: boolean
  supported: boolean
  adapter: string
  path: string
  exists: boolean
  section: string
  entries: SoloConsoleSetting[]
}

export interface SoloBackup {
  name: string
  relativePath: string
  bytes: number
  createdAt: string
  modifiedAt: string
}

export interface SoloBackupsResponse {
  ok: boolean
  backups: SoloBackup[]
  root: string
}

export function getSoloStatus(): Promise<SoloStatus> {
  return api<SoloStatus>('/api/solo/status')
}

export function getSoloRuntime(): Promise<SoloRuntime> {
  return api<SoloRuntime>('/api/solo/runtime')
}

export function discoverSolo(path: string): Promise<SoloDiscovery> {
  return api<SoloDiscovery>('/api/solo/discover', {
    method: 'POST',
    body: JSON.stringify({ path }),
  })
}

export function connectSolo(path: string, dbPath = ''): Promise<SoloStatus> {
  return api<SoloStatus>('/api/solo/connect', {
    method: 'POST',
    body: JSON.stringify({ path, dbPath }),
  })
}

export function getSoloSettings(): Promise<SoloSettingsResponse> {
  return api<SoloSettingsResponse>('/api/solo/settings')
}

export function saveSoloSettings(settings: Record<string, string>, expectedProfileToken: string): Promise<{
  ok: boolean
  settings: SoloSettingsResponse
  backupPath: string
}> {
  return api('/api/solo/settings', {
    method: 'PUT',
    body: JSON.stringify({ settings, expectedProfileToken, confirm: 'APPLY SOLO SETTINGS' }),
  })
}

export function saveSoloConsoleSettings(
  settings: Record<string, string>,
  expectedProfileToken: string,
): Promise<{
  ok: boolean
  settings: SoloConsoleSettingsResponse
  backupPath: string
  backupPaths: string[]
  paths: string[]
}> {
  return api('/api/solo/console-settings', {
    method: 'PUT',
    body: JSON.stringify({
      settings,
      expectedProfileToken,
      confirm: 'APPLY SOLO CONSOLE SETTINGS',
    }),
  })
}

export function getSoloBackups(): Promise<SoloBackupsResponse> {
  return api<SoloBackupsResponse>('/api/solo/backups')
}

export function createSoloBackup(expectedProfileToken: string): Promise<{ ok: boolean; path: string; inspection: SoloInspection }> {
  return api('/api/solo/backups', {
    method: 'POST',
    body: JSON.stringify({ expectedProfileToken }),
  })
}

export function deleteSoloBackup(
  relativePath: string,
  expectedProfileToken: string,
): Promise<{ ok: boolean; deleted: string }> {
  return api('/api/solo/backups', {
    method: 'DELETE',
    body: JSON.stringify({
      relativePath,
      expectedProfileToken,
      confirm: 'DELETE SOLO BACKUP',
    }),
  })
}

export function deleteSoloBackups(
  relativePaths: string[],
  expectedProfileToken: string,
): Promise<{ ok: boolean; deleted: string[]; deletedCount: number }> {
  return api('/api/solo/backups', {
    method: 'DELETE',
    body: JSON.stringify({
      relativePaths,
      expectedProfileToken,
      confirm: 'DELETE SOLO BACKUPS',
    }),
  })
}

export function restoreSoloBackup(relativePath: string, expectedProfileToken: string): Promise<{
  ok: boolean
  path: string
  safetyBackup: string
  inspection: SoloInspection
}> {
  return api('/api/solo/restore', {
    method: 'POST',
    body: JSON.stringify({ relativePath, expectedProfileToken, confirm: 'RESTORE SOLO SAVE' }),
  })
}

export interface SoloGiveItem {
  templateId: string
  quantity: number
  quality: number
}

export function grantSoloItems(
  destination: string,
  items: SoloGiveItem[],
  expectedProfileToken: string,
): Promise<{
  ok: boolean
  destination: string
  granted: Array<SoloGiveItem & { insertedRows: number; updatedRows: number }>
  safetyBackup: string
  inspection: SoloInspection
}> {
  return api('/api/solo/items/grant', {
    method: 'POST',
    body: JSON.stringify({
      destination,
      items,
      expectedProfileToken,
      confirm: 'GIVE SOLO ITEMS',
    }),
  })
}

export function importSoloBlueprint(
  blueprint: BlueprintFile,
  expectedProfileToken: string,
): Promise<{
  ok: boolean
  blueprintId: number
  itemId: number
  name: string
  instances: number
  placeables: number
  pentashields: number
  safetyBackup: string
  inspection: SoloInspection
}> {
  return api('/api/solo/blueprints/import', {
    method: 'POST',
    body: JSON.stringify({
      blueprint,
      expectedProfileToken,
      confirm: 'IMPORT SOLO BLUEPRINT',
    }),
  })
}

export function setSoloCurrencies(
  solari: number,
  scrip: number,
  expectedProfileToken: string,
): Promise<{
  ok: boolean
  solari: number
  scrip: number
  safetyBackup: string
  inspection: SoloInspection
}> {
  return api('/api/solo/currencies', {
    method: 'PUT',
    body: JSON.stringify({
      solari,
      scrip,
      expectedProfileToken,
      confirm: 'SET SOLO CURRENCIES',
    }),
  })
}

export function fillSoloWaterContainer(
  itemId: number,
  expectedProfileToken: string,
): Promise<{
  ok: boolean
  itemId: number
  templateId: string
  amount: number
  safetyBackup: string
  inspection: SoloInspection
}> {
  return api('/api/solo/fillables/water', {
    method: 'POST',
    body: JSON.stringify({
      itemId,
      expectedProfileToken,
      confirm: 'FILL SOLO WATER',
    }),
  })
}

export function setSoloWeaponAmmo(
  itemId: number,
  ammo: number,
  mode: 'finite' | 'infinite',
  expectedProfileToken: string,
): Promise<{
  ok: boolean
  itemId: number
  templateId: string
  currentAmmo: number
  mode: 'finite' | 'infinite'
  safetyBackup: string
  inspection: SoloInspection
}> {
  return api('/api/solo/items/weapon-ammo', {
    method: 'PUT',
    body: JSON.stringify({
      itemId,
      ammo,
      mode,
      expectedProfileToken,
      confirm: 'SET SOLO WEAPON AMMO',
    }),
  })
}

export function setSoloBackpackSlots(
  slots: number,
  expectedProfileToken: string,
): Promise<{
  ok: boolean
  inventoryId: number
  slots: number
  safetyBackup: string
  inspection: SoloInspection
}> {
  return api('/api/solo/inventory/backpack-slots', {
    method: 'PUT',
    body: JSON.stringify({
      slots,
      expectedProfileToken,
      confirm: 'SET SOLO BACKPACK SLOTS',
    }),
  })
}

export function maxSoloAugmentAttributes(expectedProfileToken: string): Promise<{
  ok: boolean
  updated: number
  safetyBackup: string
  inspection: SoloInspection
}> {
  return api('/api/solo/items/augments/max', {
    method: 'POST',
    body: JSON.stringify({
      expectedProfileToken,
      confirm: 'MAX SOLO AUGMENT ATTRIBUTES',
    }),
  })
}

interface SoloProgressionResult {
  ok: boolean
  action: string
  safetyBackup: string
  details: Record<string, unknown>
  inspection: SoloInspection
}

export function maxSoloSpecializations(expectedProfileToken: string): Promise<SoloProgressionResult> {
  return api('/api/solo/progression/specializations/max', {
    method: 'POST',
    body: JSON.stringify({
      expectedProfileToken,
      confirm: 'MAX SOLO SPECIALIZATIONS',
    }),
  })
}

export function completeSoloFindTheFremen(expectedProfileToken: string): Promise<SoloProgressionResult> {
  return api('/api/solo/progression/find-the-fremen', {
    method: 'POST',
    body: JSON.stringify({
      expectedProfileToken,
      confirm: 'COMPLETE FIND THE FREMEN',
    }),
  })
}

export function completeSoloNpe(expectedProfileToken: string): Promise<SoloProgressionResult> {
  return api('/api/solo/progression/npe/complete', {
    method: 'POST',
    body: JSON.stringify({
      expectedProfileToken,
      confirm: 'COMPLETE SOLO NPE',
    }),
  })
}

export function enableSoloAllSkills(expectedProfileToken: string): Promise<SoloProgressionResult> {
  return api('/api/solo/progression/skills/enable-all', {
    method: 'POST',
    body: JSON.stringify({
      expectedProfileToken,
      confirm: 'ENABLE SOLO SKILLS',
    }),
  })
}

export function setSoloProgressionPoints(
  skillPoints: number,
  intel: number,
  expectedProfileToken: string,
): Promise<SoloProgressionResult> {
  return api('/api/solo/progression/points', {
    method: 'PUT',
    body: JSON.stringify({
      skillPoints,
      intel,
      expectedProfileToken,
      confirm: 'SET SOLO PROGRESSION POINTS',
    }),
  })
}
