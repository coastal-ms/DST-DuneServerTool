import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'
import { InstallLocationCard } from '../../src/pages/settings/InstallLocationCard'
import { api } from '../../src/api/client'

vi.mock('../../src/api/client', () => ({
  ApiError: class ApiError extends Error {
    body?: unknown
  },
  api: vi.fn(),
}))

beforeEach(() => {
  localStorage.clear()
  vi.mocked(api).mockImplementation(async (path, init) => {
    if (path === '/api/system/install-location') {
      return { ok: true, path: 'C:\\Program Files\\Dune Server Tool', installed: true }
    }
    if (path === '/api/system/install-location/open' && init?.method === 'POST') {
      return { ok: true, path: 'C:\\Program Files\\Dune Server Tool' }
    }
    throw new Error(`Unexpected API call: ${path}`)
  })
})

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('InstallLocationCard', () => {
  it('shows and opens the DST install folder', async () => {
    const user = userEvent.setup()
    render(<InstallLocationCard />)

    expect(await screen.findByText('C:\\Program Files\\Dune Server Tool')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: /open folder/i }))

    await waitFor(() => {
      expect(api).toHaveBeenCalledWith('/api/system/install-location/open', { method: 'POST' })
    })
  })
})
