import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React, { useState } from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  ApiError,
  PlayerGuardCancelledError,
  withOnlinePlayerGuard,
} from '../../src/api/client'
import { OnlinePlayerGuardModal } from '../../src/components/OnlinePlayerGuardModal'

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

function Harness({ operation }: { operation: (force: boolean) => Promise<string> }) {
  const [status, setStatus] = useState('idle')
  const run = async () => {
    try {
      setStatus(await withOnlinePlayerGuard(operation))
    } catch (error) {
      setStatus(error instanceof PlayerGuardCancelledError ? 'cancelled' : 'failed')
    }
  }
  return (
    <>
      <OnlinePlayerGuardModal />
      <button type="button" onClick={() => { void run() }}>Run guarded action</button>
      <output>{status}</output>
    </>
  )
}

function unknownConflict() {
  return new ApiError(409, 'conflict', {
    ok: false,
    conflict: 'player_status_unknown',
    verificationFailure: 'timeout',
    playersOnline: null,
    playerNames: [],
    players: [],
    message: 'DST could not verify whether players are online. The query timed out.',
  })
}

describe('OnlinePlayerGuardModal', () => {
  it('defaults focus to safe cancel, explains the risk, and cancels with Escape', async () => {
    const user = userEvent.setup()
    const nativeConfirm = vi.spyOn(window, 'confirm')
    const operation = vi.fn(async () => { throw unknownConflict() })
    render(<Harness operation={operation} />)

    const launch = screen.getByRole('button', { name: 'Run guarded action' })
    await user.click(launch)

    expect(await screen.findByRole('alertdialog', { name: 'Player verification failed' })).toBeInTheDocument()
    expect(screen.getByText('Verification timed out')).toBeInTheDocument()
    expect(screen.getByText(/Connected players may still be online/i)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Cancel' })).toHaveFocus()

    await user.keyboard('{Escape}')
    await waitFor(() => expect(screen.getByText('cancelled')).toBeInTheDocument())
    expect(operation).toHaveBeenCalledTimes(1)
    expect(launch).toHaveFocus()
    expect(nativeConfirm).not.toHaveBeenCalled()
  })

  it('runs the forced retry only from the explicit destructive action', async () => {
    const user = userEvent.setup()
    const operation = vi.fn(async (force: boolean) => {
      if (!force) throw unknownConflict()
      return 'completed'
    })
    render(<Harness operation={operation} />)

    await user.click(screen.getByRole('button', { name: 'Run guarded action' }))
    const continueButton = await screen.findByRole('button', {
      name: 'Continue without verification',
    })
    await user.click(continueButton)

    await waitFor(() => expect(screen.getByText('completed')).toBeInTheDocument())
    expect(operation.mock.calls).toEqual([[false], [true]])
  })

  it('keeps keyboard focus inside the modal', async () => {
    const user = userEvent.setup()
    const operation = vi.fn(async () => { throw unknownConflict() })
    render(<Harness operation={operation} />)

    await user.click(screen.getByRole('button', { name: 'Run guarded action' }))
    const continueButton = await screen.findByRole('button', {
      name: 'Continue without verification',
    })
    continueButton.focus()
    await user.tab()

    expect(screen.getByRole('button', { name: 'Cancel and close' })).toHaveFocus()
  })
})
