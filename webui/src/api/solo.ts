import { api } from './client'

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
  kind: 'backpack' | 'developer-storage'
  itemRows: number
  maxItemCount: number
  maxItemVolume: number
  usedVolume: number
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

export function enableSoloAllSkills(expectedProfileToken: string): Promise<SoloProgressionResult> {
  return api('/api/solo/progression/skills/enable-all', {
    method: 'POST',
    body: JSON.stringify({
      expectedProfileToken,
      confirm: 'ENABLE SOLO SKILLS',
    }),
  })
}
