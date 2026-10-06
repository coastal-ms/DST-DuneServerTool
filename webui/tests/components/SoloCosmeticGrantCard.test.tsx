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
    expect(screen.getByRole('button', { name: 'Grant unlock' })).toBeDisabled()
    await user.selectOptions(screen.getByRole('combobox'), 'Developer_Storage')
    expect(screen.getByRole('button', { name: 'Grant unlock' })).toBeEnabled()
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
