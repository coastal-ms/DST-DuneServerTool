import React from 'react'
import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { BrowserRouter } from '../src/router'
import PlayersWorkspace from '../src/pages/workspaces/PlayersWorkspace'
import BasesWorkspace from '../src/pages/workspaces/BasesWorkspace'
import VehiclesWorkspace from '../src/pages/workspaces/VehiclesWorkspace'
import EconomyWorkspace from '../src/pages/workspaces/EconomyWorkspace'

vi.mock('../src/pages/gameplay/PlayersTab', () => ({
  PlayersTab: () => <div>Player admin fixture</div>,
}))

vi.mock('../src/pages/gameplay/BasesTab', () => ({
  BasesTab: () => <div>Bases fixture</div>,
}))

vi.mock('../src/components/inventory/SharedInventoryExplorer', () => ({
  SharedInventoryExplorer: ({
    entityTypes,
    unavailableReason,
  }: {
    entityTypes: string[]
    unavailableReason?: string
  }) => (
    <div>
      Inventory fixture: {entityTypes.join(',') || 'unavailable'}
      {unavailableReason && <span>{unavailableReason}</span>}
    </div>
  ),
}))

afterEach(() => {
  cleanup()
  window.history.replaceState(null, '', '/')
})

describe('inventory workspace embedding', () => {
  it('preserves Player admin as default and adds the shared player inventory view', () => {
    window.history.replaceState(null, '', '/players')
    const view = render(<BrowserRouter><PlayersWorkspace /></BrowserRouter>)
    expect(screen.getByText('Player admin fixture')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Player admin' })).toHaveAttribute('aria-current', 'page')

    view.unmount()
    window.history.replaceState(null, '', '/players?view=inventory')
    render(<BrowserRouter><PlayersWorkspace /></BrowserRouter>)
    expect(screen.getByText('Inventory fixture: player')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Inventory' })).toHaveAttribute('aria-current', 'page')
  })

  it('limits the Bases inventory view to proven storage containers', () => {
    window.history.replaceState(null, '', '/bases?view=inventory')
    render(<BrowserRouter><BasesWorkspace /></BrowserRouter>)
    expect(screen.getByText('Inventory fixture: storage')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Storage inventory' })).toHaveAttribute('aria-current', 'page')
  })

  it('keeps vehicle cargo visibly unavailable instead of mounting fleet writes', () => {
    window.history.replaceState(null, '', '/vehicles?view=cargo')
    render(<BrowserRouter><VehiclesWorkspace /></BrowserRouter>)
    expect(screen.getByText('Inventory fixture: unavailable')).toBeInTheDocument()
    expect(screen.getByText(/vehicle-to-cargo inventory join is not/i)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /queue removal/i })).not.toBeInTheDocument()
  })

  it('offers the combined proven inventory projection from Economy', () => {
    window.history.replaceState(null, '', '/economy?view=inventory')
    render(<BrowserRouter><EconomyWorkspace /></BrowserRouter>)
    expect(screen.getByText('Inventory fixture: player,storage')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Inventory' })).toHaveAttribute('aria-current', 'page')
  })
})
