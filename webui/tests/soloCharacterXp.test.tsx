import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { SoloCharacterXp } from '../src/components/solo/SoloCharacterXp'

afterEach(() => { cleanup(); vi.restoreAllMocks() })
describe('Solo character XP controls', () => {
  it('separates an additive grant from replacing total XP', () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true)
    const onRun = vi.fn()
    render(<SoloCharacterXp disabled={false} onRun={onRun} />)
    fireEvent.click(screen.getByRole('button', { name: 'Add character XP' }))
    fireEvent.click(screen.getByRole('button', { name: 'Set character XP' }))
    expect(onRun.mock.calls).toEqual([['add', 5000], ['set', 5000]])
  })
  it('does not replace XP after cancellation', () => {
    vi.spyOn(window, 'confirm').mockReturnValue(false)
    const onRun = vi.fn()
    render(<SoloCharacterXp disabled={false} onRun={onRun} />)
    fireEvent.click(screen.getByRole('button', { name: 'Set character XP' }))
    expect(onRun).not.toHaveBeenCalled()
  })
  it.each(['', '-1', '344441', '1.5'])('blocks invalid XP %s', amount => {
    render(<SoloCharacterXp disabled={false} onRun={vi.fn()} />)
    fireEvent.change(screen.getByLabelText('Character XP amount (0–344,440)'), { target: { value: amount } })
    for (const button of screen.getAllByRole('button')) expect((button as HTMLButtonElement).disabled).toBe(true)
  })
  it('blocks both writes for a running game or unvalidated profile', () => {
    render(<SoloCharacterXp disabled onRun={vi.fn()} />)
    for (const button of screen.getAllByRole('button')) expect((button as HTMLButtonElement).disabled).toBe(true)
  })
})
