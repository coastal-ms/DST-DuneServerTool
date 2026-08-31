import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import React from 'react'
import { SPONSORS } from '../src/data/sponsors'
import { SponsorsCredits } from '../src/pages/SponsorsCredits'
import { LEGACY_ROUTE_MANIFEST } from '../src/platform/routes'
import { getVisibleNavItems } from '../src/nav'

afterEach(cleanup)

describe('Sponsors & Credits', () => {
  it('uses the typed sponsor source as the complete Discord Sponsor list', () => {
    expect(SPONSORS).toEqual([
      { name: 'Hawk_I5', recognition: 'Discord Sponsor' },
      { name: 'Ed O.', recognition: 'Discord Sponsor' },
    ])
  })

  it('renders restrained credits and one separate support action', () => {
    render(<SponsorsCredits />)

    expect(screen.getByRole('heading', { name: 'Sponsors & Credits' })).toBeInTheDocument()
    expect(screen.getByRole('list', { name: 'Discord Sponsors' })).toHaveTextContent('Hawk_I5')
    expect(screen.getByRole('list', { name: 'Discord Sponsors' })).toHaveTextContent('Ed O.')
    expect(screen.getAllByText('Discord Sponsor')).toHaveLength(2)
    expect(screen.getByRole('link', { name: /Buy Me a Coffee/ })).toHaveAttribute(
      'href',
      'https://buymeacoffee.com/coastal_dst',
    )
  })

  it('is lazy-routed and visible to local and remote full-portal viewers', () => {
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
  })
})
