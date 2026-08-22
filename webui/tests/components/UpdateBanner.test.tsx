import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'

const { installUpdate } = vi.hoisted(() => ({ installUpdate: vi.fn() }))

vi.mock('../../src/api/update', () => ({
  installUpdate,
}))

vi.mock('../../src/hooks/useUpdateCheck', () => ({
  useUpdateCheck: () => ({
    data: {
      available: true,
      installable: true,
      currentVersion: '13.8.4',
      latestVersion: '14.0.0',
      checkedAt: '2026-08-21T00:00:00Z',
    },
    error: null,
  }),
}))

import { UpdateBanner } from '../../src/components/UpdateBanner'

afterEach(() => {
  cleanup()
  installUpdate.mockReset()
  sessionStorage.clear()
  delete (window as unknown as { __duneUpdating?: boolean }).__duneUpdating
})

describe('UpdateBanner', () => {
  it('opens the visible installer for banner updates', async () => {
    installUpdate.mockResolvedValue({ launched: false, reason: 'test stop' })
    const user = userEvent.setup()
    render(<UpdateBanner />)
    await user.click(screen.getByRole('button', { name: 'Update now' }))
    expect(installUpdate).toHaveBeenCalledWith({ mode: 'interactive', source: 'banner' })
  })

  it('leaves reconnect recovery active while the visible wizard runs', async () => {
    installUpdate.mockResolvedValue({
      launched: true,
      mode: 'interactive',
      toVersion: '14.0.0-test9',
    })
    const user = userEvent.setup()
    render(<UpdateBanner />)
    await user.click(screen.getByRole('button', { name: 'Update now' }))

    expect(await screen.findByText(/Complete the visible wizard on the host PC/i)).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: /Updating Dune Server Tool/i })).not.toBeInTheDocument()
    expect((window as unknown as { __duneUpdating?: boolean }).__duneUpdating).not.toBe(true)
  })
})
