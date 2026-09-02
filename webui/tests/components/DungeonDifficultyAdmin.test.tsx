import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../../src/api/client'
import {
  getDungeonDifficultySummary,
  normalizeDungeonDifficulty,
  type DungeonDifficultySummary,
} from '../../src/api/gameplay'
import { DungeonDifficultyAdmin } from '../../src/pages/gameplay/players/dungeon-difficulty'

vi.mock('../../src/api/gameplay', () => ({
  getDungeonDifficultySummary: vi.fn(),
  normalizeDungeonDifficulty: vi.fn(),
}))

const liveSummary: DungeonDifficultySummary = {
  ok: true,
  total: 120,
  aboveTarget: 8,
  maximum: 93,
  affectedPlayers: 14,
  target: 50,
  source: 'live',
}

describe('DungeonDifficultyAdmin', () => {
  const flash = vi.fn()

  beforeEach(() => {
    flash.mockReset()
    vi.mocked(getDungeonDifficultySummary).mockReset()
    vi.mocked(normalizeDungeonDifficulty).mockReset()
    vi.mocked(getDungeonDifficultySummary).mockResolvedValue(liveSummary)
  })

  afterEach(() => cleanup())

  const renderAdmin = (overrides: Partial<{ canWrite: boolean; demo: boolean }> = {}) =>
    render(
      <DungeonDifficultyAdmin
        canWrite={overrides.canWrite ?? true}
        demo={overrides.demo ?? false}
        flash={flash}
      />,
    )

  it('renders the preview and complete safety boundary', async () => {
    renderAdmin()

    expect(await screen.findByText('Normalize Dungeon Difficulty')).toBeInTheDocument()
    for (const value of ['120', '8', '93', '14', '50']) {
      expect(screen.getByText(value)).toBeInTheDocument()
    }
    expect(screen.getByText(/historical dungeon completion difficulty values/i)).toBeInTheDocument()
    expect(screen.getByText(/never changed or raised/i)).toBeInTheDocument()
    expect(screen.getByText(/all connected players are disconnected/i)).toBeInTheDocument()
    expect(screen.getByText(/rollback backup/i)).toBeInTheDocument()
  })

  it('requires the exact typed confirmation before submitting', async () => {
    renderAdmin()

    fireEvent.click(await screen.findByRole('button', { name: 'Normalize 8 completion rows' }))
    const dialog = screen.getByRole('alertdialog')
    const confirmButton = within(dialog).getByRole('button', { name: 'Back up and normalize' })
    const input = within(dialog).getByLabelText('Dungeon normalization confirmation')

    expect(confirmButton).toBeDisabled()
    fireEvent.change(input, { target: { value: 'normalize dungeons' } })
    expect(confirmButton).toBeDisabled()
    fireEvent.change(input, { target: { value: 'NORMALIZE DUNGEONS' } })
    expect(confirmButton).toBeEnabled()
  })

  it('supports cancellation without invoking the mutation', async () => {
    renderAdmin()

    fireEvent.click(await screen.findByRole('button', { name: 'Normalize 8 completion rows' }))
    fireEvent.click(within(screen.getByRole('alertdialog')).getByRole('button', { name: 'Cancel' }))

    expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument()
    expect(normalizeDungeonDifficulty).not.toHaveBeenCalled()
  })

  it.each([
    ['demo mode', { demo: true }],
    ['read-only permissions', { canWrite: false }],
  ])('disables mutation in %s', async (_name, props) => {
    vi.mocked(getDungeonDifficultySummary).mockResolvedValue(
      props.demo ? { ...liveSummary, source: 'demo' } : liveSummary,
    )
    renderAdmin(props)

    expect(await screen.findByRole('button', { name: 'Normalize 8 completion rows' })).toBeDisabled()
  })

  it('disables mutation when no rows need changing', async () => {
    vi.mocked(getDungeonDifficultySummary).mockResolvedValue({
      ...liveSummary,
      aboveTarget: 0,
      affectedPlayers: 0,
      maximum: 50,
    })
    renderAdmin()

    expect(await screen.findByRole('button', { name: 'Normalize 0 completion rows' })).toBeDisabled()
    expect(screen.getByText(/nothing needs changing/i)).toBeInTheDocument()
  })

  it('fails closed when the summary is unavailable and supports retry', async () => {
    vi.mocked(getDungeonDifficultySummary)
      .mockRejectedValueOnce(new Error('Dungeon schema unavailable'))
      .mockResolvedValueOnce(liveSummary)
    renderAdmin()

    expect(await screen.findByRole('alert')).toHaveTextContent('Dungeon schema unavailable')
    expect(screen.getByRole('button', { name: 'Normalize 0 completion rows' })).toBeDisabled()
    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }))
    expect(await screen.findByRole('button', { name: 'Normalize 8 completion rows' })).toBeEnabled()
  })

  it('refreshes after success and shows the rollback backup', async () => {
    vi.mocked(normalizeDungeonDifficulty).mockResolvedValue({
      ok: true,
      noOp: false,
      changed: true,
      verified: true,
      restarted: true,
      updated: 8,
      backupPath: '/mnt/backups/dungeon.tar.gz',
      backupSize: 2048,
      summary: { ...liveSummary, aboveTarget: 0, maximum: 50, affectedPlayers: 0 },
      message: 'Normalized 8 dungeon completion rows.',
    })
    vi.mocked(getDungeonDifficultySummary)
      .mockResolvedValueOnce(liveSummary)
      .mockResolvedValueOnce({ ...liveSummary, aboveTarget: 0, maximum: 50, affectedPlayers: 0 })
    renderAdmin()

    fireEvent.click(await screen.findByRole('button', { name: 'Normalize 8 completion rows' }))
    const dialog = screen.getByRole('alertdialog')
    fireEvent.change(within(dialog).getByLabelText('Dungeon normalization confirmation'), {
      target: { value: 'NORMALIZE DUNGEONS' },
    })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Back up and normalize' }))

    await waitFor(() => expect(normalizeDungeonDifficulty).toHaveBeenCalledWith('NORMALIZE DUNGEONS'))
    await waitFor(() => expect(getDungeonDifficultySummary).toHaveBeenCalledTimes(2))
    expect(flash).toHaveBeenCalledWith('Normalized 8 dungeon completion rows.')
    expect(screen.getByText('/mnt/backups/dungeon.tar.gz')).toBeInTheDocument()
  })

  it('keeps backup and recovery details visible after a partial failure', async () => {
    vi.mocked(normalizeDungeonDifficulty).mockRejectedValue(
      new ApiError(503, 'Post-write verification failed. The battlegroup start command was launched.', {
        ok: false,
        changed: true,
        verified: false,
        restarted: true,
        backupPath: '/mnt/backups/recovery.tar.gz',
      }),
    )
    renderAdmin()

    fireEvent.click(await screen.findByRole('button', { name: 'Normalize 8 completion rows' }))
    const dialog = screen.getByRole('alertdialog')
    fireEvent.change(within(dialog).getByLabelText('Dungeon normalization confirmation'), {
      target: { value: 'NORMALIZE DUNGEONS' },
    })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Back up and normalize' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('Post-write verification failed')
    expect(screen.getByText('/mnt/backups/recovery.tar.gz')).toBeInTheDocument()
    expect(flash).toHaveBeenCalledWith(expect.stringContaining('battlegroup start command was launched'), 'err')
  })
})
