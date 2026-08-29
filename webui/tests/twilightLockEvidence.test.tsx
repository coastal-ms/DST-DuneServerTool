import React from 'react'
import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import { TwilightLockEvidenceCard } from '../src/pages/gameconfig/TwilightLockEvidenceCard'
import { EXPERIMENTAL_BLOCKED_DEFAULT_TARGETS } from '../src/pages/GameConfig'

afterEach(() => cleanup())

describe('Experimental twilight lock evidence gate', () => {
  it('refuses an unproven lock and documents apply, restoration, and field proof', async () => {
    render(<TwilightLockEvidenceCard />)

    expect(screen.getByText('Phase lock unavailable')).toBeInTheDocument()
    expect(screen.getByText(/m_StartTime=12.0/)).toBeInTheDocument()
    expect(screen.getByText(/effect, range, and apply behavior are unverified/)).toBeInTheDocument()
    expect(screen.getByText(/No recovered key or command selects twilight/)).toBeInTheDocument()
    expect(screen.getByText(/crafting, scheduled events, patrol timing, and server timers/)).toBeInTheDocument()
    expect(screen.getByText(/Restore normal cycle:/)).toBeInTheDocument()
    expect(screen.getByText(/remove the experimental/)).toBeInTheDocument()
    expect(screen.getByText(/every modified server and client INI/)).toBeInTheDocument()
    expect(screen.getByText(/Apply INIs & restart/)).toBeInTheDocument()
    expect(screen.getByText('This card does not change any setting.')).toBeInTheDocument()
    expect(screen.queryByRole('button')).not.toBeInTheDocument()
    expect(EXPERIMENTAL_BLOCKED_DEFAULT_TARGETS).toContain(
      'game||/script/dunesandbox.timeofdaysettings||m_starttime',
    )
  })
})
