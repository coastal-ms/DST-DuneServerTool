import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import {
  OfficialRetailServerSettingsCard,
  RETAIL_SETTING_GUIDANCE,
} from '../src/pages/gameconfig/OfficialRetailServerSettingsCard'

beforeEach(() => {
  window.localStorage.clear()
})

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('Official Retail Server Settings card', () => {
  it('shows field-proven labels, raw paths, and inverted semantics read-only', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
      available: true,
      readOnly: true,
      source: 'funcom-runtime-projection',
      authority: 'Funcom-managed live server output',
      modifiedAt: '2026-09-18T04:52:04.000Z',
      target: {
        available: true,
        path: '/srv/Config/LinuxServer/ServerCustomSettings.ini',
        gamePath: '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer/ServerCustomSettings.ini',
        stopped: false,
        serverPodCount: 2,
      },
      settings: [
        {
          key: 'bIsBuildingRestrictionsEnabled',
          value: 'True',
          displayValue: 'Enabled',
          label: 'General Building Restrictions',
          group: 'World threats and building',
          type: 'bool',
          options: [],
          inverted: false,
          supported: true,
          valid: true,
          validationError: '',
          editable: true,
          readOnly: true,
        },
        {
          key: 'bBuildingInfiniteStability',
          value: 'False',
          displayValue: 'Enabled',
          label: 'Building Stability Limits',
          group: 'World threats and building',
          type: 'bool',
          options: [],
          inverted: true,
          supported: true,
          valid: true,
          validationError: '',
          editable: true,
          readOnly: true,
        },
      ],
      malformedLines: [],
      writeBehavior: { supported: false, reason: 'Funcom regenerates this runtime file.' },
      applyBehavior: {
        mode: 'live-reconciled',
        restartRequired: false,
        note: 'DST does not write or restart for this surface.',
      },
    }), { status: 200, headers: { 'Content-Type': 'application/json' } })))

    render(<OfficialRetailServerSettingsCard vmRunning />)

    expect(await screen.findByText('General Building Restrictions')).toBeInTheDocument()
    expect(screen.getByText(
      'Enabled enforces general building restrictions; disabled is less restrictive but does not remove permanent no-build zones.',
    )).toBeInTheDocument()
    expect(screen.getByText('True')).toBeInTheDocument()
    expect(screen.getByText('Building Stability Limits')).toBeInTheDocument()
    expect(screen.getAllByText('Enabled')).toHaveLength(2)
    expect(screen.getByText((_, element) =>
      element?.textContent === 'Inverted game key: raw False means enabled.',
    )).toBeInTheDocument()
    expect(screen.getByText('/srv/Config/LinuxServer/ServerCustomSettings.ini')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled()
  })

  it('shows future unknown keys instead of dropping them', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
      available: true,
      readOnly: true,
      source: 'funcom-runtime-projection',
      authority: 'Funcom-managed live server output',
      target: { available: true, stopped: false, serverPodCount: 2 },
      settings: [{
        key: 'FutureRetailKey',
        value: 'surprise',
        displayValue: 'surprise',
        label: 'FutureRetailKey',
        group: 'Other values',
        type: 'string',
        options: [],
        inverted: false,
        supported: false,
        valid: true,
        validationError: '',
        editable: false,
        readOnly: true,
      }],
      malformedLines: [],
    }), { status: 200, headers: { 'Content-Type': 'application/json' } })))

    render(<OfficialRetailServerSettingsCard vmRunning />)

    expect(await screen.findAllByText('FutureRetailKey')).toHaveLength(2)
    expect(screen.getByText('Unknown current-Retail key retained read-only.')).toBeInTheDocument()
  })

  it('does not request the endpoint while the VM is stopped', async () => {
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)

    render(<OfficialRetailServerSettingsCard vmRunning={false} />)

    expect(screen.getByText(/Start the battlegroup/i)).toBeInTheDocument()
    await waitFor(() => expect(fetchMock).not.toHaveBeenCalled())
  })

  it('saves only changed values when the battlegroup is fully stopped', async () => {
    const fetchMock = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      if (init?.method === 'PUT') {
        return new Response(JSON.stringify({
          ok: true,
          applied: 1,
          revision: 'next',
          backup: { path: '/srv/settings.dstbak-1', sha256: 'backup', timestamp: '1' },
          restartRequired: true,
          message: 'saved',
          settings: [{
            key: 'FiefdomLimit',
            value: '4',
            displayValue: '4',
            label: 'Maximum Sub-Fief Amount',
            group: 'World threats and building',
            type: 'int',
            options: [],
            inverted: false,
            supported: true,
            valid: true,
            validationError: '',
            editable: true,
            readOnly: false,
          }],
        }), { status: 200, headers: { 'Content-Type': 'application/json' } })
      }
      return new Response(JSON.stringify({
        available: true,
        readOnly: false,
        source: 'funcom-runtime-projection',
        authority: 'Funcom-managed live server output',
        revision: 'current',
        target: { available: true, stopped: true, serverPodCount: 0 },
        settings: [{
          key: 'FiefdomLimit',
          value: '3',
          displayValue: '3',
          label: 'Maximum Sub-Fief Amount',
          group: 'World threats and building',
          type: 'int',
          options: [],
          inverted: false,
          supported: true,
          valid: true,
          validationError: '',
          editable: true,
          readOnly: false,
        }],
        malformedLines: [],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } })
    })
    vi.stubGlobal('fetch', fetchMock)

    render(<OfficialRetailServerSettingsCard vmRunning />)
    const input = await screen.findByRole('spinbutton', { name: 'Maximum Sub-Fief Amount exact value' })
    fireEvent.change(input, { target: { value: '4' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save (1)' }))

    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2))
    const [, putInit] = fetchMock.mock.calls[1]
    expect(putInit?.method).toBe('PUT')
    expect(JSON.parse(putInit?.body as string)).toEqual({
      revision: 'current',
      updates: { FiefdomLimit: '4' },
    })
    expect(await screen.findByText(/saved with backup/)).toBeInTheDocument()
  })

  it('rejects a fractional integer draft before PUT while preserving partial editing', async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({
      available: true,
      readOnly: false,
      source: 'funcom-servergroup-user-ini-config',
      authority: 'Funcom BattleGroup operator configuration',
      revision: 'current',
      target: { available: true, stopped: true, serverPodCount: 0 },
      settings: [{
        key: 'FiefdomLimit',
        value: '3',
        displayValue: '3',
        label: 'Maximum Sub-Fief Amount',
        group: 'World threats and building',
        type: 'int',
        options: [],
        inverted: false,
        supported: true,
        valid: true,
        validationError: '',
        editable: true,
        readOnly: false,
      }],
      malformedLines: [],
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
    vi.stubGlobal('fetch', fetchMock)
    render(<OfficialRetailServerSettingsCard vmRunning />)

    const input = await screen.findByRole('spinbutton', { name: 'Maximum Sub-Fief Amount exact value' })
    fireEvent.change(input, { target: { value: '3.5' } })

    expect(input).toHaveAttribute('value', '3.5')
    expect(screen.getByRole('alert')).toHaveTextContent('must be a finite whole integer')
    expect(screen.getByRole('button', { name: 'Save (1)' })).toBeDisabled()
    fireEvent.click(screen.getByRole('button', { name: 'Save (1)' }))
    expect(fetchMock).toHaveBeenCalledOnce()
  })

  it('keeps the newest status-triggered Retail response when requests resolve out of order', async () => {
    let resolveOlder!: (response: Response) => void
    let resolveNewer!: (response: Response) => void
    const older = new Promise<Response>(resolve => { resolveOlder = resolve })
    const newer = new Promise<Response>(resolve => { resolveNewer = resolve })
    const fetchMock = vi.fn()
      .mockReturnValueOnce(older)
      .mockReturnValueOnce(newer)
    vi.stubGlobal('fetch', fetchMock)
    const view = render(<OfficialRetailServerSettingsCard vmRunning statusRefreshKey="stopping:1" />)
    view.rerender(<OfficialRetailServerSettingsCard vmRunning statusRefreshKey="stopped:0" />)

    resolveNewer(new Response(JSON.stringify({
      available: true,
      readOnly: false,
      source: 'funcom-servergroup-user-ini-config',
      authority: 'Funcom BattleGroup operator configuration',
      revision: 'newer',
      target: { available: true, stopped: true, serverPodCount: 0 },
      settings: [{
        key: 'FiefdomLimit',
        value: '8',
        displayValue: '8',
        label: 'Maximum Sub-Fief Amount',
        group: 'World threats and building',
        type: 'int',
        options: [],
        inverted: false,
        supported: true,
        valid: true,
        validationError: '',
        editable: true,
        readOnly: false,
      }],
      malformedLines: [],
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
    expect(await screen.findByRole('spinbutton', { name: 'Maximum Sub-Fief Amount exact value' })).toHaveValue(8)

    resolveOlder(new Response(JSON.stringify({
      available: true,
      readOnly: true,
      source: 'funcom-runtime-projection',
      authority: 'older running response',
      revision: 'older',
      target: { available: true, stopped: false, serverPodCount: 1 },
      settings: [{
        key: 'FiefdomLimit',
        value: '3',
        displayValue: '3',
        label: 'Maximum Sub-Fief Amount',
        group: 'World threats and building',
        type: 'int',
        options: [],
        inverted: false,
        supported: true,
        valid: true,
        validationError: '',
        editable: true,
        readOnly: true,
      }],
      malformedLines: [],
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2))
    expect(screen.getByRole('spinbutton', { name: 'Maximum Sub-Fief Amount exact value' })).toHaveValue(8)
    expect(screen.queryByText('older running response')).not.toBeInTheDocument()
  })

  it('reports a non-abort Retail load failure', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => {
      throw new Error('Retail settings unavailable')
    }))

    render(<OfficialRetailServerSettingsCard vmRunning />)

    expect(await screen.findByRole('alert')).toHaveTextContent('Retail settings unavailable')
  })

  it('uses direct raw semantics and the documented default for Unlimited Landsraad Decree Rerolls', async () => {
    const fetchMock = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      if (init?.method === 'PUT') {
        return new Response(JSON.stringify({
          ok: true,
          applied: 1,
          revision: 'next',
          backup: { path: '/srv/settings.dstbak-1', sha256: 'backup', timestamp: '1' },
          restartRequired: true,
          message: 'saved',
          settings: [],
        }), { status: 200, headers: { 'Content-Type': 'application/json' } })
      }
      return new Response(JSON.stringify({
        available: true,
        readOnly: false,
        source: 'funcom-servergroup-user-ini-config',
        authority: 'Funcom BattleGroup operator configuration',
        revision: 'current',
        target: { available: true, stopped: true, serverPodCount: 0 },
        settings: [{
          key: 'bLandsraadDisableDecreeRerollLimit',
          value: 'False',
          displayValue: 'Disabled',
          label: 'Unlimited Landsraad Decree Rerolls',
          group: 'Landsraad',
          type: 'bool',
          options: [],
          inverted: false,
          supported: true,
          valid: true,
          validationError: '',
          editable: true,
          readOnly: false,
        }],
        malformedLines: [],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } })
    })
    vi.stubGlobal('fetch', fetchMock)
    render(<OfficialRetailServerSettingsCard vmRunning />)

    const toggle = await screen.findByRole('combobox', { name: 'Unlimited Landsraad Decree Rerolls' })
    expect(toggle).toHaveValue('False')
    expect(RETAIL_SETTING_GUIDANCE.bLandsraadDisableDecreeRerollLimit.defaultValue).toBe('False')
    fireEvent.change(toggle, { target: { value: 'True' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save (1)' }))

    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2))
    expect(JSON.parse(fetchMock.mock.calls[1][1]?.body as string)).toEqual({
      revision: 'current',
      updates: { bLandsraadDisableDecreeRerollLimit: 'True' },
    })
  })

  it('renders synchronized int and float convenience sliders with exact type steps', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
      available: true,
      readOnly: false,
      source: 'funcom-servergroup-user-ini-config',
      authority: 'Funcom BattleGroup operator configuration',
      revision: 'current',
      target: { available: true, stopped: true, serverPodCount: 0 },
      settings: [
        {
          key: 'FiefdomLimit',
          value: '3',
          displayValue: '3',
          label: 'Maximum Sub-Fief Amount',
          group: 'World threats and building',
          type: 'int',
          options: [],
          inverted: false,
          supported: true,
          valid: true,
          validationError: '',
          editable: true,
          readOnly: false,
        },
        {
          key: 'BuildingPieceLimitMultiplier',
          value: '1.5',
          displayValue: '1.5',
          label: 'Building Piece Limit',
          group: 'World threats and building',
          type: 'float',
          options: [],
          inverted: false,
          supported: true,
          valid: true,
          validationError: '',
          editable: true,
          readOnly: false,
        },
      ],
      malformedLines: [],
    }), { status: 200, headers: { 'Content-Type': 'application/json' } })))

    render(<OfficialRetailServerSettingsCard vmRunning />)

    const intSlider = await screen.findByRole('slider', {
      name: 'Maximum Sub-Fief Amount slider, range 0 to 25',
    })
    const floatSlider = screen.getByRole('slider', {
      name: 'Building Piece Limit slider, range 0.1 to 25',
    })
    const intInput = screen.getByRole('spinbutton', { name: 'Maximum Sub-Fief Amount exact value' })
    const floatInput = screen.getByRole('spinbutton', { name: 'Building Piece Limit exact value' })

    expect(intSlider).toHaveAttribute('min', '0')
    expect(intSlider).toHaveAttribute('max', '25')
    expect(intSlider).toHaveAttribute('step', '1')
    expect(floatSlider).toHaveAttribute('min', '0.1')
    expect(floatSlider).toHaveAttribute('max', '25')
    expect(floatSlider).toHaveAttribute('step', '0.1')
    expect(intInput).not.toHaveAttribute('min')
    expect(intInput).not.toHaveAttribute('max')
    expect(intInput).toHaveAttribute('step', '1')
    expect(floatInput).toHaveAttribute('step', 'any')

    fireEvent.change(intSlider, { target: { value: '7' } })
    expect(intInput).toHaveValue(7)
    expect(screen.getByRole('button', { name: 'Save (1)' })).toBeEnabled()

    fireEvent.change(floatSlider, { target: { value: '1.1' } })
    expect(floatInput).toHaveAttribute('value', '1.100000')
    expect(floatSlider).toHaveValue('1.1')
    fireEvent.change(floatInput, { target: { value: '2.75' } })
    expect(floatSlider).toHaveValue('2.75')
    expect(screen.getByRole('button', { name: 'Save (2)' })).toBeEnabled()
  })

  it('preserves an exact value above 25 until the operator moves the saturated slider', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
      available: true,
      readOnly: false,
      source: 'funcom-servergroup-user-ini-config',
      authority: 'Funcom BattleGroup operator configuration',
      revision: 'current',
      target: { available: true, stopped: true, serverPodCount: 0 },
      settings: [{
        key: 'FiefdomLimit',
        value: '40',
        displayValue: '40',
        label: 'Maximum Sub-Fief Amount',
        group: 'World threats and building',
        type: 'int',
        options: [],
        inverted: false,
        supported: true,
        valid: true,
        validationError: '',
        editable: true,
        readOnly: false,
      }],
      malformedLines: [],
    }), { status: 200, headers: { 'Content-Type': 'application/json' } })))

    render(<OfficialRetailServerSettingsCard vmRunning />)

    const slider = await screen.findByRole('slider', {
      name: 'Maximum Sub-Fief Amount slider, range 0 to 25',
    })
    const input = screen.getByRole('spinbutton', { name: 'Maximum Sub-Fief Amount exact value' })
    expect(slider).toHaveValue('25')
    expect(slider).toHaveAttribute('aria-valuetext', '25, slider maximum; exact value 40 is preserved')
    expect(input).toHaveValue(40)
    expect(screen.getByText('25 / 25 max')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled()

    fireEvent.change(slider, { target: { value: '24' } })
    expect(input).toHaveValue(24)
    expect(screen.getByRole('button', { name: 'Save (1)' })).toBeEnabled()
  })

  it('normalizes long floats to Funcom precision without narrow-layout bleed or draft loss', async () => {
    const fetchMock = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      if (init?.method === 'PUT') {
        return new Response(JSON.stringify({
          ok: true,
          applied: 1,
          revision: 'next',
          backup: { path: '/srv/settings.dstbak-1', sha256: 'backup', timestamp: '1' },
          restartRequired: true,
          message: 'saved',
          settings: [],
        }), { status: 200, headers: { 'Content-Type': 'application/json' } })
      }
      return new Response(JSON.stringify({
        available: true,
        readOnly: false,
        source: 'funcom-servergroup-user-ini-config',
        authority: 'Funcom BattleGroup operator configuration',
        revision: 'current',
        target: { available: true, stopped: true, serverPodCount: 0 },
        settings: [{
          key: 'BuildingDecayRateModifier',
          value: '0.576036866359447',
          displayValue: '0.576036866359447',
          label: 'Building Decay Rate',
          group: 'World threats and building',
          type: 'float',
          options: [],
          inverted: false,
          supported: true,
          valid: true,
          validationError: '',
          editable: true,
          readOnly: false,
        }],
        malformedLines: [],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } })
    })
    vi.stubGlobal('fetch', fetchMock)

    render(<OfficialRetailServerSettingsCard vmRunning />)

    const input = await screen.findByRole('spinbutton', { name: 'Building Decay Rate exact value' })
    const slider = screen.getByRole('slider', { name: 'Building Decay Rate slider, range 0.1 to 25' })
    const measurement = screen.getByText('0.576037 / 25')
    expect(input).toHaveValue(0.576037)
    expect(input).toHaveAttribute('title', expect.stringContaining('Exact value 0.576037'))
    expect(slider).toHaveAttribute('aria-valuetext', '0.576037')
    expect(measurement).toHaveClass('whitespace-nowrap', 'tabular-nums')
    expect(measurement.parentElement).toHaveClass('min-w-0')
    expect(screen.getByText('float')).toHaveClass('shrink-0', 'self-center')
    expect(input.closest('.grid')).toHaveClass('min-w-0')
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled()

    fireEvent.change(input, { target: { value: '1.2345678' } })
    expect(input).toHaveAttribute('value', '1.2345678')
    fireEvent.change(input, { target: { value: '30.1234567' } })
    expect(input).toHaveAttribute('value', '30.1234567')
    fireEvent.blur(input)
    expect(input).toHaveValue(30.123457)
    expect(slider).toHaveValue('25')
    expect(screen.getByText('25 / 25 max')).toHaveClass('whitespace-nowrap')

    fireEvent.change(slider, { target: { value: '0.1' } })
    expect(input).toHaveAttribute('value', '0.100000')
    fireEvent.change(slider, { target: { value: '2.5' } })
    expect(input).toHaveAttribute('value', '2.500000')
    fireEvent.change(input, { target: { value: '3.12345678' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save (1)' }))

    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2))
    const [, putInit] = fetchMock.mock.calls[1]
    expect(JSON.parse(putInit?.body as string)).toEqual({
      revision: 'current',
      updates: { BuildingDecayRateModifier: '3.123457' },
    })
  })

  it('disables both numeric controls unless the battlegroup has zero running pods', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
      available: true,
      readOnly: false,
      source: 'funcom-servergroup-user-ini-config',
      authority: 'Funcom BattleGroup operator configuration',
      revision: 'current',
      target: { available: true, stopped: true, serverPodCount: 1 },
      settings: [{
        key: 'FiefdomLimit',
        value: '3',
        displayValue: '3',
        label: 'Maximum Sub-Fief Amount',
        group: 'World threats and building',
        type: 'int',
        options: [],
        inverted: false,
        supported: true,
        valid: true,
        validationError: '',
        editable: true,
        readOnly: false,
      }],
      malformedLines: [],
    }), { status: 200, headers: { 'Content-Type': 'application/json' } })))

    render(<OfficialRetailServerSettingsCard vmRunning />)

    expect(await screen.findByRole('slider', {
      name: 'Maximum Sub-Fief Amount slider, range 0 to 25',
    })).toBeDisabled()
    expect(screen.getByRole('spinbutton', { name: 'Maximum Sub-Fief Amount exact value' })).toBeDisabled()
  })

  it('loads present editable defaults as a draft and refresh discards them without an immediate save', async () => {
    const settings = [
      {
        key: 'GatheringAmount',
        value: '2.000000',
        displayValue: '2.000000',
        label: 'Gathering Amount',
        group: 'World and economy',
        type: 'float',
        options: [],
        inverted: false,
        supported: true,
        valid: true,
        validationError: '',
        editable: true,
        readOnly: false,
      },
      {
        key: 'FiefdomLimit',
        value: '5',
        displayValue: '5',
        label: 'Maximum Sub-Fief Amount',
        group: 'World threats and building',
        type: 'int',
        options: [],
        inverted: false,
        supported: true,
        valid: true,
        validationError: '',
        editable: true,
        readOnly: false,
      },
      {
        key: 'DifficultyLevel',
        value: 'Custom-Test',
        displayValue: 'Custom-Test',
        label: 'Difficulty Level',
        group: 'World and economy',
        type: 'string',
        options: [],
        inverted: false,
        supported: true,
        valid: true,
        validationError: '',
        editable: false,
        readOnly: true,
      },
      {
        key: 'FutureRetailKey',
        value: 'leave-me',
        displayValue: 'leave-me',
        label: 'FutureRetailKey',
        group: 'Other values',
        type: 'string',
        options: [],
        inverted: false,
        supported: false,
        valid: true,
        validationError: '',
        editable: false,
        readOnly: true,
      },
    ]
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({
      available: true,
      readOnly: false,
      source: 'funcom-servergroup-user-ini-config',
      authority: 'Funcom BattleGroup operator configuration',
      revision: 'current',
      target: { available: true, stopped: true, serverPodCount: 0 },
      settings,
      malformedLines: [],
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
    vi.stubGlobal('fetch', fetchMock)

    render(<OfficialRetailServerSettingsCard vmRunning />)

    const floatInput = await screen.findByRole('spinbutton', { name: 'Gathering Amount exact value' })
    const intInput = screen.getByRole('spinbutton', { name: 'Maximum Sub-Fief Amount exact value' })
    const defaultButton = screen.getByRole('button', { name: 'Default Settings' })
    expect(floatInput).toHaveValue(2)
    expect(intInput).toHaveValue(5)
    expect(intInput).toHaveAttribute('step', '1')
    expect(screen.getByRole('slider', { name: 'Maximum Sub-Fief Amount slider, range 0 to 25' })).toHaveAttribute('step', '1')

    fireEvent.click(defaultButton)

    expect(floatInput).toHaveAttribute('value', '1.000000')
    expect(intInput).toHaveAttribute('value', '3')
    expect(screen.getByText('Custom-Test')).toBeInTheDocument()
    expect(screen.getAllByText('leave-me')).toHaveLength(1)
    expect(screen.getByRole('button', { name: 'Save (2)' })).toBeEnabled()
    expect(fetchMock).toHaveBeenCalledOnce()
    expect(fetchMock.mock.calls.some(([, init]) => init?.method === 'PUT')).toBe(false)

    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }))
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2))
    expect(floatInput).toHaveAttribute('value', '2.000000')
    expect(intInput).toHaveAttribute('value', '5')
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled()
  })

  it('provides verified defaults and operator guidance for every supported Retail key', () => {
    expect(Object.keys(RETAIL_SETTING_GUIDANCE)).toHaveLength(47)
    for (const [key, guidance] of Object.entries(RETAIL_SETTING_GUIDANCE)) {
      expect(key).not.toBe('')
      expect(guidance.defaultValue).not.toBe('')
      expect(guidance.effect).toMatch(/[.!]$/)
    }
    expect(RETAIL_SETTING_GUIDANCE.NPCHealth.effect).toContain('tougher')
    expect(RETAIL_SETTING_GUIDANCE.NPCRespawnMultiplier.effect).not.toMatch(/easier|harder|faster|slower/)
    expect(RETAIL_SETTING_GUIDANCE.DifficultyLevel.defaultValue).toBe('Custom')
    expect(RETAIL_SETTING_GUIDANCE.PVPMode.defaultValue).toBe('Limited')
  })

  it('keeps malformed numeric settings on the existing exact-input fallback', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
      available: true,
      readOnly: false,
      source: 'funcom-servergroup-user-ini-config',
      authority: 'Funcom BattleGroup operator configuration',
      revision: 'current',
      target: { available: true, stopped: true, serverPodCount: 0 },
      settings: [{
        key: 'FiefdomLimit',
        value: 'not-a-number',
        displayValue: 'not-a-number',
        label: 'Maximum Sub-Fief Amount',
        group: 'World threats and building',
        type: 'int',
        options: [],
        inverted: false,
        supported: true,
        valid: false,
        validationError: "Unexpected int value 'not-a-number'.",
        editable: true,
        readOnly: false,
      }],
      malformedLines: [],
    }), { status: 200, headers: { 'Content-Type': 'application/json' } })))

    render(<OfficialRetailServerSettingsCard vmRunning />)

    expect(await screen.findByRole('spinbutton', { name: 'Maximum Sub-Fief Amount exact value' })).toBeInTheDocument()
    expect(screen.queryByRole('slider')).not.toBeInTheDocument()
    expect(screen.getByText("Unexpected int value 'not-a-number'.")).toBeInTheDocument()
  })
})
