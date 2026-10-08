import { afterEach, expect, it, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import { AppShell } from '../src/layout/AppShell'
import { COMMAND_DECK_KEY, setCommandDeck } from '../src/hooks/useCommandDeck'

vi.mock('../src/hooks/useInstallationMode', () => ({ useSoloInstallation: () => true }))
vi.mock('../src/auth/portalAccess', () => ({ usePortalAccess: () => ({ canAccessOwnerSurfaces: true }) }))
vi.mock('../src/components/DecoupleNoticeModal', () => ({ DecoupleNoticeModal: () => null }))
vi.mock('../src/components/OnlinePlayerGuardModal', () => ({ OnlinePlayerGuardModal: () => null }))
vi.mock('../src/components/UpdateBanner', () => ({ UpdateBanner: () => null }))
vi.mock('../src/components/SectionJumpNav', () => ({ SectionJumpNav: () => null }))
vi.mock('../src/layout/MenuBar', () => ({ MenuBar: () => null }))
vi.mock('../src/layout/StatusBar', () => ({ StatusBar: () => <p>Server status</p> }))
vi.mock('../src/layout/Sidebar', () => ({ Sidebar: () => <p>Classic navigation</p> }))
vi.mock('../src/layout/SpatialFrame', () => ({ default: () => <p>Command Deck</p> }))

afterEach(() => { cleanup(); setCommandDeck(false); localStorage.clear() })

it('keeps Solo Classic while preserving the saved full-mode Command Deck preference', async () => {
  setCommandDeck(true)
  window.history.replaceState({}, '', '/solo')
  render(<AppShell><p>Local save tools</p></AppShell>)
  expect(await screen.findByText('Classic navigation')).not.toBeNull()
  expect(screen.queryByText('Command Deck')).toBeNull()
  expect(screen.queryByText('Server status')).toBeNull()
  expect(localStorage.getItem(COMMAND_DECK_KEY)).toBe('1')
})
