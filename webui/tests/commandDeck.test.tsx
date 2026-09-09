// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import type { StatusSnapshot } from '../src/api/types'
import { getDeckDestinations, searchDeck } from '../src/layout/commandDeckModel'
import { COMMAND_DECK_KEY, setCommandDeck, useCommandDeck } from '../src/hooks/useCommandDeck'
import CommandDeckHome from '../src/pages/workspaces/CommandDeckHome'
import CommandDeck from '../src/layout/CommandDeck'

const data = vi.hoisted(() => ({
  owner: true,
  status: null as StatusSnapshot | null,
  error: null as string | null,
  loading: false,
}))
vi.mock('../src/hooks/useStatus', () => ({ useStatus: () => data }))
vi.mock('../src/auth/portalAccess', () => ({
  usePortalAccess: () => ({ canAccessOwnerSurfaces: data.owner }),
}))

beforeEach(() => {
  data.owner = true
  data.status = null
  data.error = null
  data.loading = false
  localStorage.clear()
  window.dispatchEvent(new StorageEvent('storage', { key: null }))
  window.history.replaceState({}, '', '/')
})
afterEach(() => { cleanup(); vi.restoreAllMocks() })

describe('Command Deck destinations', () => {
  it('uses the existing viewer restrictions including owner and Windows-only tools', () => {
    const admin = getDeckDestinations({ local: false, windows: true, canAccessOwnerSurfaces: false })
    expect(admin.some(item => item.to === '/players')).toBe(true)
    expect(admin.some(item => item.to === '/map?view=atlas')).toBe(true)
    for (const route of ['/database', '/settings', '/experimental', '/gameconfig', '/terminal', '/solo', '/setup']) {
      expect(admin.some(item => item.to === route)).toBe(false)
    }
    const linuxOwner = getDeckDestinations({ local: true, windows: false, canAccessOwnerSurfaces: true })
    expect(linuxOwner.some(item => item.to === '/solo')).toBe(false)
    expect(linuxOwner.some(item => item.to === '/database')).toBe(true)
  })

  it('searches available task descriptions and requires every search word', () => {
    const routes = getDeckDestinations({ local: true, windows: true, canAccessOwnerSurfaces: true })
    expect(searchDeck(routes, 'give ammo').map(item => item.to)).toEqual(['/players'])
    expect(searchDeck(routes, 'chat commands').map(item => item.to)).toEqual(['/players'])
    expect(searchDeck(routes, 'welcome back').map(item => item.to)).toEqual(['/players'])
    expect(searchDeck(routes, 'shared teleport destinations').map(item => item.to)).toEqual(['/players'])
    expect(searchDeck(routes, 'backup').map(item => item.to)).toEqual(['/database'])
    expect(searchDeck(routes, 'nonexistent')).toEqual([])
    expect(new Set(routes.map(item => item.to)).size).toBe(routes.length)
  })
})

describe('Command Deck opt-in', () => {
  function Mode() {
    const enabled = useCommandDeck()
    return <button onClick={() => setCommandDeck(!enabled)}>{enabled ? 'Deck' : 'Classic'}</button>
  }
  it('defaults to classic and synchronizes consumers without a page reload', () => {
    render(<><Mode /><Mode /></>)
    expect(screen.getAllByText('Classic')).toHaveLength(2)
    fireEvent.click(screen.getAllByText('Classic')[0])
    expect(screen.getAllByText('Deck')).toHaveLength(2)
    expect(localStorage.getItem(COMMAND_DECK_KEY)).toBe('1')
    act(() => {
      localStorage.setItem(COMMAND_DECK_KEY, '0')
      window.dispatchEvent(new StorageEvent('storage', { key: COMMAND_DECK_KEY }))
    })
    expect(screen.getAllByText('Classic')).toHaveLength(2)
  })
  it('switches in memory if preference storage is blocked', () => {
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('blocked') })
    render(<Mode />)
    fireEvent.click(screen.getByText('Classic'))
    expect(screen.getByText('Deck')).toBeInTheDocument()
  })
})

describe('Command Deck home', () => {
  it('shows missing data honestly and keeps detailed overview accessible', () => {
    const details = vi.fn()
    render(<CommandDeckHome onDetails={details} />)
    expect(screen.getByText('No maps reported.')).toBeInTheDocument()
    expect(screen.getByText('Waiting for server status')).toBeInTheDocument()
    fireEvent.click(screen.getAllByRole('button', { name: 'Detailed overview' })[0])
    expect(details).toHaveBeenCalledOnce()
  })
  it('renders reported states and zero players without claiming live freshness', () => {
    data.status = {
      ts: '2026-09-05T12:00:00Z', serverName: 'Preview server',
      vm: { exists: true, running: true, state: 'Running', name: 'Preview VM', ip: null, uptime: 50 },
      ports: null,
      bg: { available: true, state: 'starting', info: { status: 'Starting', database: 'Ready', director: '', gateway: '', uptime: '' },
        gameServers: [{ map: 'Survival_1', phase: 'Pending', ready: 'False', players: '0', age: '2m' }] },
    }
    data.error = 'Connection interrupted'
    render(<CommandDeckHome onDetails={() => {}} />)
    expect(screen.getByText(/Showing last known state/)).toBeInTheDocument()
    expect(screen.getByText(/Status refresh failed/)).toBeInTheDocument()
    expect(screen.getByText('starting')).toBeInTheDocument()
    expect(screen.getByText('Pending')).toBeInTheDocument()
    expect(screen.getByText('Not ready')).toBeInTheDocument()
    expect(screen.getByText('0')).toBeInTheDocument()
  })
  it('finds an existing tool without executing any server request', () => {
    const fetch = vi.spyOn(window, 'fetch')
    render(<CommandDeckHome onDetails={() => {}} />)
    fireEvent.change(screen.getByRole('textbox', { name: 'Search DST tasks' }), { target: { value: 'ammo' } })
    expect(screen.getByRole('link', { name: /Inspect a player/ })).toHaveAttribute('href', '/players')
    expect(fetch).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Clear task search' }))
    expect(screen.getByRole('textbox', { name: 'Search DST tasks' })).toHaveValue('')
  })
})

describe('Command Deck navigation', () => {
  it('supports keyboard task search and keeps all permitted destinations available', () => {
    render(<CommandDeck collapsed={false} />)
    fireEvent.keyDown(window, { key: 'k', ctrlKey: true })
    expect(screen.getByRole('textbox', { name: 'Find a task' })).toHaveFocus()
    fireEvent.change(screen.getByRole('textbox', { name: 'Find a task' }), { target: { value: 'backup' } })
    expect(screen.getByRole('link', { name: 'Database' })).toHaveAttribute('href', '/database')
    fireEvent.keyDown(screen.getByRole('textbox', { name: 'Find a task' }), { key: 'Escape' })
    expect(screen.getByRole('link', { name: 'Sponsors & Credits' })).toBeInTheDocument()
  })
})
