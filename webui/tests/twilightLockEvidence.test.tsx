import React from 'react'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { TimeOfDayLockPanel } from '../src/pages/gameconfig/TwilightLockEvidenceCard'
import { EXPERIMENTAL_BLOCKED_DEFAULT_TARGETS } from '../src/pages/GameConfig'

const api = vi.hoisted(() => ({
  getExperiment: vi.fn(),
  stage: vi.fn(),
  restore: vi.fn(),
}))

vi.mock('../src/api/gameconfig', async importOriginal => {
  const actual = await importOriginal<typeof import('../src/api/gameconfig')>()
  return {
    ...actual,
    getTimeOfDayLockConfig: api.getExperiment,
    stageTimeOfDayPhase: api.stage,
    restoreTimeOfDayCycle: api.restore,
  }
})

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
  vi.clearAllMocks()
})

describe('Experimental twilight lock field-test harness', () => {
  it('stages only bounded candidates after confirmation and explains the experiment', async () => {
    const user = userEvent.setup()
    vi.spyOn(window, 'confirm').mockReturnValue(true)
    api.getExperiment.mockResolvedValue({
      available: true,
      evidenceStatus: 'visual-phases-verified',
      candidates: [
        { value: '18.0', label: 'Sunset - 18:00' },
        { value: '19.0', label: 'Twilight - 19:00' },
        { value: '20.0', label: 'Dark night - 20:00' },
        { value: '21.0', label: 'Full night - 21:00' },
        { value: '4.0', label: 'Dew harvest - 04:00' },
      ],
      clientApply: { available: false, reason: 'Unverified.' },
      restartRequired: true,
      minimumObservationMinutes: 30,
    })
    api.stage.mockResolvedValue({
      ok: true,
      staged: true,
      candidate: '18.0',
      backup: '/fixture/UserGame.ini.dstbak',
      restartRequired: true,
      clientApplied: false,
      message: 'Candidate staged.',
    })
    render(<TimeOfDayLockPanel vmRunning />)

    expect(await screen.findByText('Field-verified phases')).toBeInTheDocument()
    expect(screen.getByText(/Live testing verified sunset, twilight/)).toBeInTheDocument()
    expect(screen.getByText(/DST does not modify client INIs/)).toBeInTheDocument()
    expect(screen.getByText(/crafting timers continue/)).toBeInTheDocument()
    expect(screen.getAllByRole('option').map(option => option.getAttribute('value'))).toEqual([
      '18.0',
      '19.0',
      '20.0',
      '21.0',
      '4.0',
    ])
    await user.selectOptions(screen.getByLabelText('Candidate phase value'), '18.0')
    await user.click(screen.getByRole('button', { name: 'Back up & stage candidate' }))

    expect(api.stage).toHaveBeenCalledWith('18.0')
    expect(await screen.findByText(/Candidate staged/)).toBeInTheDocument()
  })

  it('restores normal cycle with one confirmed action', async () => {
    const user = userEvent.setup()
    vi.spyOn(window, 'confirm').mockReturnValue(true)
    api.getExperiment.mockResolvedValue({
      available: true,
      evidenceStatus: 'candidate-only',
      candidates: [{ value: '17.0', label: 'Candidate 17.0' }],
      clientApply: { available: false, reason: 'Unverified.' },
      restartRequired: true,
      minimumObservationMinutes: 30,
    })
    api.restore.mockResolvedValue({
      ok: true,
      restored: true,
      backup: '/fixture/UserGame.ini.dstbak',
      restartRequired: true,
      clientApplied: false,
      message: 'Normal cycle restored.',
    })
    render(<TimeOfDayLockPanel vmRunning />)
    await screen.findByText('Field-verified phases')

    await user.click(screen.getByRole('button', { name: 'Restore normal cycle' }))

    expect(api.restore).toHaveBeenCalledOnce()
    expect(await screen.findByText(/Normal cycle restored/)).toBeInTheDocument()
  })

  it('disables staging when the VM is unavailable and keeps raw defaults blocked', async () => {
    api.getExperiment.mockResolvedValue({
      available: true,
      evidenceStatus: 'candidate-only',
      candidates: [{ value: '17.0', label: 'Candidate 17.0' }],
      clientApply: { available: false, reason: 'Unverified.' },
      restartRequired: true,
      minimumObservationMinutes: 30,
    })
    render(<TimeOfDayLockPanel vmRunning={false} />)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Back up & stage candidate' })).toBeDisabled())
    expect(screen.getByText(/Start the server VM/)).toBeInTheDocument()
    expect(EXPERIMENTAL_BLOCKED_DEFAULT_TARGETS).toContain(
      'game||/script/dunesandbox.timeofdaysettings||m_starttime',
    )
  })
})
