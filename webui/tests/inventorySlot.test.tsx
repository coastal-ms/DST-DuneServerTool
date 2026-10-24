import React from 'react'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { SharedInventoryGroup } from '../src/api/gameplay'
import { InventorySlot } from '../src/components/inventory/InventorySlot'

const iconMount = vi.hoisted(() => vi.fn())
afterEach(() => {cleanup();vi.clearAllMocks()})
vi.mock('../src/components/inventory/InventoryItemIcon', () => ({
  InventoryItemIcon: () => { iconMount(); return <span aria-hidden="true" /> },
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
  it('closes the hovered preview without restoring another focused item', async () => {
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
      expect(screen.queryByRole('tooltip')).not.toBeInTheDocument()
    })
    await user.tab()
    expect(hovered).toHaveFocus()
    expect(within(screen.getByRole('tooltip')).getByText('Hovered item')).toBeInTheDocument()
  })
  it('dismisses previews when scrolling or moving the pointer outside the item', async () => {
    render(<InventorySlot item={group('Preview item')} onSelect={vi.fn()} />)
    const item=screen.getByRole('button',{name:/Preview item/})
    fireEvent.mouseEnter(item)
    expect(screen.getByRole('tooltip')).toBeInTheDocument()
    fireEvent.scroll(window)
    expect(screen.queryByRole('tooltip')).not.toBeInTheDocument()
    fireEvent.mouseEnter(item)
    expect(screen.getByRole('tooltip')).toBeInTheDocument()
    fireEvent.pointerMove(document.body)
    expect(screen.queryByRole('tooltip')).not.toBeInTheDocument()
  })
  it('supports dismissing a keyboard preview with Escape', async () => {
    const user=userEvent.setup()
    render(<InventorySlot item={group('Keyboard item')} onSelect={vi.fn()} />)
    await user.tab()
    expect(screen.getByRole('tooltip')).toBeInTheDocument()
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('tooltip')).not.toBeInTheDocument()
    expect(screen.getByRole('button',{name:/Keyboard item/})).toHaveFocus()
  })
})

it('renders a selectable text row without mounting any image component', () => {
  iconMount.mockClear()
  const select = vi.fn()
  const item = group('Text item')
  render(<InventorySlot item={item} showImages={false} onSelect={select} />)
  fireEvent.click(screen.getByRole('button', {name: /Text item/}))
  expect(select).toHaveBeenCalledWith(item)
  expect(iconMount).not.toHaveBeenCalled()
})
