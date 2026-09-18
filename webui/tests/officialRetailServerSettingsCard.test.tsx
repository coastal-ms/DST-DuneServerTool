import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { OfficialRetailServerSettingsCard } from '../src/pages/gameconfig/OfficialRetailServerSettingsCard'

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
          label: 'Area Building Restrictions',
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

    expect(await screen.findByText('Area Building Restrictions')).toBeInTheDocument()
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
    const input = await screen.findByRole('spinbutton', { name: 'Maximum Sub-Fief Amount' })
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
})
