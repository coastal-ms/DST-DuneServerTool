import React from 'react'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { SharedInventoryGroup } from '../src/api/gameplay'
import { InventorySlot } from '../src/components/inventory/InventorySlot'

vi.mock('../src/components/inventory/InventoryItemIcon', () => ({
  InventoryItemIcon: () => <span aria-hidden="true" />,
}))

function group(name: string): SharedInventoryGroup {
  return {
    groupKey: name.toLowerCase(),
    templateId: `${name}Template`,
    displayName: name,
    totalQuantity: 1,
    occurrenceCount: 1,
    locationCount: 1,
    quality: { min: 0, max: 0, mixed: false },
    metadata: {
      category: '',
      tier: 0,
      rarity: '',
      icon: '',
      stackMaximum: 0,
      volume: 0,
      vendorPrice: 0,
      isGradeable: false,
    },
  }
}

describe('InventorySlot preview coordination', () => {
  it('shows only the hovered preview while another slot remains focused', async () => {
    const user = userEvent.setup()
    render(
      <>
        <InventorySlot item={group('Focused item')} onSelect={vi.fn()} />
        <InventorySlot item={group('Hovered item')} onSelect={vi.fn()} />
      </>,
    )
    const focused = screen.getByRole('button', { name: /Focused item/ })
    const hovered = screen.getByRole('button', { name: /Hovered item/ })

    await user.tab()
    expect(focused).toHaveFocus()
    await waitFor(() => {
      expect(within(screen.getByRole('tooltip')).getByText('Focused item')).toBeInTheDocument()
    })

    fireEvent.mouseEnter(hovered)
    await waitFor(() => {
      expect(screen.getAllByRole('tooltip')).toHaveLength(1)
      expect(within(screen.getByRole('tooltip')).getByText('Hovered item')).toBeInTheDocument()
    })

    fireEvent.mouseLeave(hovered)
    await waitFor(() => {
      expect(screen.getAllByRole('tooltip')).toHaveLength(1)
      expect(within(screen.getByRole('tooltip')).getByText('Focused item')).toBeInTheDocument()
    })
  })
})
