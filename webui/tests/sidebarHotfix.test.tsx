import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import React from 'react'
import { Sidebar } from '../src/layout/Sidebar'
import { BrowserRouter } from '../src/router'

vi.mock('../src/hooks/useUpdateCheck', () => ({
  useUpdateCheck: () => ({ data: null }),
}))

vi.mock('../src/auth/portalAccess', () => ({
  usePortalAccess: () => ({ canAccessOwnerSurfaces: true }),
}))

afterEach(() => cleanup())

function renderSidebar(collapsed: boolean) {
  return render(
    <BrowserRouter>
      <Sidebar collapsed={collapsed} />
    </BrowserRouter>,
  )
}

describe('sidebar hotfix links', () => {
  it('restores Buy Me a Coffee in the expanded sidebar and removes PowerShell', () => {
    renderSidebar(false)

    const support = screen.getByRole('link', { name: 'Buy Me a Coffee' })
    expect(support).toHaveAttribute('href', 'https://buymeacoffee.com/coastal_dst')
    expect(support).toHaveClass('flex')
    expect(screen.queryByRole('link', { name: 'PowerShell' })).not.toBeInTheDocument()
  })

  it('keeps the support link available when the sidebar is collapsed', () => {
    renderSidebar(true)

    const support = screen.getByTitle('Support development — Buy Me a Coffee')
    expect(support).toHaveClass('flex')
  })
})
