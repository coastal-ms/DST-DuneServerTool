import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, expect, it, vi } from 'vitest'
import { EmoteGrantForm } from '../../src/components/EmoteGrantForm'

afterEach(cleanup)

it('keeps selections across searches and grants only those entries once', async () => {
  const user = userEvent.setup(), grant = vi.fn().mockResolvedValue(true)
  render(<EmoteGrantForm busy={false} onGrant={grant} />)
  expect(screen.queryByText(/Show saved records/)).not.toBeInTheDocument()
  expect(screen.getByText(/Learned emotes are not checked/)).toBeInTheDocument()
  await user.selectOptions(screen.getByRole('listbox'), 'Emote_Wave_01')
  await user.type(screen.getByLabelText('Search emotes'), 'Bow')
  await user.selectOptions(screen.getByRole('listbox'), 'Emote_Bow_01')
  await user.click(screen.getByRole('button', { name: 'Grant selected (2)' }))
  await waitFor(() => expect(screen.getByRole('button', { name: 'Grant selected (0)' })).toBeDisabled())
  expect(grant.mock.calls.map(([template]) => template).sort()).toEqual(['Emote_Bow_01', 'Emote_Wave_01'])
  expect(screen.getAllByText('Request submitted')).toHaveLength(2)
})

it('stops on failure and retries remaining requests without resending successful entries', async () => {
  const user = userEvent.setup(), grant = vi.fn().mockResolvedValueOnce(true).mockResolvedValueOnce(false).mockResolvedValue(true)
  render(<EmoteGrantForm busy={false} onGrant={grant} />)
  await user.selectOptions(screen.getByRole('listbox'), ['Emote_Bow_01', 'Emote_Clap_01', 'Emote_Wave_01'])
  await user.click(screen.getByRole('button', { name: 'Grant selected (3)' }))
  await screen.findByText('Request failed — see action result.')
  expect(grant).toHaveBeenCalledTimes(2)
  await user.click(screen.getByRole('button', { name: 'Grant selected (2)' }))
  await waitFor(() => expect(screen.getByRole('button', { name: 'Grant selected (0)' })).toBeDisabled())
  expect(grant.mock.calls.map(([template]) => template)).toEqual(['Emote_Bow_01', 'Emote_Clap_01', 'Emote_Clap_01', 'Emote_Wave_01'])
})

it('shows a thrown error and leaves later entries unsubmitted', async () => {
  const user = userEvent.setup(), grant = vi.fn().mockRejectedValue(new Error('Backpack is full'))
  render(<EmoteGrantForm busy={false} onGrant={grant} />)
  await user.selectOptions(screen.getByRole('listbox'), ['Emote_Bow_01', 'Emote_Wave_01'])
  await user.click(screen.getByRole('button', { name: 'Grant selected (2)' }))
  expect(await screen.findByRole('alert')).toHaveTextContent('Backpack is full')
  expect(grant).toHaveBeenCalledTimes(1)
  expect(screen.getByText('Not submitted')).toBeInTheDocument()
})

it('allows an intentional repeat after clearing the selection', async () => {
  const user = userEvent.setup(), grant = vi.fn().mockResolvedValue(true)
  render(<EmoteGrantForm busy={false} onGrant={grant} />)
  await user.selectOptions(screen.getByRole('listbox'), 'Emote_Wave_01')
  await user.click(screen.getByRole('button', { name: 'Grant selected (1)' }))
  await waitFor(() => expect(screen.getByRole('button', { name: 'Grant selected (0)' })).toBeDisabled())
  await user.click(screen.getByRole('button', { name: 'Clear selection' }))
  await user.selectOptions(screen.getByRole('listbox'), 'Emote_Wave_01')
  await user.click(screen.getByRole('button', { name: 'Grant selected (1)' }))
  await waitFor(() => expect(grant).toHaveBeenCalledTimes(2))
})
