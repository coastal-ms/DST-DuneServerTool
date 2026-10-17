import { useState } from 'react'
import { afterEach, expect, it } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { SoloNumericSettingInput, stepSoloNumber } from '../src/components/solo/SoloNumericSettingInput'

afterEach(cleanup)

function Control({ initial = '1.000000', integer = false, disabled = false }) {
  const [value, setValue] = useState(initial)
  return <SoloNumericSettingInput aria-label="Setting" value={value} precisionSource={initial} integer={integer} disabled={disabled} step={integer ? 1 : 'any'} onValueChange={setValue} />
}

it('adjusts a focused decimal by 0.1 and keeps its trailing zeroes and manually entered precision', () => {
  render(<Control />)
  const input = screen.getByRole('spinbutton') as HTMLInputElement
  input.focus()
  expect(fireEvent.wheel(input, { deltaY: -120 })).toBe(false)
  expect(input.value).toBe('1.100000')
  fireEvent.wheel(input, { deltaY: 120 })
  expect(input.value).toBe('1.000000')
  fireEvent.change(input, { target: { value: '14.1234567890000' } })
  fireEvent.wheel(input, { deltaY: -120 })
  expect(input.value).toBe('14.2234567890000')
})

it('leaves hover scrolling, blank values, disabled controls and zoom gestures alone', () => {
  const view = render(<Control />)
  const input = screen.getByRole('spinbutton') as HTMLInputElement
  expect(fireEvent.wheel(input, { deltaY: -120 })).toBe(true)
  expect(input.value).toBe('1.000000')
  input.focus()
  expect(fireEvent.wheel(input, { deltaY: -120, ctrlKey: true })).toBe(true)
  expect(input.value).toBe('1.000000')
  fireEvent.change(input, { target: { value: '' } })
  fireEvent.wheel(input, { deltaY: -120 })
  expect(input.value).toBe('')
  view.unmount()
  render(<Control disabled />)
  fireEvent.wheel(screen.getByRole('spinbutton'), { deltaY: -120 })
  expect((screen.getByRole('spinbutton') as HTMLInputElement).value).toBe('1.000000')
})

it('keeps whole-number settings integral and respects existing bounds without rounding decimals', () => {
  render(<Control initial="20" integer />)
  const input = screen.getByRole('spinbutton') as HTMLInputElement
  input.focus()
  fireEvent.wheel(input, { deltaY: -120 })
  expect(input.value).toBe('21')
  expect(stepSoloNumber('0.000000', -1, false, '0.000000', 0, 1)).toBe('0.000000')
  expect(stepSoloNumber('0.950000', 1, false, '0.950000', 0, 1)).toBe('1.000000')
  expect(stepSoloNumber('-0.050000', 1, false)).toBe('0.050000')
})
