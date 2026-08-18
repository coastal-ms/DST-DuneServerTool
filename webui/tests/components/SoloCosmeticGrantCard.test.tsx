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
