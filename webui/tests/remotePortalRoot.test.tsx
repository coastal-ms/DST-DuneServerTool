import React, { lazy } from 'react'
import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { RemotePortalBoundary } from '../src/components/RemotePortalRoot'

const PendingRemoteApp = lazy(() => new Promise(() => {}))
const RejectedRemoteApp = lazy(() => Promise.reject(new Error('Remote route chunk failed.')))

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('RemotePortalRoot', () => {
  it('shows a visible loading state while the route chunk is pending', () => {
    render(
      <RemotePortalBoundary>
        <PendingRemoteApp />
      </RemotePortalBoundary>,
    )
    expect(screen.getByRole('status')).toHaveTextContent('Loading Remote Portal')
  })

  it('shows route error and reload recovery when the lazy chunk rejects', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    render(
      <RemotePortalBoundary>
        <RejectedRemoteApp />
      </RemotePortalBoundary>,
    )

    expect(await screen.findByText('Remote portal crashed')).toBeInTheDocument()
    expect(screen.getByText('Remote route chunk failed.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Reload page' })).toBeInTheDocument()
  })
})
