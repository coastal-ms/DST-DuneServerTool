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

vi.mock('../src/pages/gameplay/ChatCommandsCard', () => ({
  ChatCommandsCard: () => <div>In-game commands fixture</div>,
}))

vi.mock('../src/pages/gameplay/WelcomeBackCard', () => ({
  WelcomeBackCard: () => <div>Welcome back fixture</div>,
}))

vi.mock('../src/pages/gameplay/BasesTab', () => ({
  BasesTab: () => <div>Bases fixture</div>,
}))

vi.mock('../src/pages/gameplay/BlueprintsTab', () => ({
  BlueprintsTab: () => <div>Blueprints fixture</div>,
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
  it('preserves Player admin as default and exposes every Players workspace view', () => {
    window.history.replaceState(null, '', '/players')
    const view = render(<BrowserRouter><PlayersWorkspace /></BrowserRouter>)
    expect(screen.getByText('Player admin fixture')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Player admin' })).toHaveAttribute('aria-current', 'page')
    expect(screen.getByRole('link', { name: 'Community tools' })).toHaveAttribute('href', '/players?view=community')

    view.unmount()
    window.history.replaceState(null, '', '/players?view=inventory')
    const inventory = render(<BrowserRouter><PlayersWorkspace /></BrowserRouter>)
    expect(screen.getByText('Inventory fixture: player')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Inventory' })).toHaveAttribute('aria-current', 'page')

    inventory.unmount()
    window.history.replaceState(null, '', '/players?view=community')
    render(<BrowserRouter><PlayersWorkspace /></BrowserRouter>)
    expect(screen.getByText('In-game commands fixture')).toBeInTheDocument()
    expect(screen.getByText('Welcome back fixture')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Community tools' })).toHaveAttribute('aria-current', 'page')
  })

  it('limits the Bases inventory view to proven storage containers', () => {
    window.history.replaceState(null, '', '/bases?view=inventory')
    render(<BrowserRouter><BasesWorkspace /></BrowserRouter>)
    expect(screen.getByText('Inventory fixture: storage')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Storage inventory' })).toHaveAttribute('aria-current', 'page')
  })

  it('makes the existing Blueprints tools discoverable from Bases', () => {
    window.history.replaceState(null, '', '/bases')
    const view = render(<BrowserRouter><BasesWorkspace /></BrowserRouter>)
    expect(screen.getByText('Bases fixture')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Blueprints' })).toHaveAttribute('href', '/bases?view=blueprints')
    expect(screen.getByRole('link', { name: 'Storage inventory' })).toHaveAttribute('href', '/bases?view=inventory')

    view.unmount()
    window.history.replaceState(null, '', '/bases?view=blueprints')
    render(<BrowserRouter><BasesWorkspace /></BrowserRouter>)
    expect(screen.getByText('Blueprints fixture')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Blueprints' })).toHaveAttribute('aria-current', 'page')
  })

  it('requires a vehicle selection before opening read-only cargo', () => {
    window.history.replaceState(null, '', '/vehicles?view=cargo')
    const view = render(<BrowserRouter><VehiclesWorkspace /></BrowserRouter>)
    expect(screen.getByText('No vehicle selected')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Choose from fleet' })).toHaveAttribute('href', '/vehicles?view=fleet')
    expect(screen.queryByText('Inventory fixture: vehicle')).not.toBeInTheDocument()

    view.unmount()
    window.history.replaceState(null, '', '/vehicles?view=cargo&scope_type=vehicle&scope_id=7')
    render(<BrowserRouter><VehiclesWorkspace /></BrowserRouter>)
    expect(screen.getByText('Inventory fixture: vehicle')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /queue removal/i })).not.toBeInTheDocument()
  })

  it('offers the combined proven inventory projection from Economy', () => {
    window.history.replaceState(null, '', '/economy?view=inventory')
    render(<BrowserRouter><EconomyWorkspace /></BrowserRouter>)
    expect(screen.getByText('Inventory fixture: player,storage')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Inventory' })).toHaveAttribute('aria-current', 'page')
  })
})
