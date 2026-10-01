// @vitest-environment jsdom
import { render, screen, fireEvent } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { SoloSpecializationEditor } from '../../src/pages/SoloMode'

describe('Solo specialization level editor', () => {
  it('lets an existing maxed track be lowered while explaining preserved rewards', () => {
    const onSet = vi.fn()
    render(<SoloSpecializationEditor tracks={[{ trackType: 1, level: 100 }]} disabled={false} onSet={onSet} />)
    const crafting = screen.getByLabelText(/Crafting/)
    fireEvent.change(crafting, { target: { value: '37' } })
    fireEvent.click(crafting.parentElement!.querySelector('button')!)
    expect(onSet).toHaveBeenCalledWith('Crafting', 37)
    expect(screen.getByText(/Existing rewards and skill points are preserved/)).toBeTruthy()
    fireEvent.change(crafting, { target: { value: '101' } })
    expect(crafting.parentElement!.querySelector('button')!.disabled).toBe(true)
  })
})
