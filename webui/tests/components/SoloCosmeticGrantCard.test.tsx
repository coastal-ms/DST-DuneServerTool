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
  it('reports the entire Solo selection to the completion popup',async()=>{
    const user=userEvent.setup(),summary=vi.fn()
    render(<SoloCosmeticGrantCard busy={false} disabled={false} loadCatalog={async()=>catalog} onGrant={vi.fn().mockResolvedValue(true)} onGrantSummary={summary} />)
    await user.selectOptions(await screen.findByRole('listbox'),catalog.map(entry=>entry.template))
    await user.click(screen.getByRole('button',{name:'Grant selected (2)'}))
    await waitFor(()=>expect(summary).toHaveBeenCalledTimes(1))
    expect(summary.mock.calls[0][0].message).toContain('2/2 selected grant requests submitted.')
    for(const entry of catalog)expect(summary.mock.calls[0][0].message).toContain(`${entry.name}: Submitted`)
  })
  it('finds individual batch appearances by name and forwards their character grant method', async () => {
    const user = userEvent.setup(), onGrant = vi.fn(async () => {})
    const entry: CosmeticEntry = {template:'appearance:B1C3_Shaman_Raider_Top',name:'Habiliments of the Hidden Hand Top',group:'Gear Appearances',grant_method:'character',customization_id:'appearance:B1C3_Shaman_Raider_Top'}
    render(<SoloCosmeticGrantCard busy={false} disabled={false} loadCatalog={async () => [entry,...catalog]} onGrant={onGrant} />)
    await screen.findByRole('listbox')
    await user.type(screen.getByRole('textbox'),'hidden hand')
    await user.selectOptions(screen.getByRole('listbox'),entry.template)
    expect(screen.getByText(/Saves this appearance directly/)).toBeInTheDocument()
    expect(screen.queryByText(/another token/)).not.toBeInTheDocument()
    await user.click(screen.getByRole('button',{name:/Grant selected/}))
    expect(onGrant).toHaveBeenCalledWith(entry.template,entry.name,entry)
  })

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
    await user.selectOptions(screen.getByRole('listbox'), 'ChoamSet')
    expect(screen.getByRole('button', { name: /Grant selected/ })).toBeEnabled()
    expect(screen.getByText(/Unlock record saved\. You can/)).toBeInTheDocument()
    await user.selectOptions(screen.getByRole('listbox'), 'Dye')
    expect(screen.getByRole('button', { name: /Grant selected/ })).toBeEnabled()
    expect(screen.getByText(/Unlock token already held in inventory/)).toBeInTheDocument()
    await user.selectOptions(screen.getByRole('listbox'), 'Developer_Storage')
    expect(screen.getByRole('button', { name: /Grant selected/ })).toBeEnabled()
  })

  it('grants a selected token even when the same token is already held', async () => {
    const user = userEvent.setup()
    const onGrant = vi.fn(async () => {})
    render(<SoloCosmeticGrantCard busy={false} disabled={false}
      loadCatalog={async () => catalog}
      ownership={{ available: true, owned: ['DesertSwatch'], unlocked: [], pending: ['DesertSwatch'], error: '' }}
      onGrant={onGrant} />)
    await user.selectOptions(await screen.findByRole('listbox'), 'DesertSwatch')
    await user.click(screen.getByRole('button', { name: /Grant selected/ }))
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
    await user.selectOptions(await screen.findByRole('listbox'), template)
    await user.click(screen.getByRole('button', { name: /Grant selected/ }))
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

    const picker = await screen.findByRole('listbox')
    const search = screen.getByRole('textbox')
    const grant = screen.getByRole('button', { name: /Grant selected/ })

    await user.selectOptions(picker, 'ScoutSetVariant')
    await user.click(grant)
    expect(onGrant).toHaveBeenCalledWith('ScoutSetVariant', 'Scout Set')

    await user.type(search, 'desert')
    await waitFor(() => expect(grant).toBeDisabled())
  })
})
