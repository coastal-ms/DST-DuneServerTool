import { afterEach, expect, it } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import { SoloPresetNotice } from '../src/components/solo/SoloPresetNotice'

afterEach(cleanup)

it('warns for an ordinary settings edit in a known non-Custom mode without mutating it', () => {
  const changes = Object.freeze({ GatheringAmount: '2' })
  render(<SoloPresetNotice preset="Survival" changes={changes} />)
  expect(screen.getByRole('alert')).toHaveTextContent('Select Custom in the game')
  expect(screen.getByRole('alert')).toHaveTextContent('DST does not change your preset')
  expect(changes).toEqual({ GatheringAmount: '2' })
  expect(screen.queryByRole('button')).not.toBeInTheDocument()
})

it('stays quiet for Custom, an unknown preset, no edits and independent override edits', () => {
  const view = render(<SoloPresetNotice preset=" Custom " changes={{ GatheringAmount: '2' }} />)
  expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  view.rerender(<SoloPresetNotice preset={undefined} changes={{ GatheringAmount: '2' }} />)
  expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  view.rerender(<SoloPresetNotice preset="Survival" changes={{}} />)
  expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  view.rerender(<SoloPresetNotice preset="Survival" changes={{ m_DayLengthMinutes: '60', MaxLandclaimSegments: '20', PlayerInventoryStartingSize: '100' }} />)
  expect(screen.queryByRole('alert')).not.toBeInTheDocument()
})

it('warns for a mixed edit and disappears when the preset-controlled edit is reverted', () => {
  const view = render(<SoloPresetNotice preset="Exploration" changes={{ GatheringAmount: '2', m_DayLengthMinutes: '60' }} />)
  expect(screen.getByRole('alert')).toBeVisible()
  view.rerender(<SoloPresetNotice preset="Exploration" changes={{ m_DayLengthMinutes: '60' }} />)
  expect(screen.queryByRole('alert')).not.toBeInTheDocument()
})
