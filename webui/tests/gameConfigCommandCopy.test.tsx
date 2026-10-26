import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { FieldRow } from '../src/pages/GameConfig'
import type { GameConfigField } from '../src/api/types'

const key = 'demo.MaximumRecDestructionInfoReplicationPercentage'
const field: GameConfigField = { key, label: key, section: 'ConsoleVariables', file: 'engine', type: 'float', consoleVar: true }
const props = { field, value: '0.75', onChange: vi.fn(), disabled: false, isDirty: true, isSet: true, isCustom: true, defaultValue: '0.25', managed: true, fixedHeight: true }
afterEach(() => { cleanup(); vi.unstubAllGlobals() })

describe('manual INI copying', () => {
  it('copies the full command and current INI value, including the section', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    vi.stubGlobal('navigator', { clipboard: { writeText } })
    render(<FieldRow {...props} />)
    fireEvent.click(screen.getByRole('button', { name: `Copy command name ${key}` }))
    await waitFor(() => expect(writeText).toHaveBeenLastCalledWith(key))
    fireEvent.click(screen.getByRole('button', { name: `Copy INI entry ${key}` }))
    await waitFor(() => expect(writeText).toHaveBeenLastCalledWith(`[ConsoleVariables]\n${key}=0.75`))
    expect(await screen.findByRole('status')).toHaveTextContent('INI entry copied')
  })

  it('does not invent an entry for an unset value or flatten a struct member', () => {
    const { rerender } = render(<FieldRow {...props} value="" />)
    expect(screen.queryByRole('button', { name: `Copy INI entry ${key}` })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: `Copy command name ${key}` })).toBeEnabled()
    rerender(<FieldRow {...props} field={{ ...field, structKey: 'DedicatedServerData' }} />)
    expect(screen.queryByRole('button', { name: `Copy INI entry ${key}` })).not.toBeInTheDocument()
  })

  it('reports a clipboard failure without claiming success', async () => {
    vi.stubGlobal('navigator', { clipboard: { writeText: vi.fn().mockRejectedValue(new Error('denied')) } })
    render(<FieldRow {...props} />)
    fireEvent.click(screen.getByRole('button', { name: `Copy command name ${key}` }))
    expect(await screen.findByRole('status')).toHaveTextContent('Copy unavailable')
  })
})
