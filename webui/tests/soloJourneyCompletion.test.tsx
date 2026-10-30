import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { SoloJourneyCompletion } from '../src/components/solo/SoloJourneyCompletion'

afterEach(cleanup)

it('offers numbered acts, Lost Harvest and Scourge in Story with their exact handlers', () => {
 const onRun = vi.fn()
 render(<SoloJourneyCompletion category="story" disabled={false} busy={false} onRun={onRun} />)
 const expected = ['DA_MQ_FindTheFremen', 'act2_complete', 'DA_MQ_TheGreatConventionPt2', 'DA_MQ_TheGreatConventionPt3', 'DA_DLC_LostHarvest', 'scourge_complete']
 expect(screen.getAllByRole('option').map(o => (o as HTMLOptionElement).value)).toEqual(expected)
 for (const value of expected) {
  fireEvent.change(screen.getByLabelText('Progression path'), {target: {value}})
  fireEvent.click(screen.getByRole('button', {name:'Complete selected journey'}))
  expect(onRun).toHaveBeenLastCalledWith(value)
 }
})
it('keeps full tutorial completion in its own category', () => {
 render(<SoloJourneyCompletion category="tutorial" disabled={false} busy={false} onRun={vi.fn()} />)
 expect(screen.getAllByRole('option')).toHaveLength(1)
 expect(screen.getByRole('option', {name:'Complete Full Tutorial (NPE)'})).toHaveValue('npe')
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
