import { cleanup, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { GameConfig } from '../src/pages/GameConfig'
import {
  applyGameConfigClient,
  getGameConfig,
  getGameConfigClient,
  getGameConfigSchema,
} from '../src/api/gameconfig'
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

describe('Game Config advanced client compatibility action', () => {
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
