import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { SoloJourneyCompletion } from '../src/components/solo/SoloJourneyCompletion'

afterEach(cleanup)

it('offers all main quests and the full tutorial in one completion control', () => {
  const onRun = vi.fn()
  render(<SoloJourneyCompletion disabled={false} busy={false} onRun={onRun} />)
  expect(screen.getAllByRole('combobox')).toHaveLength(1)
  const choices = screen.getAllByRole('option') as HTMLOptionElement[]
  expect(choices).toHaveLength(6)
  for (const choice of choices) {
    fireEvent.change(screen.getByLabelText('Progression path'), { target: { value: choice.value } })
    fireEvent.click(screen.getByRole('button', { name: 'Complete selected journey' }))
    expect(onRun).toHaveBeenLastCalledWith(choice.value)
  }
})

it('keeps tutorial completion distinct from the A New Beginning quest', () => {
  render(<SoloJourneyCompletion disabled={false} busy={false} onRun={vi.fn()}
    progression={{ npeNodesComplete: 10, npeNodesTotal: 140, npeTagPresent: false,
      fremenNodesComplete: 20, fremenNodesTotal: 59, spiceSystemStatus: 'FullyEnabled' }} />)
  expect(screen.getByText('20/59 nodes · Prescience enabled')).toBeInTheDocument()
  fireEvent.change(screen.getByLabelText('Progression path'), { target: { value: 'npe' } })
  expect(screen.getByText(/mark the full tutorial finished/)).toBeInTheDocument()
  expect(screen.getByText('10/140 nodes · completion tag missing')).toBeInTheDocument()
  fireEvent.change(screen.getByLabelText('Progression path'), { target: { value: 'DA_MQ_ANewBeginning' } })
  expect(screen.queryByText(/mark the full tutorial finished/)).not.toBeInTheDocument()
  expect(screen.queryByText(/completion tag missing/)).not.toBeInTheDocument()
})

it.each([[true, false], [false, true]])('blocks changes when disabled=%s or busy=%s', (disabled, busy) => {
  const onRun = vi.fn()
  render(<SoloJourneyCompletion disabled={disabled} busy={busy} onRun={onRun} />)
  expect(screen.getByRole('combobox')).toBeDisabled()
  const button = screen.getByRole('button')
  expect(button).toBeDisabled()
  fireEvent.click(button)
  expect(onRun).not.toHaveBeenCalled()
})
