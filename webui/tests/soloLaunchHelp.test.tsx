import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { BrowserRouter } from '../src/router'
import { MenuBar } from '../src/layout/MenuBar'
import { api } from '../src/api/client'

vi.mock('../src/api/client', () => ({ api: vi.fn() }))
vi.mock('../src/hooks/useInstallationMode', async importOriginal => ({
  ...await importOriginal<typeof import('../src/hooks/useInstallationMode')>(),
  useSoloInstallation: () => true,
}))
vi.mock('../src/auth/portalAccess', () => ({ usePortalAccess: () => ({ canAccessOwnerSurfaces: true }) }))
vi.mock('../src/util/viewer', () => ({ isLocalViewer: () => true, isWindowsViewer: () => true }))
afterEach(() => { cleanup(); vi.clearAllMocks() })

it('exposes and saves Skip intro in Help for a Solo-only installation', async () => {
  let skipIntro = false
  vi.mocked(api).mockImplementation(async (path, options) => {
    if (path !== '/api/game/launch-preferences') throw new Error('Unexpected server request')
    if (options?.method === 'POST') skipIntro = JSON.parse(String(options.body)).skipIntro
    return { skipIntro }
  })
  render(<BrowserRouter><MenuBar sidebarCollapsed={false} onToggleSidebar={vi.fn()} /></BrowserRouter>)
  fireEvent.click(screen.getByRole('button', {name:'Help'}))
  const toggle = await screen.findByRole('menuitemcheckbox', {name:/Skip intro/})
  expect(toggle).toHaveAttribute('aria-checked', 'false')
  fireEvent.click(toggle)
  await waitFor(() => expect(toggle).toHaveAttribute('aria-checked', 'true'))
  expect(api).toHaveBeenCalledWith('/api/game/launch-preferences', {method:'POST',body:JSON.stringify({skipIntro:true})})
})
