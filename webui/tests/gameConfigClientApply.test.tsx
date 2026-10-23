import { act, cleanup, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { GameConfig, buildClientConfigDifferences } from '../src/pages/GameConfig'
import { api } from '../src/api/client'
import {
  applyGameConfigClient,
  getGameConfig,
  getGameConfigClient,
  getGameConfigSchema,
  saveGameConfig,
  saveGameConfigRaw,
  saveLabLocal,
} from '../src/api/gameconfig'
import { SettingsApplyContext, type SettingsDraft } from '../src/pages/gameconfig/settingsApplyContext'
import type {
  GameConfigCategory,
  GameConfigClientInfo,
  GameConfigResponse,
} from '../src/api/types'

const testState = vi.hoisted(() => ({ local: true }))

vi.mock('../src/util/viewer', () => ({
  isLocalViewer: () => testState.local,
}))
vi.mock('../src/hooks/useCommandDeck', () => ({
  useCommandDeck: () => false,
}))
vi.mock('../src/hooks/useStatus', () => ({
  useStatus: () => ({
    status: { vm: { running: true }, serverName: 'Test server' },
    forceRefresh: vi.fn().mockResolvedValue(undefined),
  }),
}))
vi.mock('../src/api/client', () => ({
  api: vi.fn(),
}))
vi.mock('../src/api/gameconfig', () => ({
  getGameConfigSchema: vi.fn(),
  getGameConfigExperimentalCategories: vi.fn(),
  getGameConfigExperimentalCategory: vi.fn(),
  searchGameConfigExperimental: vi.fn(),
  getGameConfig: vi.fn(),
  saveGameConfig: vi.fn(),
  reloadGameConfigPods: vi.fn(),
  backupGameConfig: vi.fn(),
  listGameConfigBackups: vi.fn(),
  deleteGameConfigBackups: vi.fn(),
  getGameConfigClient: vi.fn(),
  setGameConfigClientDir: vi.fn(),
  setGameConfigClientEngineEnabled: vi.fn(),
  applyGameConfigClient: vi.fn(),
  openGameConfigClientFile: vi.fn(),
  getGameConfigDefaults: vi.fn(),
  saveGameConfigRaw: vi.fn(),
  saveLabLocal: vi.fn(),
}))
vi.mock('../src/pages/gameconfig/ServerNameCard', () => ({ ServerNameCard: () => null }))
vi.mock('../src/pages/gameconfig/TwilightLockEvidenceCard', () => ({ TimeOfDayLockPanel: () => null }))
vi.mock('../src/pages/gameconfig/SpicefieldsCard', () => ({ SpicefieldsCard: () => null }))
vi.mock('../src/pages/gameconfig/LandclaimTimerCard', () => ({ LandclaimTimerCard: () => null }))
vi.mock('../src/pages/gameconfig/DeepDesertPvpCard', () => ({ DeepDesertPvpCard: () => null }))
vi.mock('../src/pages/gameconfig/BaseBackupGuardPanel', () => ({ BaseBackupGuardPanel: () => null }))

const schema: GameConfigCategory[] = [{
  category: 'Retail compatibility',
  fields: [
    { file: 'game', section: '/Script/DuneSandbox.InventorySystemSettings', key: 'PlayerInventoryStartingSize', label: 'Starting Inventory Slots', type: 'int', default: '35', clientApply: true },
    { file: 'game', section: '/Script/DuneSandbox.InventorySystemSettings', key: 'PlayerInventoryStartingVolumeCapacity', label: 'Starting Inventory Volume', type: 'float', default: '175.0', clientApply: true },
    { file: 'game', section: '/Script/DuneSandbox.DuneGameMode', key: 'm_InventoryWeightMultiplier', label: 'Inventory Weight Multiplier', type: 'float', default: '1.0', clientApply: true },
    { file: 'game', section: '/Script/DuneSandbox.BuildingSettings', key: 'm_BaseBackupToolMapRestriction', label: 'Allowed Maps', type: 'string', default: 'Hagga', clientApply: true },
    { file: 'engine', section: 'ConsoleVariables', key: 'Vehicle.MaxVehiclesPerPlayer', label: 'Maximum Vehicles Per Player', type: 'int', default: '10', clientApply: true },
    { file: 'engine', section: 'ConsoleVariables', key: 'Dune.DisableShieldOnShooting', label: 'Shield Drops While Shooting', type: 'bool01', default: '1', clientApply: true },
  ],
}]

const fileBundle = (file: 'game' | 'engine', effective: Record<string, string>) => ({
  file,
  path: `C:\\Dune\\${file === 'game' ? 'Game.ini' : 'Engine.ini'}`,
  exists: true,
  raw: '',
  sections: [],
  effective,
  effectiveByKey: {},
  managedSections: [],
})

const config: GameConfigResponse = {
  available: true,
  source: 'installed',
  game: fileBundle('game', {
    '/Script/DuneSandbox.InventorySystemSettings||PlayerInventoryStartingSize': '70',
    '/Script/DuneSandbox.InventorySystemSettings||PlayerInventoryStartingVolumeCapacity': '175.0',
    '/Script/DuneSandbox.DuneGameMode||m_InventoryWeightMultiplier': '0.5',
    '/Script/DuneSandbox.BuildingSettings||m_BaseBackupToolMapRestriction': 'Hagga,DeepDesert',
  }),
  engine: fileBundle('engine', {
    'ConsoleVariables||Vehicle.MaxVehiclesPerPlayer': '100',
    'ConsoleVariables||Dune.DisableShieldOnShooting': '0',
  }),
}

function clientInfo(engineEnabled: boolean): GameConfigClientInfo {
  const game = fileBundle('game', {})
  const engine = fileBundle('engine', {})
  return {
    ...game,
    dir: 'C:\\Dune',
    dirResolved: 'C:\\Dune',
    dirExists: true,
    default: 'C:\\Dune',
    engineEnabled,
    game,
    engine,
  }
}

beforeEach(() => {
  localStorage.clear()
  testState.local = true
  vi.mocked(getGameConfigSchema).mockResolvedValue({ schema })
  vi.mocked(getGameConfig).mockResolvedValue(config)
  vi.mocked(getGameConfigClient).mockResolvedValue(clientInfo(false))
  vi.mocked(applyGameConfigClient).mockResolvedValue({
    ok: true,
    path: 'C:\\Dune\\Game.ini',
    backup: '',
    created: false,
    applied: 1,
    items: [],
    client: clientInfo(false),
  })
})

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

async function openComparison(user: ReturnType<typeof userEvent.setup>) {
  const button = await screen.findByRole('button', { name: 'Compare INIs' })
  await waitFor(() => expect(button).toBeEnabled())
  await user.click(button)
}

describe('Game Config advanced client compatibility action', () => {
  it('ignores numeric formatting but preserves missing, empty, zero and text distinctions', () => {
    const fields = [
      { file: 'game' as const, section: 'Manual', key: 'Volume', label: 'Volume', type: 'float' as const },
      { file: 'game' as const, section: 'Manual', key: 'Missing', label: 'Missing', type: 'int' as const },
      { file: 'game' as const, section: 'Manual', key: 'Empty', label: 'Empty', type: 'int' as const },
      { file: 'game' as const, section: 'Manual', key: 'Name', label: 'Name', type: 'string' as const },
    ]
    const server = { ...config, game: fileBundle('game', { 'Manual||Volume': '300.0', 'Manual||Empty': '', 'Manual||Name': '001' }) }
    const client = { ...clientInfo(false), game: fileBundle('game', { 'Manual||Volume': '300.000000', 'Manual||Missing': '0', 'Manual||Empty': '0', 'Manual||Name': '1' }) }
    expect(buildClientConfigDifferences([{ category: 'Manual', fields }], server, client).filter(item => item.file === 'game').map(item => item.key)).toEqual(['Missing', 'Empty', 'Name'])
  })

  it.each([true, false])('keeps the other 17 differences visible after one winner (snapshot returned: %s)', async snapshotReturned => {
    const user = userEvent.setup()
    const section = '/Script/Test.Settings'
    const fields = Array.from({ length: 18 }, (_, index) => ({ file: 'game' as const, section,
      key: `Difference${index}`, label: `Difference ${index}`, type: 'int' as const }))
    const serverValues = Object.fromEntries(fields.map(field => [`${section}||${field.key}`, '1']))
    const localValues = Object.fromEntries(fields.map(field => [`${section}||${field.key}`, '0']))
    const client = { ...clientInfo(false), game: fileBundle('game', localValues) }
    const refreshed = { ...client, game: fileBundle('game', { ...localValues, [`${section}||Difference0`]: '1' }) }
    vi.mocked(getGameConfigSchema).mockResolvedValue({ schema: [{ category: 'Differences', fields }] })
    vi.mocked(getGameConfig).mockResolvedValue({ ...config, game: fileBundle('game', serverValues), engine: fileBundle('engine', {}) })
    vi.mocked(getGameConfigClient).mockResolvedValue(client)
    render(<GameConfig />)
    await openComparison(user)
    await openComparison(user)
  const comparison = await screen.findByRole('region', { name: 'Server and local INI differences' })
    await user.click(within(comparison).getByRole('button', { name: 'Save to local Difference0' }))
    vi.mocked(getGameConfigClient).mockResolvedValue(refreshed)
    vi.mocked(api).mockResolvedValueOnce({ ok: true, applied: 1, ...(snapshotReturned ? { client: refreshed } : {}) })
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Apply 1 selected setting' }))
    expect(await screen.findByText('Review 17 related setting differences')).toBeInTheDocument()
    const request = vi.mocked(api).mock.calls.find(([path]) => path === '/api/gameconfig/client/lab')!
    expect(JSON.parse(request[1]!.body as string).updates).toEqual([{ file: 'game', section, key: 'Difference0', value: '1' }])
    expect(saveGameConfig).not.toHaveBeenCalled()
    expect(applyGameConfigClient).not.toHaveBeenCalled()
  })

  it('distinguishes a server deletion from a local zero or an empty assignment', () => {
    const server = { ...config, engine: fileBundle('engine', {}) }
    const client = clientInfo(true)
    client.engine = fileBundle('engine', { 'ConsoleVariables||Vehicle.MaxVehiclesPerPlayer': '0', 'ConsoleVariables||Dune.DisableShieldOnShooting': '' })
    const differences = buildClientConfigDifferences(schema, server, client)
    expect(differences).toEqual(expect.arrayContaining([
      expect.objectContaining({ key: 'Vehicle.MaxVehiclesPerPlayer', serverPresent: false, localPresent: true, currentValue: '0', remove: true }),
      expect.objectContaining({ key: 'Dune.DisableShieldOnShooting', serverPresent: false, localPresent: true, currentValue: '', remove: true }),
    ]))
    expect(saveGameConfig).not.toHaveBeenCalled()
    expect(applyGameConfigClient).not.toHaveBeenCalled()
  })

  it('warns for a related existing local entry outside the curated compatibility list', () => {
    const client = clientInfo(false)
    client.engine = fileBundle('engine', { 'ConsoleVariables||SafeZone.EnableScale': '' })
    const differences = buildClientConfigDifferences([{ category: 'Manual comparison', fields: [{
      file: 'engine', section: 'ConsoleVariables', key: 'SafeZone.EnableScale', label: 'Safe-zone scaling', type: 'bool01',
    }] }], { ...config, engine: fileBundle('engine', {}) }, client)
    expect(differences.filter(item => item.file === 'engine')).toEqual([expect.objectContaining({ key: 'SafeZone.EnableScale', serverPresent: false, localPresent: true, currentValue: '' })])
    expect(applyGameConfigClient).not.toHaveBeenCalled()
    expect(saveGameConfig).not.toHaveBeenCalled()
  })

  it('warns about deleted server entries while allowing the user to keep local settings unchanged', async () => {
    const user = userEvent.setup()
    const client = clientInfo(true)
    client.engine = fileBundle('engine', { 'ConsoleVariables||Vehicle.MaxVehiclesPerPlayer': '0' })
    vi.mocked(getGameConfigClient).mockResolvedValue(client)
    vi.mocked(getGameConfig).mockResolvedValue({ ...config, engine: fileBundle('engine', {}) })
    render(<GameConfig />)
    await openComparison(user)
    await openComparison(user)
  const comparison = await screen.findByRole('region', { name: 'Server and local INI differences' })
    expect(within(comparison).getAllByText('Missing (no override)').length).toBeGreaterThan(0)
    expect(within(comparison).getByText('0')).toBeInTheDocument()
    await user.click(within(comparison).getByRole('button', { name: 'Keep settings separate' }))
    expect(screen.queryByRole('region', { name: 'Server and local INI differences' })).not.toBeInTheDocument()
    expect(saveGameConfig).not.toHaveBeenCalled()
    expect(applyGameConfigClient).not.toHaveBeenCalled()
  })

  it('stages the chosen local value for server review without saving or changing the local file', async () => {
    const user = userEvent.setup()
    const client = clientInfo(true)
    client.engine = fileBundle('engine', { 'ConsoleVariables||Vehicle.MaxVehiclesPerPlayer': '0' })
    vi.mocked(getGameConfigClient).mockResolvedValue(client)
    vi.mocked(getGameConfig).mockResolvedValue({ ...config, engine: fileBundle('engine', {}) })
    render(<GameConfig />)
    await openComparison(user)
    await openComparison(user)
  const comparison = await screen.findByRole('region', { name: 'Server and local INI differences' })
    await user.click(within(comparison).getByRole('button', { name: 'Local to server Vehicle.MaxVehiclesPerPlayer' }))
    expect(screen.getByRole('dialog')).toBeInTheDocument()
    expect(within(screen.getByRole('dialog')).getByRole('checkbox', { name: /Save to this PC/ })).not.toBeChecked()
    expect(saveGameConfig).not.toHaveBeenCalled()
    expect(applyGameConfigClient).not.toHaveBeenCalled()
  })

  it('requires explicit review confirmation before removing a local entry to match a server deletion', async () => {
    const user = userEvent.setup()
    const client = clientInfo(true)
    client.engine = fileBundle('engine', { 'ConsoleVariables||Vehicle.MaxVehiclesPerPlayer': '0' })
    vi.mocked(getGameConfigClient).mockResolvedValue(client)
    vi.mocked(getGameConfig).mockResolvedValue({ ...config, engine: fileBundle('engine', {}) })
    render(<GameConfig />)
    await openComparison(user)
    await openComparison(user)
  const comparison = await screen.findByRole('region', { name: 'Server and local INI differences' })
    await user.click(within(comparison).getByRole('button', { name: 'Save to local Vehicle.MaxVehiclesPerPlayer' }))
    const dialog = screen.getByRole('dialog', { name: 'Review selected local INI changes' })
    expect(within(dialog).getByText('Remove local override (server entry is missing or cleared)')).toBeInTheDocument()
    expect(applyGameConfigClient).not.toHaveBeenCalled()
    expect(saveGameConfig).not.toHaveBeenCalled()
    vi.mocked(api).mockResolvedValueOnce({ ok: true, applied: 1, client })
    await user.click(within(dialog).getByRole('button', { name: 'Apply 1 selected setting' }))
    await waitFor(() => expect(api).toHaveBeenCalledWith('/api/gameconfig/client/lab', {
      method: 'PUT', body: JSON.stringify({ approved: true, updates: [{
        file: 'engine', section: 'ConsoleVariables', key: 'Vehicle.MaxVehiclesPerPlayer', value: '',
      }] }),
    }))
    expect(applyGameConfigClient).not.toHaveBeenCalled()
    expect(saveGameConfig).not.toHaveBeenCalled()
  })
  it('clears an existing empty server assignment instead of treating it as an absent key', async () => {
    const user = userEvent.setup()
    const emptyConfig = { ...config, engine: fileBundle('engine', { 'ConsoleVariables||SafeZone.EnableScale': '', 'ConsoleVariables||ManualOther': '0' }) }
    vi.mocked(getGameConfigSchema).mockResolvedValue({ schema: [{ category: 'Mining', fields: [
      { file: 'engine', section: 'ConsoleVariables', key: 'SafeZone.EnableScale', label: 'Enable Safe-Zone Scaling', type: 'bool01' },
    ] }] })
    vi.mocked(getGameConfig).mockResolvedValue(emptyConfig)
    vi.mocked(saveGameConfig).mockResolvedValue({ ok: true, applied: 1, source: 'installed', game: config.game, engine: fileBundle('engine', { 'ConsoleVariables||ManualOther': '0' }) })
    const drafts = new Map<string, SettingsDraft>()
    const controller = { register: (id: string, draft: SettingsDraft | null) => { if (draft) drafts.set(id, draft); else drafts.delete(id) }, review: vi.fn(), locked: false }
    render(<SettingsApplyContext.Provider value={controller}><GameConfig embedded /></SettingsApplyContext.Provider>)
    const categoryToggle = (await screen.findByText('Mining')).closest('button')!
    if (categoryToggle.getAttribute('aria-expanded') === 'false') await user.click(categoryToggle)
    const clear = screen.getByTitle('Remove this entry from the server INI on apply; local player files are not included')
    expect(clear).toBeEnabled()
    expect(drafts.get('advanced')!.changes).toEqual([])
    await user.click(clear)
    expect(drafts.get('advanced')!.changes).toEqual([expect.objectContaining({ label: 'Enable Safe-Zone Scaling', after: 'Remove from server file' })])
    await drafts.get('advanced')!.validate!()
    await act(async () => { await drafts.get('advanced')!.apply() })
    expect(saveGameConfig).toHaveBeenCalledExactlyOnceWith({ 'SafeZone.EnableScale': '' })
    expect(applyGameConfigClient).not.toHaveBeenCalled()
    expect(clear).toBeDisabled()
    expect(drafts.get('advanced')!.changes).toEqual([])
  })

  it('reloads manual server changes and deletions without saving or adding defaults', async () => {
    const user = userEvent.setup()
    vi.mocked(getGameConfigSchema).mockResolvedValue({ schema: [{ category: 'Mining', fields: [
      { file: 'engine', section: 'ConsoleVariables', key: 'MiningManual', label: 'Manual mining', type: 'float', default: '1' },
    ] }] })
    vi.mocked(getGameConfig).mockResolvedValue({ ...config, engine: fileBundle('engine', { 'ConsoleVariables||MiningManual': '2' }) })
    render(<GameConfig embedded />)
    const categoryToggle = (await screen.findByText('Mining')).closest('button')!
    if (categoryToggle.getAttribute('aria-expanded') === 'false') await user.click(categoryToggle)
    expect(await screen.findByDisplayValue('2')).toBeInTheDocument()
    vi.mocked(getGameConfig).mockResolvedValue({ ...config, engine: fileBundle('engine', { 'ConsoleVariables||MiningManual': '7' }) })
    await user.click(screen.getByRole('button', { name: 'Refresh advanced values' }))
    expect(await screen.findByDisplayValue('7')).toBeInTheDocument()
    vi.mocked(getGameConfig).mockResolvedValue({ ...config, engine: fileBundle('engine', {}) })
    await user.click(screen.getByRole('button', { name: 'Refresh advanced values' }))
    await waitFor(() => expect(screen.getByRole('spinbutton')).toHaveValue(null))
    expect(saveGameConfig).not.toHaveBeenCalled()
    expect(applyGameConfigClient).not.toHaveBeenCalled()
  })

  it('leaves absent overrides blank and writes a default only after its own button is clicked', async () => {
    const user = userEvent.setup()
    vi.mocked(getGameConfigSchema).mockResolvedValue({ schema: [{ category: 'Mining', fields: [
      { file: 'engine', section: 'ConsoleVariables', key: 'Dune.GlobalMiningOutputMultiplier', label: 'Global Mining Multiplier', type: 'float', default: '1.0' },
      { file: 'engine', section: 'ConsoleVariables', key: 'UnknownDefault', label: 'No Known Default', type: 'float' },
    ] }] })
    vi.mocked(getGameConfig).mockResolvedValue({ ...config, engine: fileBundle('engine', {}) })
    const drafts = new Map<string, SettingsDraft>()
    const controller = { register: (id: string, draft: SettingsDraft | null) => { if (draft) drafts.set(id, draft); else drafts.delete(id) }, review: vi.fn(), locked: false }
    vi.mocked(saveGameConfig).mockResolvedValue({ ok: true, applied: 1, source: 'installed', game: config.game, engine: fileBundle('engine', { 'ConsoleVariables||Dune.GlobalMiningOutputMultiplier': '1.0' }) })
    render(<SettingsApplyContext.Provider value={controller}><GameConfig embedded /></SettingsApplyContext.Provider>)
    const categoryToggle = (await screen.findByText('Mining')).closest('button')!
    if (categoryToggle.getAttribute('aria-expanded') === 'false') await user.click(categoryToggle)
    const buttons = screen.getAllByRole('button', { name: 'Default' })
    expect(screen.getAllByRole('spinbutton').every(input => (input as HTMLInputElement).value === '')).toBe(true)
    expect(drafts.get('advanced')!.changes).toEqual([])
    expect(buttons[1]).toBeDisabled()
    await user.click(buttons[0])
    expect(drafts.get('advanced')!.changes).toEqual([expect.objectContaining({ label: 'Global Mining Multiplier', after: '1.0' })])
    await act(async () => { await drafts.get('advanced')!.apply() })
    expect(saveGameConfig).toHaveBeenCalledExactlyOnceWith({ 'Dune.GlobalMiningOutputMultiplier': '1.0' })
    expect(applyGameConfigClient).not.toHaveBeenCalled()
  })
  it('reviews a cleared server value as removal and never applies it to local player files', async () => {
    const user = userEvent.setup()
    const drafts = new Map<string, SettingsDraft>()
    const controller = { register: (id: string, draft: SettingsDraft | null) => { if (draft) drafts.set(id, draft); else drafts.delete(id) }, review: vi.fn(), locked: false }
    vi.mocked(saveGameConfig).mockResolvedValue({ ok: true, applied: 1, source: 'installed', game: config.game, engine: config.engine })
    render(<SettingsApplyContext.Provider value={controller}><GameConfig embedded /></SettingsApplyContext.Provider>)
    await user.clear(await screen.findByDisplayValue('70'))
    const draft = drafts.get('advanced')!
    expect(draft.changes).toEqual([expect.objectContaining({ before: '70', after: 'Remove from server file' })])
    await draft.validate!()
    await act(async () => { await draft.apply() })
    expect(saveGameConfig).toHaveBeenCalledExactlyOnceWith({ PlayerInventoryStartingSize: '' })
    expect(applyGameConfigClient).not.toHaveBeenCalled()
  })
  it('registers a server draft for shared review and saves only its changed key without touching player files', async () => {
    const user = userEvent.setup()
    const drafts = new Map<string, SettingsDraft>()
    const controller = { register: (id: string, draft: SettingsDraft | null) => { if (draft) drafts.set(id, draft); else drafts.delete(id) }, review: vi.fn(), locked: false }
    vi.mocked(saveGameConfig).mockResolvedValue({ ok: true, applied: 1, source: 'installed', game: config.game, engine: config.engine })
    render(<SettingsApplyContext.Provider value={controller}><GameConfig embedded /></SettingsApplyContext.Provider>)
    const input = await screen.findByDisplayValue('70')
    await user.clear(input); await user.type(input, '85')
    await user.click(screen.getByRole('button', { name: 'Review & Apply' }))
    expect(controller.review).toHaveBeenCalledOnce()
    expect(saveGameConfig).not.toHaveBeenCalled()
    const draft = drafts.get('advanced')!
    expect(draft.changes).toEqual([expect.objectContaining({ label: 'Starting Inventory Slots', before: '70', after: '85', target: expect.stringContaining('Server + this PC’s local game file · UserGame.ini') })])
    vi.mocked(getGameConfig).mockResolvedValueOnce({ ...config, game: { ...config.game, raw: 'manual edit' } })
    await expect(draft.validate!()).rejects.toThrow('changed outside this form')
    expect(saveGameConfig).not.toHaveBeenCalled()
    await draft.validate!()
    await act(async () => { await draft.apply() })
    expect(saveGameConfig).toHaveBeenCalledExactlyOnceWith({ PlayerInventoryStartingSize: '85' })
    expect(applyGameConfigClient).not.toHaveBeenCalled()
  })
  it('reviews and applies a customized landclaim segment limit without enabling unrelated client fields', async () => {
    const user = userEvent.setup()
    const section = '/Script/DuneSandbox.BuildingSettings'
    vi.mocked(getGameConfigSchema).mockResolvedValue({ schema: [{ category: 'Building', fields: [
      { file: 'game', section, key: 'm_MaxNumLandclaimSegments', label: 'Max Landclaim Segments', type: 'int', default: '6', clientApply: true },
      { file: 'game', section, key: 'm_UnverifiedSetting', label: 'Unverified Setting', type: 'int', default: '1', clientApply: true },
    ] }] })
    vi.mocked(getGameConfig).mockResolvedValue({ ...config, game: fileBundle('game', {
      [`${section}||m_MaxNumLandclaimSegments`]: '23',
      [`${section}||m_UnverifiedSetting`]: '2',
    }), engine: fileBundle('engine', {}) })
    render(<GameConfig />)
    await user.click(await screen.findByRole('button', { name: 'Apply advanced compatibility overrides' }))
    const dialog = screen.getByRole('dialog', { name: 'Review advanced compatibility overrides' })
    expect(within(dialog).getByText('Max Landclaim Segments')).toBeInTheDocument()
    expect(within(dialog).getByText('23')).toBeInTheDocument()
    expect(within(dialog).queryByText('Unverified Setting')).not.toBeInTheDocument()
    expect(applyGameConfigClient).not.toHaveBeenCalled()
    await user.click(within(dialog).getByRole('button', { name: 'Apply 1 selected setting' }))
    await waitFor(() => expect(applyGameConfigClient).toHaveBeenCalledWith([
      expect.objectContaining({ file: 'game', section, key: 'm_MaxNumLandclaimSegments', value: '23' }),
    ], 'C:\\Dune'))
  })

  it('shows the action locally, hides it remotely, and disables it without eligible custom values', async () => {
    const { unmount } = render(<GameConfig />)
    expect(await screen.findByRole('button', { name: 'Apply advanced compatibility overrides' })).toBeEnabled()
    unmount()

    vi.mocked(getGameConfig).mockResolvedValue({
      ...config,
      game: fileBundle('game', {}),
      engine: fileBundle('engine', {}),
    })
    render(<GameConfig />)
    expect(await screen.findByRole('button', { name: 'Apply advanced compatibility overrides' })).toBeDisabled()
    cleanup()

    vi.mocked(getGameConfigClient).mockClear()
    testState.local = false
    render(<GameConfig />)
    await screen.findByText('Game Config')
    expect(screen.queryByRole('button', { name: 'Apply advanced compatibility overrides' })).not.toBeInTheDocument()
    expect(getGameConfigClient).not.toHaveBeenCalled()
  })

  it('reviews exact eligible targets, supports deselection, and submits only the reviewed selection', async () => {
    const user = userEvent.setup()
    const info = clientInfo(true)
    vi.mocked(getGameConfigClient).mockResolvedValue(info)
    vi.mocked(applyGameConfigClient).mockResolvedValue({
      ok: true,
      path: info.game.path,
      backup: '',
      created: false,
      applied: 3,
      items: [],
      client: info,
    })

    render(<GameConfig />)
    await user.click(await screen.findByRole('button', { name: 'Apply advanced compatibility overrides' }))

    const dialog = screen.getByRole('dialog', { name: 'Review advanced compatibility overrides' })
    expect(within(dialog).getByText('Game.ini')).toBeInTheDocument()
    expect(within(dialog).getByText('Engine.ini')).toBeInTheDocument()
    expect(within(dialog).getByText('Starting Inventory Slots')).toBeInTheDocument()
    expect(within(dialog).queryByText('Starting Inventory Volume')).not.toBeInTheDocument()
    expect(within(dialog).queryByText('Inventory Weight Multiplier')).not.toBeInTheDocument()
    expect(within(dialog).getByText('[/Script/DuneSandbox.InventorySystemSettings] PlayerInventoryStartingSize')).toBeInTheDocument()
    expect(within(dialog).getByText('70')).toBeInTheDocument()
    expect(within(dialog).getByText('[ConsoleVariables] Vehicle.MaxVehiclesPerPlayer')).toBeInTheDocument()
    expect(within(dialog).getByText('100')).toBeInTheDocument()

    await user.click(within(dialog).getByRole('checkbox', { name: /Maximum Vehicles Per Player/ }))
    await user.click(within(dialog).getByRole('button', { name: 'Apply 3 selected settings' }))

    await waitFor(() => expect(applyGameConfigClient).toHaveBeenCalledOnce())
    expect(applyGameConfigClient).toHaveBeenCalledWith([
      expect.objectContaining({ file: 'game', key: 'PlayerInventoryStartingSize', value: '70' }),
      expect.objectContaining({ file: 'game', key: 'm_BaseBackupToolMapRestriction', value: 'Hagga,DeepDesert' }),
      expect.objectContaining({ file: 'engine', key: 'Dune.DisableShieldOnShooting', value: '0' }),
    ], 'C:\\Dune')
  })

  it('keeps Engine.ini targets out of review until Engine.ini management is enabled', async () => {
    const user = userEvent.setup()
    render(<GameConfig />)
    await user.click(await screen.findByRole('button', { name: 'Apply advanced compatibility overrides' }))

    const dialog = screen.getByRole('dialog', { name: 'Review advanced compatibility overrides' })
    expect(within(dialog).getByText('Game.ini')).toBeInTheDocument()
    expect(within(dialog).queryByText('Engine.ini')).not.toBeInTheDocument()
    expect(within(dialog).queryByText('Maximum Vehicles Per Player')).not.toBeInTheDocument()
    expect(within(dialog).getByText(/Game.ini compatibility values do not require Engine.ini management/)).toBeInTheDocument()
  })

  it('moves and traps focus safely, closes with Escape, and restores the opener', async () => {
    const user = userEvent.setup()
    render(<GameConfig />)
    const opener = await screen.findByRole('button', { name: 'Apply advanced compatibility overrides' })
    await user.click(opener)

    const dialog = screen.getByRole('dialog', { name: 'Review advanced compatibility overrides' })
    const cancel = within(dialog).getByRole('button', { name: 'Cancel' })
    expect(cancel).toHaveFocus()

    const apply = within(dialog).getByRole('button', { name: /Apply \d+ selected settings/ })
    apply.focus()
    await user.tab()
    expect(within(dialog).getByRole('button', { name: 'Close client settings review' })).toHaveFocus()

    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog', { name: 'Review advanced compatibility overrides' })).not.toBeInTheDocument()
    expect(opener).toHaveFocus()
  })

  it('reviews only eligible WindowsClient values, preselects missing values, and leaves conflicts opt-in', async () => {
    const user = userEvent.setup()
    const info = clientInfo(true)
    info.legacyMigration = {
      available: true,
      reason: '',
      sourceDir: 'C:\\Dune\\WindowsClient',
      destinationDir: 'C:\\Dune\\Windows',
      actionableCount: 2,
      alreadyCurrentCount: 1,
      conflictCount: 1,
      excludedRecognized: [{
        file: 'game',
        section: '/Script/DuneSandbox.SandwormSettings',
        key: 'm_bGiantWormSystemEnabled',
        label: 'Giant Worm System',
        reason: 'No current evidence.',
      }],
      candidates: [
        {
          file: 'game',
          section: '/Script/DuneSandbox.InventorySystemSettings',
          key: 'PlayerInventoryStartingSize',
          label: 'Starting Inventory Slots',
          value: '70',
          currentValue: '',
          state: 'missing',
          selected: true,
        },
        {
          file: 'engine',
          section: 'ConsoleVariables',
          key: 'Vehicle.MaxVehiclesPerPlayer',
          label: 'Maximum Vehicles Per Player',
          value: '20',
          currentValue: '10',
          state: 'conflict',
          selected: false,
        },
        {
          file: 'game',
          section: '/Script/DuneSandbox.BuildingSettings',
          key: 'm_BaseBackupToolMapRestriction',
          label: 'Allowed Maps',
          value: 'Hagga,DeepDesert',
          currentValue: 'Hagga,DeepDesert',
          state: 'current',
          selected: false,
        },
      ],
    }
    vi.mocked(getGameConfigClient).mockResolvedValue(info)

    render(<GameConfig />)
    await user.click(await screen.findByRole('button', { name: 'Review WindowsClient migration' }))

    const dialog = screen.getByRole('dialog', { name: 'Review WindowsClient migration' })
    expect(within(dialog).getByText('Starting Inventory Slots')).toBeInTheDocument()
    expect(within(dialog).getByText('Maximum Vehicles Per Player')).toBeInTheDocument()
    expect(within(dialog).queryByText('Allowed Maps')).not.toBeInTheDocument()
    expect(within(dialog).getByText('old: 70 • current: missing')).toBeInTheDocument()
    expect(within(dialog).getByText('old: 20 • current: 10')).toBeInTheDocument()
    expect(within(dialog).getByRole('checkbox', { name: /Starting Inventory Slots/ })).toBeChecked()
    expect(within(dialog).getByRole('checkbox', { name: /Maximum Vehicles Per Player/ })).not.toBeChecked()

    await user.click(within(dialog).getByRole('button', { name: 'Apply 1 selected setting' }))
    await waitFor(() => expect(applyGameConfigClient).toHaveBeenCalledOnce())
    expect(applyGameConfigClient).toHaveBeenCalledWith([
      expect.objectContaining({ key: 'PlayerInventoryStartingSize', value: '70' }),
    ], 'C:\\Dune')
  })
})


describe('manual scalar comparison coverage', () => {
  it('includes door overrides and missing manual entries without a schema control', () => {
    const section = '/Script/DuneSandbox.BuildingSettings||'
    const cfg = { ...config, game: fileBundle('game', { [section + 'm_TimeToAutomaticallyCloseDoor']: '6', [section + 'm_OpenDoorMinimumVelocity']: '900', [section + 'm_TimeToAutomaticallyCloseDoorRetry']: '1' }) }
    const client = { game: fileBundle('game', { [section + 'm_TimeToAutomaticallyCloseDoor']: '3', [section + 'm_OpenDoorMinimumVelocity']: '1200' }) } as GameConfigClientInfo
    const rows = buildClientConfigDifferences([], cfg, client)
    expect(rows).toHaveLength(3)
    expect(rows.find(row => row.key === 'm_TimeToAutomaticallyCloseDoor')).toMatchObject({ value: '6', currentValue: '3', section: section.slice(0, -2), raw: true })
    expect(rows.find(row => row.key === 'm_TimeToAutomaticallyCloseDoorRetry')).toMatchObject({ localPresent: false, serverPresent: true })
  })
})


it('reviews only the selected manual server entry and keeps local writes disabled', async () => {
  const user = userEvent.setup()
  const section = '/Script/DuneSandbox.BuildingSettings'
  vi.mocked(getGameConfigSchema).mockResolvedValue({ schema: [] })
  vi.mocked(getGameConfig).mockResolvedValue({ ...config, game: fileBundle('game', { [section + '||m_TimeToAutomaticallyCloseDoor']: '6' }), engine: fileBundle('engine', {}) })
  vi.mocked(getGameConfigClient).mockResolvedValue({ ...clientInfo(false), game: fileBundle('game', { [section + '||m_TimeToAutomaticallyCloseDoor']: '3' }), engine: fileBundle('engine', {}) })
  vi.mocked(saveGameConfigRaw).mockResolvedValue({} as never)
  render(<GameConfig />)
  await openComparison(user)
  const comparison = await screen.findByRole('region', { name: 'Server and local INI differences' })
  await user.click(within(comparison).getByRole('button', { name: 'Local to server m_TimeToAutomaticallyCloseDoor' }))
  const dialog = screen.getByRole('dialog')
  const local = within(dialog).getByRole('checkbox', { name: /Save to this PC/ })
  expect(local).not.toBeChecked()
  expect(local).toBeDisabled()
  await user.click(within(dialog).getByRole('button', { name: 'Save server files' }))
  await waitFor(() => expect(saveGameConfigRaw).toHaveBeenCalledWith([{ file: 'game', section, key: 'm_TimeToAutomaticallyCloseDoor', value: '3' }]))
  expect(applyGameConfigClient).not.toHaveBeenCalled()
})


it('remembers an individual Skip after remount, but shows a changed value again', async () => {
  const user = userEvent.setup()
  const section = 'Manual'
  vi.mocked(getGameConfigSchema).mockResolvedValue({ schema: [] })
  const server = { ...config, game: fileBundle('game', { 'Manual||Door': '6', 'Manual||Other': '8' }), engine: fileBundle('engine', {}) }
  vi.mocked(getGameConfig).mockResolvedValue(server)
  vi.mocked(getGameConfigClient).mockResolvedValue({ ...clientInfo(false), game: fileBundle('game', { 'Manual||Door': '3', 'Manual||Other': '4' }), engine: fileBundle('engine', {}) })
  const first = render(<GameConfig />)
  await openComparison(user)
  let comparison = await screen.findByRole('region', { name: 'Server and local INI differences' })
  await user.click(within(comparison).getByRole('button', { name: 'Skip difference Door' }))
  expect(screen.getByText('Review 1 related setting differences')).toBeInTheDocument()
  first.unmount()
  const second = render(<GameConfig />)
  await openComparison(user)
  expect(await screen.findByText('Review 1 related setting differences')).toBeInTheDocument()
  expect(screen.queryByRole('button', { name: 'Skip difference Door' })).not.toBeInTheDocument()
  second.unmount()
  vi.mocked(getGameConfig).mockResolvedValue({ ...server, game: fileBundle('game', { 'Manual||Door': '7', 'Manual||Other': '8' }) })
  render(<GameConfig />)
  await openComparison(user)
  expect(await screen.findByText('Review 2 related setting differences')).toBeInTheDocument()
  expect(saveGameConfigRaw).not.toHaveBeenCalled()
  expect(applyGameConfigClient).not.toHaveBeenCalled()
})


it('excludes local game preferences and engine infrastructure while retaining manual gameplay and cvar differences', () => {
  const localGame = fileBundle('game', { 'Settings.Audio||SoundEffectsVolume': '1', 'Settings.Video||VirtualShadowMaps': '1', 'Settings.Account||IsLocalTotalPlayedTimeActive': 'True', 'Settings.Gameplay||Camera': '1', 'FuncomLiveServices||bPlayFabTelemetryEnabled': 'true', '/Script/DuneSandbox.BuildingSettings||m_TimeToAutomaticallyCloseDoor': '3' })
  const localEngine = fileBundle('engine', { 'Core.System||Paths': '../../../Engine', '/Script/Engine.RendererSettings||r.Shadow': '1', 'ConsoleVariables||Vehicle.Test': '0' })
  const server = { ...config, game: fileBundle('game', { '/Script/DuneSandbox.BuildingSettings||m_TimeToAutomaticallyCloseDoor': '6' }), engine: fileBundle('engine', {}) }
  const rows = buildClientConfigDifferences([], server, { ...clientInfo(true), game: localGame, engine: localEngine })
  expect(rows.map(row => row.key)).toEqual(['m_TimeToAutomaticallyCloseDoor', 'Vehicle.Test'])
})

it('ignores conventional numeric formatting in manual entries without equating blanks or padded strings', () => {
  const server = { ...config, game: fileBundle('game', { 'Manual||Distance': '7.000000', 'Manual||Name': '001', 'Manual||Empty': '' }), engine: fileBundle('engine', {}) }
  const client = { ...clientInfo(false), game: fileBundle('game', { 'Manual||Distance': '7', 'Manual||Name': '1', 'Manual||Empty': '0' }), engine: fileBundle('engine', {}) }
  expect(buildClientConfigDifferences([], server, client).map(row => row.key)).toEqual(['Name', 'Empty'])
})


it('keeps manual differences quiet until Compare INIs is requested', async () => {
  render(<GameConfig />)
  const button = await screen.findByRole('button', { name: 'Compare INIs' })
  await waitFor(() => expect(button).toBeEnabled())
  expect(screen.queryByRole('region', { name: 'Server and local INI differences' })).not.toBeInTheDocument()
  expect(saveGameConfig).not.toHaveBeenCalled()
  expect(saveLabLocal).not.toHaveBeenCalled()
})

it.each([{ skip: false, failure: false }, { skip: true, failure: false }, { skip: false, failure: true }])('handles a required DST edit with the reviewed destinations (%j)', async ({ skip, failure }) => {
  const user = userEvent.setup()
  const key = 'Hydration.SunExposureEnabled', section = 'ConsoleVariables'
  const fields: GameConfigCategory[] = [{ category: 'Hydration', fields: [{ file: 'engine', section, key, label: 'Sun exposure test', type: 'int', clientApply: true }] }]
  const initial = { ...config, game: fileBundle('game', {}), engine: fileBundle('engine', { [section + '||' + key]: '0' }) }
  const client = { ...clientInfo(false), game: fileBundle('game', {}), engine: fileBundle('engine', { [section + '||' + key]: skip ? '7' : '0' }) }
  const final = { ...initial, engine: fileBundle('engine', { [section + '||' + key]: '1' }) }
  vi.mocked(getGameConfigSchema).mockResolvedValue({ schema: fields })
  vi.mocked(getGameConfig).mockResolvedValue(initial)
  vi.mocked(getGameConfigClient).mockResolvedValue(client)
  vi.mocked(saveGameConfig).mockResolvedValue({ ok: true, applied: 1, ...final })
  vi.mocked(saveLabLocal).mockResolvedValue({ ok: true, applied: 1, client: { ...client, engine: final.engine } } as never)
  if (failure) vi.mocked(saveLabLocal).mockRejectedValueOnce(new Error('Local save failed'))
  const drafts = new Map<string, SettingsDraft>()
  const controller = { register: (id: string, draft: SettingsDraft | null) => { if (draft) drafts.set(id, draft) }, review: vi.fn(), locked: false }
  render(<SettingsApplyContext.Provider value={controller}><GameConfig embedded /></SettingsApplyContext.Provider>)
  const input = await screen.findByDisplayValue('0')
  await user.clear(input); await user.type(input, '1')
  if (skip) await user.click(await screen.findByRole('button', { name: 'Skip difference ' + key }))
  if (failure) {
    await act(async () => { await expect(drafts.get('advanced')!.validate!()).rejects.toThrow('Local save failed') })
    expect(saveGameConfig).not.toHaveBeenCalled()
    return
  }
  await act(async () => { await drafts.get('advanced')!.validate!() })
  await act(async () => { await drafts.get('advanced')!.apply() })
  expect(saveGameConfig).toHaveBeenCalledExactlyOnceWith({ [key]: '1' })
  if (skip) expect(saveLabLocal).not.toHaveBeenCalled()
  else expect(vi.mocked(saveLabLocal).mock.calls).toEqual([
    [[{ file: 'engine', section, key, value: '1' }], true],
    [[{ file: 'engine', section, key, value: '1' }]],
  ])
  expect(screen.queryByRole('region', { name: 'Server and local INI differences' })).not.toBeInTheDocument()
})
