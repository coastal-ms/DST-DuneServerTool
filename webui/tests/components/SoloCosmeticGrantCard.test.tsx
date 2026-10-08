import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  SoloCosmeticGrantCard,
} from '../../src/pages/SoloMode'
import type { CosmeticEntry } from '../../src/api/gameplay'

const catalog: CosmeticEntry[] = [
  { template: 'DesertSwatch', name: 'Desert Dye', group: 'Swatches (Dyes)' },
  { template: 'ScoutSetVariant', name: 'Scout Set', group: 'Armor & Suit Sets' },
]

afterEach(cleanup)

describe('SoloCosmeticGrantCard', () => {
  it('uses the shared curated bulk catalog and skips saved and held tokens', async () => {
    const user = userEvent.setup()
    const onBulkGrant = vi.fn(async () => {})
    const entries: CosmeticEntry[] = [
      { template: 'ChoamSet', name: 'CHOAM', group: 'Building Sets - Other', bulk_building_set: true },
      { template: 'Terrarium', name: 'Terrarium', group: 'Building Sets - Decor', bulk_building_set: true },
      { template: 'Developer_Storage', name: 'Developer Storage', group: 'Building Sets - Developer Storage', bulk_building_set: false },
      { template: 'Dye', name: 'Dye', group: 'Swatches (Dyes)' },
    ]
    render(<SoloCosmeticGrantCard busy={false} disabled={false} loadCatalog={async () => entries}
      ownership={{ available: true, owned: ['choamset', 'Dye'], unlocked: ['choamset'], pending: ['Dye'], error: '' }}
      onGrant={vi.fn()} onBulkGrant={onBulkGrant} />)
    await user.click(await screen.findByRole('button', { name: 'All Building Sets (1 missing)' }))
    expect(onBulkGrant).toHaveBeenCalledWith('building-sets', 'All Building Sets')
    expect(screen.getByRole('button', { name: 'All Dyes (0 missing)' })).toBeDisabled()
    await user.selectOptions(screen.getByRole('combobox'), 'ChoamSet')
    expect(screen.getByRole('button', { name: 'Grant unlock' })).toBeEnabled()
    expect(screen.getByText(/Unlock record saved; in-game usability is unverified/)).toBeInTheDocument()
    await user.selectOptions(screen.getByRole('combobox'), 'Dye')
    expect(screen.getByRole('button', { name: 'Grant unlock' })).toBeEnabled()
    expect(screen.getByText(/Unlock token already held in inventory/)).toBeInTheDocument()
    await user.selectOptions(screen.getByRole('combobox'), 'Developer_Storage')
    expect(screen.getByRole('button', { name: 'Grant unlock' })).toBeEnabled()
  })

  it('grants a selected token even when the same token is already held', async () => {
    const user = userEvent.setup()
    const onGrant = vi.fn(async () => {})
    render(<SoloCosmeticGrantCard busy={false} disabled={false}
      loadCatalog={async () => catalog}
      ownership={{ available: true, owned: ['DesertSwatch'], unlocked: [], pending: ['DesertSwatch'], error: '' }}
      onGrant={onGrant} />)
    await user.selectOptions(await screen.findByRole('combobox'), 'DesertSwatch')
    await user.click(screen.getByRole('button', { name: 'Grant unlock' }))
    expect(onGrant).toHaveBeenCalledWith('DesertSwatch', 'Desert Dye')
  })

  it('allows retrying a saved building patent without an inventory token', async () => {
    const user = userEvent.setup()
    const onGrant = vi.fn(async () => {})
    const template = 'MTX_Atre_Troopship_Relief_Placeable_Patent'
    render(<SoloCosmeticGrantCard busy={false} disabled={false}
      loadCatalog={async () => [{ template, name: 'Atreides Warship Carving', group: 'Building Sets - Decor' }]}
      ownership={{ available: true, owned: [template], unlocked: [template], pending: [], error: '' }}
      onGrant={onGrant} />)
    await user.selectOptions(await screen.findByRole('combobox'), template)
    await user.click(screen.getByRole('button', { name: 'Grant unlock' }))
    expect(onGrant).toHaveBeenCalledWith(template, 'Atreides Warship Carving')
  })

  it('blocks bulk grants while ownership is unavailable or the save is disabled', async () => {
    const entries: CosmeticEntry[] = [{ template: 'Set', name: 'Set', group: 'Building Sets - Other', bulk_building_set: true }]
    render(<SoloCosmeticGrantCard busy={false} disabled={false} loadCatalog={async () => entries}
      onGrant={vi.fn()} onBulkGrant={vi.fn()} />)
    expect(await screen.findByRole('button', { name: 'All Building Sets (1 missing)' })).toBeDisabled()
  })
  it('grants the visible selection and disables a selection hidden by filtering', async () => {
    const user = userEvent.setup()
    const onGrant = vi.fn(async () => {})
    render(
      <SoloCosmeticGrantCard
        busy={false}
        disabled={false}
        loadCatalog={async () => catalog}
        onGrant={onGrant}
      />,
    )

    const picker = await screen.findByRole('combobox')
    const search = screen.getByRole('textbox')
    const grant = screen.getByRole('button', { name: 'Grant unlock' })

    await user.selectOptions(picker, 'ScoutSetVariant')
    await user.click(grant)
    expect(onGrant).toHaveBeenCalledWith('ScoutSetVariant', 'Scout Set')

    await user.type(search, 'desert')
    await waitFor(() => expect(grant).toBeDisabled())
  })
})
