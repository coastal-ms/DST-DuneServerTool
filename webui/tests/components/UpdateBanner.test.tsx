import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'

const { installUpdate, updateData } = vi.hoisted(() => ({
  installUpdate: vi.fn(),
  updateData: {
    available: true,
    installable: true,
    currentVersion: '13.8.4',
    latestVersion: '14.0.0',
    checkedAt: '2026-08-21T00:00:00Z',
    identityMismatch: false,
    releaseCommit: '',
  },
}))

vi.mock('../../src/api/update', () => ({
  installUpdate,
}))

vi.mock('../../src/hooks/useUpdateCheck', () => ({
  useUpdateCheck: () => ({
    data: updateData,
    error: null,
  }),
}))

import { UpdateBanner } from '../../src/components/UpdateBanner'

afterEach(() => {
  cleanup()
  installUpdate.mockReset()
  sessionStorage.clear()
  updateData.identityMismatch = false
  updateData.releaseCommit = ''
  updateData.latestVersion = '14.0.0'
})

describe('UpdateBanner', () => {
  it('requests an explicit silent banner install', async () => {
    installUpdate.mockResolvedValue({ launched: false, reason: 'test stop' })
    const user = userEvent.setup()
    render(<UpdateBanner />)
    await user.click(screen.getByRole('button', { name: 'Update now' }))
    expect(installUpdate).toHaveBeenCalledWith({ mode: 'silent', source: 'banner' })
  })

  it('offers the exact published build for a same-tag dev commit mismatch', () => {
    updateData.identityMismatch = true
    updateData.releaseCommit = 'abcdef1234567890abcdef1234567890abcdef12'
    updateData.latestVersion = '14.0.0-test10'
    render(<UpdateBanner />)
    expect(screen.getByText('Published build available:')).toBeInTheDocument()
    expect(screen.getByText('(this local/dev build uses a different commit)')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Install published build' })).toBeInTheDocument()
  })
})
