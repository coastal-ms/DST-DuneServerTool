import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import OperationsWorkspace from '../src/pages/workspaces/OperationsWorkspace'
import { COMMAND_DECK_KEY } from '../src/hooks/useCommandDeck'

const state = vi.hoisted(() => ({ role: 'admin' as 'admin' | 'player' | null, owner: false, local: false, refresh: vi.fn(async () => {}), error: null as string | null }))
vi.mock('../src/auth/PortalAuthGate', () => ({ usePortalAuth: () => ({ status: { accountLoginEnabled: true, account: { role: state.owner ? 'owner' : state.role } } }) }))
vi.mock('../src/util/viewer', () => ({ isLocalViewer: () => state.local }))
vi.mock('../src/hooks/useStatus', () => ({ useStatus: () => ({
  status: { ts: '2026-09-05T12:00:00Z', vm: { state: 'Running' }, bg: { state: 'running', gameServers: [] } },
  error: state.error, loading: false, refresh: state.refresh,
}) }))
beforeEach(() => { localStorage.setItem(COMMAND_DECK_KEY, '1'); state.owner = false; state.role = 'admin'; state.local = false; state.error = null; vi.clearAllMocks() })
afterEach(() => { cleanup(); localStorage.clear() })

describe('Contextual Operations desk', () => {
  it('keeps owner and local-only tools outside a remote admin task list', () => {
    render(<OperationsWorkspace />)
    expect(screen.getByRole('link', { name: /Service health/ })).toHaveAttribute('href', '/pods')
    expect(screen.queryByRole('link', { name: /^Backups/ })).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: /^Server updates/ })).toHaveAttribute('href', '/commands?task=updates')
    expect(screen.queryByRole('link', { name: /^Database/ })).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: /^PowerShell/ })).not.toBeInTheDocument()
    expect(screen.getByRole('region', { name: 'Server status' })).toHaveTextContent('Running')
  })
  it.each(['player', null] as const)('hides Server updates from remote role %s', role => {
    state.role = role
    render(<OperationsWorkspace />)
    expect(screen.queryByRole('link', { name: /^Server updates/ })).not.toBeInTheDocument()
  })
  it('searches existing tasks without dispatching an operation and reuses snapshot refresh', () => {
    state.owner = true
    state.local = true
    render(<OperationsWorkspace />)
    fireEvent.change(screen.getByRole('searchbox', { name: 'Find a server task' }), { target: { value: 'backup' } })
    expect(screen.getByRole('link', { name: /^Backups/ })).toHaveAttribute('href', '/database?section=database.maint.Take+Backup')
    expect(screen.getByRole('link', { name: /^Backup schedule/ })).toHaveAttribute('href', '/database?section=database.backupSchedule')
    expect(screen.queryByRole('link', { name: /All commands/ })).not.toBeInTheDocument()
    expect(state.refresh).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }))
    expect(state.refresh).toHaveBeenCalledOnce()
  })
  it('labels an unavailable observation without inventing a health verdict', () => {
    state.error = 'Status request failed'
    render(<OperationsWorkspace />)
    expect(screen.getByRole('status')).toHaveTextContent('Last available observation shown')
    expect(screen.queryByText('Healthy')).not.toBeInTheDocument()
  })
})
