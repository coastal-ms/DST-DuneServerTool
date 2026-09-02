import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import React, { useState } from 'react'
import userEvent from '@testing-library/user-event'
import { Sidebar } from '../src/layout/Sidebar'
import { MenuBar } from '../src/layout/MenuBar'
import { BrowserRouter } from '../src/router'
import {
  SIDEBAR_ORDER_STORAGE_KEY,
  SIDEBAR_ORDER_V1_STORAGE_KEY,
} from '../src/hooks/useSidebarNavigationOrder'
import { PORTAL_HANDOFF_REQUEST_EVENT } from '../src/util/portalHandoff'

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
  it('keeps support page-local, restores Hawk recognition, and removes PowerShell', () => {
    renderSidebar(false)

    expect(screen.getByRole('link', { name: 'Sponsors & Credits' })).toHaveAttribute('href', '/sponsors')
    expect(screen.getByRole('link', { name: 'Buy Me a Coffee' })).toHaveAttribute(
      'href',
      'https://buymeacoffee.com/coastal_dst',
    )
    expect(screen.queryByRole('link', { name: 'PowerShell' })).not.toBeInTheDocument()
    expect(screen.getAllByText('Thank you Hawk_I5')).toHaveLength(1)
    expect(screen.queryByText('Decker (@decker177)')).not.toBeInTheDocument()
    expect(screen.queryByText('Ed O.')).not.toBeInTheDocument()
  })

  it('keeps Sponsors & Credits available when the sidebar is collapsed', () => {
    renderSidebar(true)

    expect(screen.getByTitle('Sponsors & Credits')).toHaveAttribute('href', '/sponsors')
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
    expect(screen.getByRole('textbox', { name: /Rename section Server Management/ })).toBeInTheDocument()
    const divider = screen.getByRole('textbox', { name: /Rename section Server Management/ })
    expect(divider).toHaveClass('text-accent-bright')
    expect(divider.closest('li')).toHaveClass('border-accent/65', 'bg-accent/[0.14]')
    expect(screen.queryByRole('link', { name: 'Server Overview' })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Done' }))
    expect(screen.getByRole('link', { name: 'Server Overview' })).toBeInTheDocument()
  })

  it('opens the local browser handoff only through the advanced Help request', () => {
    renderSidebar(false)
    fireEvent(window, new Event(PORTAL_HANDOFF_REQUEST_EVENT))

    expect(screen.getByRole('heading', { name: 'Open in web browser' })).toBeInTheDocument()
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
    const commandsHandle = screen.getByRole('button', { name: 'Reorder Commands' })
    commandsHandle.focus()
    await user.keyboard('[Space][ArrowUp][ArrowUp][ArrowUp][ArrowUp][Space]')

    const saved = JSON.parse(localStorage.getItem(SIDEBAR_ORDER_STORAGE_KEY) ?? 'null')
    expect(saved.version).toBe(3)
    expect(saved.items.findIndex((entry: { id: string }) => entry.id === '/commands'))
      .toBeLessThan(saved.items.findIndex((entry: { id: string }) => entry.id === 'divider:overview'))
  })

  it('creates, renames, moves, and removes a divider without removing pages', async () => {
    const user = userEvent.setup()
    renderSidebar(false)
    await user.click(screen.getByRole('button', { name: 'Customize navigation' }))
    await user.click(screen.getByRole('button', { name: 'Section' }))

    const input = screen.getByRole('textbox', { name: 'Rename section New section' })
    await user.clear(input)
    await user.type(input, 'Favorites')
    await user.keyboard('[Enter]')
    expect(screen.getByRole('textbox', { name: 'Rename section Favorites' })).toHaveValue('Favorites')

    const handle = screen.getByRole('button', { name: 'Reorder section Favorites' })
    handle.focus()
    await user.keyboard('[Space][ArrowUp][Space]')
    expect(JSON.parse(localStorage.getItem(SIDEBAR_ORDER_STORAGE_KEY) ?? 'null').items)
      .toContainEqual(expect.objectContaining({ type: 'divider', label: 'Favorites' }))

    await user.click(screen.getByRole('button', { name: 'Remove section Favorites' }))
    const saved = JSON.parse(localStorage.getItem(SIDEBAR_ORDER_STORAGE_KEY) ?? 'null')
    expect(saved.items).not.toContainEqual(expect.objectContaining({ label: 'Favorites' }))
    expect(saved.items.filter((entry: { type: string }) => entry.type === 'page').length).toBeGreaterThan(0)
  })

  it('cancels an inline divider rename with Escape', async () => {
    const user = userEvent.setup()
    renderSidebar(false)
    await user.click(screen.getByRole('button', { name: 'Customize navigation' }))

    const input = screen.getByRole('textbox', { name: 'Rename section Server Management' })
    await user.clear(input)
    await user.type(input, 'Temporary')
    await user.keyboard('[Escape]')

    expect(input).toHaveValue('Server Management')
    expect(localStorage.getItem(SIDEBAR_ORDER_STORAGE_KEY)).toBeNull()
  })

  it('migrates v1 customization and Reset restores canonical v3 preferences', async () => {
    localStorage.setItem(SIDEBAR_ORDER_V1_STORAGE_KEY, JSON.stringify({
      version: 1,
      groups: { overview: ['/operations', '/', '/pods'] },
    }))
    const user = userEvent.setup()
    renderSidebar(false)

    await waitFor(() => expect(localStorage.getItem(SIDEBAR_ORDER_STORAGE_KEY)).not.toBeNull())
    expect(localStorage.getItem(SIDEBAR_ORDER_V1_STORAGE_KEY)).toBeNull()
    await user.click(screen.getByRole('button', { name: 'Customize navigation' }))
    await user.click(screen.getByRole('button', { name: 'Reset' }))
    expect(localStorage.getItem(SIDEBAR_ORDER_STORAGE_KEY)).toBeNull()
    expect(screen.getAllByRole('textbox')[0]).toHaveValue('Server Management')
  })

  it('shows every optional page by default and marks protected pages as always shown', async () => {
    const user = userEvent.setup()
    renderSidebar(false)

    expect(screen.getByRole('link', { name: 'Operations' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Sponsors & Credits' })).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Customize navigation' }))
    expect(screen.queryByRole('button', { name: 'Hide Server Overview in sidebar' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Hide Sponsors & Credits in sidebar' })).not.toBeInTheDocument()
    expect(screen.getByLabelText('Server Overview is always shown')).toBeInTheDocument()
    expect(screen.getByLabelText('Sponsors & Credits is always shown')).toBeInTheDocument()
  })

  it('hides and restores an individual page while keeping it available in customization', async () => {
    const user = userEvent.setup()
    renderSidebar(false)

    await user.click(screen.getByRole('button', { name: 'Customize navigation' }))
    await user.click(screen.getByRole('button', { name: 'Hide Operations in sidebar' }))
    expect(screen.getByText('Operations')).toBeInTheDocument()
    expect(screen.getByText('Hidden')).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Done' }))
    expect(screen.queryByRole('link', { name: 'Operations' })).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Customize navigation' }))
    await user.click(screen.getByRole('button', { name: 'Show Operations in sidebar' }))
    await user.click(screen.getByRole('button', { name: 'Done' }))
    expect(screen.getByRole('link', { name: 'Operations' })).toBeInTheDocument()
  })

  it('removes an empty section from the sidebar and can restore it from customization', async () => {
    const user = userEvent.setup()
    renderSidebar(false)

    await user.click(screen.getByRole('button', { name: 'Customize navigation' }))
    await user.click(screen.getByRole('button', { name: 'Hide pages in section Gameplay Administration' }))
    await user.click(screen.getByRole('button', { name: 'Done' }))

    expect(screen.queryByRole('link', { name: 'Gameplay Admin' })).not.toBeInTheDocument()
    expect(screen.queryByText('Gameplay Administration')).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Customize navigation' }))
    expect(screen.getByRole('textbox', { name: 'Rename section Gameplay Administration' })).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Show pages in section Gameplay Administration' }))
    await user.click(screen.getByRole('button', { name: 'Done' }))
    expect(screen.getByRole('link', { name: 'Gameplay Admin' })).toBeInTheDocument()
  })

  it('persists hidden pages across reloads without changing the top navigation', async () => {
    const user = userEvent.setup()
    const first = renderSidebar(false)

    await user.click(screen.getByRole('button', { name: 'Customize navigation' }))
    await user.click(screen.getByRole('button', { name: 'Hide Operations in sidebar' }))
    await user.click(screen.getByRole('button', { name: 'Done' }))
    first.unmount()

    renderSidebar(false)
    expect(screen.queryByRole('link', { name: 'Operations' })).not.toBeInTheDocument()
    const saved = JSON.parse(localStorage.getItem(SIDEBAR_ORDER_STORAGE_KEY) ?? 'null')
    expect(saved.hiddenPageIds).toContain('/operations')

    render(
      <BrowserRouter>
        <MenuBar sidebarCollapsed={false} onToggleSidebar={vi.fn()} />
      </BrowserRouter>,
    )
    await user.click(screen.getByRole('button', { name: 'Server Management' }))
    expect(screen.getByRole('button', { name: 'Operations' })).toBeInTheDocument()
  })

  it('Reset restores default visibility and order', async () => {
    const user = userEvent.setup()
    renderSidebar(false)

    await user.click(screen.getByRole('button', { name: 'Customize navigation' }))
    await user.click(screen.getByRole('button', { name: 'Hide Operations in sidebar' }))
    const commandsHandle = screen.getByRole('button', { name: 'Reorder Commands' })
    commandsHandle.focus()
    await user.keyboard('[Space][ArrowUp][ArrowUp][ArrowUp][ArrowUp][Space]')
    await user.click(screen.getByRole('button', { name: 'Reset' }))

    expect(localStorage.getItem(SIDEBAR_ORDER_STORAGE_KEY)).toBeNull()
    expect(screen.getByRole('button', { name: 'Hide Operations in sidebar' })).toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: /^Reorder / })[0]).toHaveAccessibleName('Reorder section Server Management')
  })
})
