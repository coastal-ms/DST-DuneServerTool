import React, { useState } from 'react'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { DataState, FreshnessBadge } from '../src/components/platform/DataState'
import { DetailPanel } from '../src/components/platform/DetailPanel'
import { WorkspaceLayout } from '../src/components/platform/WorkspaceLayout'
import { getWorkspace } from '../src/platform/workspaces'
import { BrowserRouter } from '../src/router'
import { GameplayAdminShell } from '../src/components/platform/GameplayAdminShell'

afterEach(() => cleanup())

describe('workspace presentation primitives', () => {
  it('presents distinct error, empty, unavailable, and freshness states', () => {
    render(
      <>
        <DataState state="error" message="Backend unavailable." />
        <DataState state="empty" message="No matching records." />
        <DataState state="unavailable" message="This source is not supported." />
        <FreshnessBadge state="stale" observedAt="2026-08-28T00:00:00Z" />
      </>,
    )
    expect(screen.getByRole('alert')).toHaveAttribute('data-data-state', 'error')
    expect(screen.getAllByRole('status')).toHaveLength(3)
    expect(screen.getByText('Stale')).toHaveAttribute('data-freshness-state', 'stale')
  })

  it('declares touch-sized keyboard navigation with horizontal scroll containment', async () => {
    const user = userEvent.setup()
    render(
      <BrowserRouter>
        <WorkspaceLayout
          workspace={getWorkspace('map')}
          activeTab="atlas"
          tabs={[
            { id: 'atlas', label: 'DD Atlas', to: '/map?view=atlas' },
            { id: 'lifecycle', label: 'Lifecycle', to: '/map?view=lifecycle' },
          ]}
        >
          <div>Map content</div>
        </WorkspaceLayout>
      </BrowserRouter>,
    )

    const navigation = screen.getByRole('navigation', { name: 'Map workspace views' })
    expect(navigation).toHaveClass('overflow-x-auto')
    expect(navigation.firstElementChild).toHaveClass('min-w-max')
    const atlas = screen.getByRole('link', { name: 'DD Atlas' })
    expect(atlas).toHaveClass('min-h-11')
    await user.tab()
    expect(atlas).toHaveFocus()
  })

  it('uses a focus-contained, keyboard-dismissible bottom-sheet/detail-panel shell', async () => {
    const user = userEvent.setup()
    const closeSpy = vi.fn()
    function Harness() {
      const [open, setOpen] = useState(false)
      return (
        <>
          <button onClick={() => setOpen(true)}>Open detail</button>
          <DetailPanel
            open={open}
            title="Vehicle detail"
            onClose={() => {
              closeSpy()
              setOpen(false)
            }}
          >
            <button>Secondary action</button>
          </DetailPanel>
        </>
      )
    }
    render(<Harness />)
    const trigger = screen.getByRole('button', { name: 'Open detail' })
    await user.click(trigger)
    expect(screen.getByRole('dialog', { name: 'Vehicle detail' })).toBeInTheDocument()
    const close = screen.getByRole('button', { name: 'Close detail panel' })
    expect(close).toHaveClass('h-11', 'w-11')
    expect(close).toHaveFocus()
    fireEvent.keyDown(document, { key: 'Tab', shiftKey: true })
    expect(screen.getByRole('button', { name: 'Secondary action' })).toHaveFocus()
    fireEvent.keyDown(document, { key: 'Tab' })
    expect(close).toHaveFocus()
    await user.keyboard('{Escape}')
    expect(closeSpy).toHaveBeenCalledOnce()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(trigger).toHaveFocus()
  })

  it('uses one horizontal, touch-sized Gameplay Admin navigator without a nested rail', async () => {
    const user = userEvent.setup()
    const { container } = render(
      <BrowserRouter>
        <GameplayAdminShell activeSection="players">
          <div>Player workspace content</div>
        </GameplayAdminShell>
      </BrowserRouter>,
    )

    const navigation = screen.getByRole('navigation', { name: 'Gameplay Admin sections' })
    expect(navigation).toHaveClass('overflow-x-auto', 'max-w-full')
    expect(navigation.firstElementChild).toHaveClass('min-w-max')
    expect(container.querySelector('aside')).toBeNull()
    expect(screen.getByRole('link', { name: 'Players' })).toHaveAttribute('aria-current', 'page')
    expect(screen.getByRole('link', { name: 'Map' })).toHaveAttribute('href', '/map')
    expect(screen.getByRole('link', { name: 'Economy' })).toHaveAttribute('href', '/economy')
    expect(screen.getAllByRole('link').filter(link => link.hasAttribute('aria-current'))).toHaveLength(1)
    for (const link of screen.getAllByRole('link')) expect(link).toHaveClass('min-h-11')
    await user.tab()
    expect(screen.getByRole('link', { name: 'Overview' })).toHaveFocus()
  })
})
