import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import React from 'react'
import { SUPPORTER_CREDITS } from '../src/data/sponsors'
import { MenuBar } from '../src/layout/MenuBar'
import { SponsorsCredits } from '../src/pages/SponsorsCredits'
import { LEGACY_ROUTE_MANIFEST } from '../src/platform/routes'
import { getVisibleNavItems } from '../src/nav'
import { BrowserRouter } from '../src/router'
import { PORTAL_HANDOFF_REQUEST_EVENT } from '../src/util/portalHandoff'

const shellHost = vi.hoisted(() => vi.fn(() => true))

vi.mock('../src/auth/portalAccess', () => ({
  usePortalAccess: () => ({ canAccessOwnerSurfaces: false }),
}))

vi.mock('../src/util/viewer', () => ({
  isLocalViewer: () => false,
  isWindowsViewer: () => true,
}))

vi.mock('../src/util/shellBridge', () => ({
  isShellHost: shellHost,
}))

const EXPECTED_CREDIT_NAMES = [
  'Decker (@decker177)',
  'Ogmosis (@ogmosis)',
  'boosterfuel (@boosterfuel)',
  'Techtonic (@techtonic001)',
  'Ken (@krazy2168)',
  'Pat (@pat.)',
  'Brandon M',
  'Daddy STATZY (@spiderstatz)',
  'Vosper (@vosper61)',
  'Murm (@murm9000)',
  'Derkuli (@ichbinderkuli)',
  'gd.py (@gd.py)',
  'Chumdizzle (@chumdizzle)',
  'Fargenbasteg (@fargenbasteg)',
  'elwicki (@elwicki)',
  'Maggie Malone (@magiemalone)',
  'William',
  'Ed O.',
] as const

afterEach(() => {
  cleanup()
  window.history.replaceState(null, '', '/')
})

describe('Sponsors & Credits', () => {
  it('uses the typed source as the complete, unique public credit list', () => {
    expect(SUPPORTER_CREDITS.map(credit => credit.displayName)).toEqual(EXPECTED_CREDIT_NAMES)
    expect(new Set(SUPPORTER_CREDITS.map(credit => credit.displayName)).size).toBe(18)
    expect(SUPPORTER_CREDITS.filter(credit => credit.recognition === 'Project Supporter')).toHaveLength(17)
    expect(SUPPORTER_CREDITS.filter(credit => credit.recognition === 'Discord Sponsor')).toEqual([
      { displayName: 'Ed O.', recognition: 'Discord Sponsor' },
    ])
  })

  it('renders every public credit once with one separate support action', () => {
    render(<SponsorsCredits />)

    expect(screen.getByRole('heading', { name: 'Sponsors & Credits' })).toBeInTheDocument()
    const credits = screen.getByRole('list', { name: 'Project supporters' })
    expect(within(credits).getAllByRole('listitem')).toHaveLength(18)
    for (const name of EXPECTED_CREDIT_NAMES) {
      expect(within(credits).getAllByText(name, { exact: true })).toHaveLength(1)
    }
    expect(within(credits).queryByText('Hawk_I5')).not.toBeInTheDocument()
    expect(within(credits).getAllByText('Project Supporter')).toHaveLength(17)
    expect(within(credits).getByText('Discord Sponsor')).toBeInTheDocument()
    expect(screen.getAllByRole('link', { name: /Buy Me a Coffee/ })).toHaveLength(1)
    expect(screen.getByRole('link', { name: /Buy Me a Coffee/ })).toHaveAttribute(
      'href',
      'https://buymeacoffee.com/coastal_dst',
    )
    const supportHeading = screen.getByRole('heading', { name: 'Support DST' })
    const creditsHeading = screen.getByRole('heading', { name: 'Project Supporters' })
    expect(supportHeading.compareDocumentPosition(creditsHeading) & Node.DOCUMENT_POSITION_FOLLOWING)
      .toBeTruthy()
  })

  it('puts durable remote setup first and hides local portal handoff inside Help', () => {
    const onPortalHandoff = vi.fn()
    window.addEventListener(PORTAL_HANDOFF_REQUEST_EVENT, onPortalHandoff, { once: true })
    render(
      <BrowserRouter>
        <MenuBar sidebarCollapsed={false} onToggleSidebar={vi.fn()} />
      </BrowserRouter>,
    )

    expect(screen.queryByRole('button', { name: 'Open local portal in browser' })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Help' }))
    expect(screen.getByRole('link', { name: /Remote Portal Setup/ })).toHaveAttribute(
      'href',
      'https://coastal-ms.github.io/DST-DuneServerTool/remote',
    )
    fireEvent.click(screen.getByRole('button', { name: /Open local portal in browser/ }))
    expect(onPortalHandoff).toHaveBeenCalledTimes(1)
  })

  it('is public and preserves one direct top-menu route without crowding intermediate widths', () => {
    expect(LEGACY_ROUTE_MANIFEST.find(route => route.path === '/sponsors')).toMatchObject({
      label: 'Sponsors & Credits',
      access: 'all',
    })
    const remotePaths = getVisibleNavItems({
      local: false,
      windows: false,
      canAccessOwnerSurfaces: false,
      includeSidebarHidden: false,
    }).map(item => item.to)
    expect(remotePaths).toContain('/sponsors')

    render(
      <BrowserRouter>
        <MenuBar sidebarCollapsed={false} onToggleSidebar={vi.fn()} />
      </BrowserRouter>,
    )
    const coffeeCreditsLink = screen.getByRole('link', { name: 'Thanks for the Coffee' })
    expect(coffeeCreditsLink).toHaveAttribute('href', '/sponsors')
    expect(coffeeCreditsLink).toHaveClass('hidden', 'xl:inline-flex')
    fireEvent.click(coffeeCreditsLink)
    expect(window.location.pathname).toBe('/sponsors')
  })
})
