import React from 'react'
import { act, cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { BrowserRouter } from '../src/router'
import { MenuBar } from '../src/layout/MenuBar'
import { PageErrorBoundary } from '../src/components/PageErrorBoundary'
import { SectionErrorBoundary } from '../src/components/SectionErrorBoundary'

const access = vi.hoisted(() => ({ owner: true }))
const diagnostics = vi.hoisted(() => ({ build: vi.fn() }))

vi.mock('../src/auth/portalAccess', () => ({
  usePortalAccess: () => ({ canAccessOwnerSurfaces: access.owner }),
}))

vi.mock('../src/util/viewer', () => ({
  isLocalViewer: () => false,
  isWindowsViewer: () => true,
}))

vi.mock('../src/api/diagnostics', async importOriginal => {
  const actual = await importOriginal<typeof import('../src/api/diagnostics')>()
  return { ...actual, buildDiagnosticBundle: diagnostics.build }
})

function renderMenu() {
  return render(
    <BrowserRouter>
      <MenuBar sidebarCollapsed={false} onToggleSidebar={vi.fn()} />
    </BrowserRouter>,
  )
}

afterEach(() => {
  cleanup()
  access.owner = true
  vi.restoreAllMocks()
  vi.clearAllMocks()
})

describe('owner diagnostics package', () => {
  it('creates the package without opening GitHub and reports the exact result', async () => {
    const user = userEvent.setup()
    let finish!: (value: {
      ok: boolean
      path: string
      sizeBytes: number
      fileCount: number
      sanitized: boolean
      warnings: string[]
    }) => void
    diagnostics.build.mockReturnValue(new Promise(resolve => { finish = resolve }))
    const open = vi.spyOn(window, 'open').mockImplementation(() => null)
    renderMenu()

    await user.click(screen.getByRole('button', { name: 'Help' }))
    await user.click(screen.getByRole('button', { name: /Create Diagnostics Package/ }))

    expect(await screen.findByRole('heading', { name: /Creating diagnostics package/ })).toBeInTheDocument()
    expect(diagnostics.build).toHaveBeenCalledOnce()
    expect(open).not.toHaveBeenCalled()

    await act(async () => {
      finish({
        ok: true,
        path: 'C:\\Users\\Coastal\\Desktop\\DST-Diagnostics.zip',
        sizeBytes: 4096,
        fileCount: 3,
        sanitized: true,
        warnings: ['One optional log was unavailable.'],
      })
    })

    expect(screen.getByRole('heading', { name: 'Diagnostics package created' })).toBeInTheDocument()
    expect(screen.getByText('C:\\Users\\Coastal\\Desktop\\DST-Diagnostics.zip')).toBeInTheDocument()
    expect(screen.getByText(/3 files · 4 KB · redacted/)).toBeInTheDocument()
    expect(screen.getByText('One optional log was unavailable.')).toBeInTheDocument()
    expect(screen.getByText(/Explorer opened the ZIP on the server host/)).toBeInTheDocument()
    expect(screen.getByText(/DST Discord support thread/)).toBeInTheDocument()
  })

  it('hides the host-writing action from remote admins', async () => {
    access.owner = false
    const user = userEvent.setup()
    renderMenu()

    await user.click(screen.getByRole('button', { name: 'Help' }))

    expect(screen.queryByRole('button', { name: /Create Diagnostics Package/ })).not.toBeInTheDocument()
    expect(diagnostics.build).not.toHaveBeenCalled()
  })

  it('shows actionable recovery and retry after package creation fails', async () => {
    diagnostics.build.mockRejectedValue(new Error('Archive writer unavailable'))
    const user = userEvent.setup()
    renderMenu()

    await user.click(screen.getByRole('button', { name: 'Help' }))
    await user.click(screen.getByRole('button', { name: /Create Diagnostics Package/ }))

    expect(await screen.findByRole('heading', { name: 'Couldn’t create the diagnostics package' })).toBeInTheDocument()
    expect(screen.getByText('Archive writer unavailable')).toBeInTheDocument()
    expect(screen.getByText(/%APPDATA%\\DuneServer\\\.logs/)).toBeInTheDocument()
    expect(screen.getByText(/DST Discord support thread/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Try again' })).toBeInTheDocument()
  })
})

function Crash(): never {
  throw new Error('Fixture crash')
}

describe('error-boundary support guidance', () => {
  it('directs page and section failures to the diagnostics package and Discord', () => {
    vi.spyOn(console, 'error').mockImplementation(() => undefined)
    const page = render(
      <PageErrorBoundary pageName="Fixture page">
        <Crash />
      </PageErrorBoundary>,
    )

    expect(screen.getByText(/Help → Create Diagnostics Package/)).toBeInTheDocument()
    expect(screen.getByText(/DST Discord support thread/)).toBeInTheDocument()
    page.unmount()

    render(
      <SectionErrorBoundary name="Fixture section">
        <Crash />
      </SectionErrorBoundary>,
    )
    expect(screen.getByText(/Help → Create Diagnostics Package/)).toBeInTheDocument()
    expect(screen.getByText(/DST Discord support thread/)).toBeInTheDocument()
  })
})
