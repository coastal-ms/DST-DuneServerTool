import { fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup } from '@testing-library/react'
import { SoloFactionProgression } from '../src/components/solo/SoloFactionProgression'

afterEach(() => { cleanup(); vi.restoreAllMocks() })
describe('Solo faction controls', () => {
  it('requires confirmation and sends the chosen faction and stage', () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true)
    const onRun = vi.fn()
    render(<SoloFactionProgression disabled={false} onRun={onRun} />)
    fireEvent.change(screen.getByLabelText('Faction'), { target: { value: 'harkonnen' } })
    fireEvent.click(screen.getByRole('button', { name: 'Apply Progression Unlock' }))
    expect(onRun).toHaveBeenCalledWith('harkonnen', 'rank19_eligible', 0)
  })
  it('does not write when a progression unlock is cancelled', () => {
    vi.spyOn(window, 'confirm').mockReturnValue(false)
    const onRun = vi.fn()
    render(<SoloFactionProgression disabled={false} onRun={onRun} />)
    fireEvent.click(screen.getByRole('button', { name: 'Apply Progression Unlock' }))
    expect(onRun).not.toHaveBeenCalled()
  })
  it('distinguishes adding reputation from replacing it', () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true)
    const onRun = vi.fn()
    render(<SoloFactionProgression disabled={false} onRun={onRun} />)
    fireEvent.click(screen.getByRole('button', { name: 'Add reputation' }))
    fireEvent.click(screen.getByRole('button', { name: 'Set reputation' }))
    expect(onRun.mock.calls).toEqual([['atreides', 'add-reputation', 100], ['atreides', 'set-reputation', 100]])
  })
  it.each(['', '-1', '12475', '1.5'])('blocks invalid reputation %s', amount => {
    render(<SoloFactionProgression disabled={false} onRun={vi.fn()} />)
    fireEvent.change(screen.getByLabelText('Faction reputation amount (0–12,474)'), { target: { value: amount } })
    expect((screen.getByRole('button', { name: 'Add reputation' }) as HTMLButtonElement).disabled).toBe(true)
  })
  it('disables every write for a running game or unvalidated profile', () => {
    render(<SoloFactionProgression disabled onRun={vi.fn()} />)
    for (const button of screen.getAllByRole('button')) expect((button as HTMLButtonElement).disabled).toBe(true)
  })
})
