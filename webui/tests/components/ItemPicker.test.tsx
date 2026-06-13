// End-to-end regression for the "can't select item from the list" bug.
//
// Root cause: /api/catalog/items returns `items` as an ARRAY of
// { templateId, name, category }, but the parser treated it as a dict, so every
// catalog entry got a numeric array-index as its template_id. Picking an item
// then committed a numeric id, which the give-item guard rejects -> the pick
// silently fails and the "pick an item from the list" warning stays on.
//
// This test drives the REAL getItemCatalog parser (via a stubbed fetch) through
// the ItemPicker, so it fails if the array shape is ever mishandled again.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React, { useState } from 'react'
import { ItemPicker } from '../../src/components/ItemPicker'

// Backend (Get-DuneItemCatalog) array shape.
const CATALOG_RESPONSE = {
  meta: { total: 2, source: 'item-catalog.json' },
  items: [
    { templateId: 'AzuriteOre', name: 'Copper Ore', category: 'Resources' },
    { templateId: 'CopperBar', name: 'Copper Ingot', category: 'Resources' },
  ],
}

beforeEach(() => {
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
    const url = typeof input === 'string' ? input : input.toString()
    if (url.includes('/api/catalog/items')) {
      return new Response(JSON.stringify(CATALOG_RESPONSE), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      })
    }
    return new Response(JSON.stringify({ ok: true }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    })
  }))
})

afterEach(() => {
  vi.unstubAllGlobals()
  cleanup()
})

// Controlled host mirroring the Give-Item form wiring in players/sections.tsx.
function Host({ onPick }: { onPick: (tpl: string, name: string) => void }) {
  const [tpl, setTpl] = useState('')
  const [name, setName] = useState('')
  return (
    <ItemPicker
      label="Item"
      value={tpl}
      displayValue={name || tpl}
      onChange={(t, item) => {
        setTpl(t)
        setName(item ? item.name : '')
        onPick(t, item ? item.name : '')
      }}
    />
  )
}

describe('ItemPicker selection (real catalog parser)', () => {
  it('commits the class-string template_id when a suggestion is clicked', async () => {
    const user = userEvent.setup()
    const onPick = vi.fn()
    render(<Host onPick={onPick} />)

    const input = screen.getByRole('textbox')
    await user.click(input)
    await user.type(input, 'Copper Ore')

    const option = await screen.findByText('Copper Ore', { selector: 'span' })
    await user.click(option)

    await waitFor(() => {
      expect(onPick).toHaveBeenLastCalledWith('AzuriteOre', 'Copper Ore')
    })
    expect(input).toHaveValue('Copper Ore')
    expect(screen.queryByText(/pick an item from the list/i)).toBeNull()
  })
})
