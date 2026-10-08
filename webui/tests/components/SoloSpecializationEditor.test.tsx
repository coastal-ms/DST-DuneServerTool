// @vitest-environment jsdom
import { cleanup, render, screen, fireEvent } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { countMaxSoloSpecializations, SoloSpecializationEditor } from '../../src/pages/SoloMode'

describe('Solo specialization level editor', () => {
  afterEach(cleanup)
  it('does not count old or unknown rows as a missing Retail specialization', () => {
    const oldRows = [0, 1, 2, 3, 4].map(trackType => ({ trackType, level: 100 }))
    expect(countMaxSoloSpecializations(oldRows, false)).toBe(4)
    expect(countMaxSoloSpecializations(oldRows, true)).toBe(5)
    expect(countMaxSoloSpecializations([...oldRows, { trackType: 5, level: 100 }, { trackType: 99, level: 100 }], false)).toBe(5)
  })
  it('retains the Legacy adapter track mapping', () => {
    render(<SoloSpecializationEditor legacyAdapter tracks={[0, 1, 2, 3, 4].map(trackType => ({ trackType, level: trackType + 10 }))} disabled={false} onSet={vi.fn()} />)
    for (const [index, name] of ['Combat', 'Crafting', 'Exploration', 'Gathering', 'Sabotage'].entries()) {
      expect((screen.getByLabelText(new RegExp(name)) as HTMLInputElement).value).toBe(String(index + 10))
    }
  })
  it('shows the Retail track IDs correctly and refreshes all five after maxing', () => {
    const props = { disabled: false, onSet: vi.fn() }
    const { rerender } = render(<SoloSpecializationEditor {...props} tracks={[
      { trackType: 1, level: 11 }, { trackType: 2, level: 22 },
      { trackType: 3, level: 33 }, { trackType: 4, level: 44 },
      { trackType: 5, level: 55 },
    ]} />)
    for (const [name, value] of [['Combat', '44'], ['Crafting', '11'], ['Exploration', '33'], ['Gathering', '22'], ['Sabotage', '55']]) {
      expect((screen.getByLabelText(new RegExp(name)) as HTMLInputElement).value).toBe(value)
    }
    rerender(<SoloSpecializationEditor {...props} tracks={[1, 2, 3, 4, 5].map(trackType => ({ trackType, level: 100 }))} />)
    for (const name of ['Combat', 'Crafting', 'Exploration', 'Gathering', 'Sabotage']) {
      expect((screen.getByLabelText(new RegExp(name)) as HTMLInputElement).value).toBe('100')
    }
  })
  it('lets an existing maxed track be lowered while explaining preserved rewards', () => {
    const onSet = vi.fn()
    const onResetRewards = vi.fn()
    render(<SoloSpecializationEditor tracks={[{ trackType: 1, level: 100 }]} disabled={false} onSet={onSet} onResetRewards={onResetRewards} />)
    const crafting = screen.getByLabelText(/Crafting/)
    fireEvent.change(crafting, { target: { value: '37' } })
    fireEvent.click(crafting.parentElement!.querySelector('button')!)
    expect(onSet).toHaveBeenCalledWith('Crafting', 37)
    expect(screen.getByText(/Existing rewards and skill points are preserved/)).toBeTruthy()
    fireEvent.change(crafting, { target: { value: '101' } })
    expect(crafting.parentElement!.querySelector('button')!.disabled).toBe(true)
    fireEvent.click(screen.getAllByText('Reset rewards')[1])
    expect(onResetRewards).toHaveBeenCalledWith('Crafting')
    expect(screen.getByText(/Max specializations grants the rewards again/)).toBeTruthy()
  })
})
