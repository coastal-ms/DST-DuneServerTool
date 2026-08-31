import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import React, { useState } from 'react'
import userEvent from '@testing-library/user-event'
import { Sidebar } from '../src/layout/Sidebar'
import { BrowserRouter } from '../src/router'
import { SIDEBAR_ORDER_STORAGE_KEY } from '../src/hooks/useSidebarNavigationOrder'

vi.mock('../src/hooks/useUpdateCheck', () => ({
  useUpdateCheck: () => ({ data: null }),
}))

vi.mock('../src/auth/portalAccess', () => ({
  usePortalAccess: () => ({ canAccessOwnerSurfaces: true }),
}))

afterEach(() => {
  cleanup()
  localStorage.clear()
  window.history.replaceState(null, '', '/')
})

function renderSidebar(collapsed: boolean, onExpand?: () => void) {
  return render(
    <BrowserRouter>
      <Sidebar collapsed={collapsed} onExpand={onExpand} />
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

  it('shows one active Gameplay Admin gateway for direct gameplay workspace URLs', () => {
    window.history.replaceState(null, '', '/map?view=atlas')
    renderSidebar(false)

    expect(screen.queryByRole('link', { name: 'Map' })).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Gameplay Admin' })).toHaveAttribute('aria-current', 'page')
    expect(screen.getAllByRole('link').filter(link => link.hasAttribute('aria-current'))).toHaveLength(1)
  })

  it('requires explicit edit mode and prevents navigation while sorting', () => {
    renderSidebar(false)

    expect(screen.queryByRole('button', { name: /Reorder Server Overview/ })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Customize navigation' }))

    expect(screen.getByRole('button', { name: /Reorder Server Overview/ })).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Server Overview' })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Done' }))
    expect(screen.getByRole('link', { name: 'Server Overview' })).toBeInTheDocument()
  })

  it('expands the collapsed sidebar before entering edit mode', () => {
    function CollapsedHarness() {
      const [collapsed, setCollapsed] = useState(true)
      return <Sidebar collapsed={collapsed} onExpand={() => setCollapsed(false)} />
    }
    render(
      <BrowserRouter>
        <CollapsedHarness />
      </BrowserRouter>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Customize navigation' }))

    expect(screen.getByRole('button', { name: /Reorder Server Overview/ })).toBeInTheDocument()
  })

  it('supports keyboard sorting from the drag handle', async () => {
    const user = userEvent.setup()
    renderSidebar(false)
    await user.click(screen.getByRole('button', { name: 'Customize navigation' }))
    const operationsHandle = screen.getByRole('button', { name: 'Reorder Operations' })
    await user.click(operationsHandle)
    await user.keyboard('[Space][ArrowUp][Space]')

    const saved = JSON.parse(localStorage.getItem(SIDEBAR_ORDER_STORAGE_KEY) ?? 'null')
    expect(saved.groups.overview).toEqual(['/operations', '/', '/pods'])
  })
})
