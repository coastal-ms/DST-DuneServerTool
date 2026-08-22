import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React, { useRef } from 'react'
import { BrowserRouter } from '../../src/router'
import { CollapsibleCard } from '../../src/components/CollapsibleCard'
import { SectionJumpNav } from '../../src/components/SectionJumpNav'

const scrollIntoView = vi.fn()
const nestedClick = vi.fn()

function Fixture() {
  const ref = useRef<HTMLElement | null>(null)
  return (
    <BrowserRouter>
      <main ref={ref}>
        <SectionJumpNav containerRef={ref} />
        <CollapsibleCard id="test.alpha" title="Alpha">
          <p>Alpha body</p>
          <button type="button" aria-expanded="false" onClick={nestedClick}>Nested disclosure</button>
        </CollapsibleCard>
        <CollapsibleCard id="test.beta" title="Beta" defaultOpen={false}><p>Beta body</p></CollapsibleCard>
      </main>
    </BrowserRouter>
  )
}

describe('SectionJumpNav', () => {
  beforeEach(() => {
    localStorage.clear()
    scrollIntoView.mockClear()
    nestedClick.mockClear()
    Object.defineProperty(HTMLElement.prototype, 'scrollIntoView', {
      configurable: true,
      value: scrollIntoView,
    })
    vi.stubGlobal('matchMedia', vi.fn(() => ({ matches: true })))
  })
  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it('defaults to the first card and opens a collapsed selected card', async () => {
    const user = userEvent.setup()
    render(<Fixture />)
    const select = await screen.findByRole('combobox', { name: 'Jump to section' })
    expect(select).toHaveValue('test.alpha')
    expect(screen.queryByText('Beta body')).not.toBeInTheDocument()

    await user.selectOptions(select, 'test.beta')
    expect(await screen.findByText('Beta body')).toBeInTheDocument()
    expect(screen.queryByText('Alpha body')).not.toBeInTheDocument()
    expect(select).toHaveValue('test.beta')
    await waitFor(() => expect(scrollIntoView).toHaveBeenCalled())
    expect(screen.getByRole('button', { name: /Beta/ })).toHaveFocus()

    await user.selectOptions(select, 'test.alpha')
    expect(nestedClick).not.toHaveBeenCalled()

    await user.click(screen.getByRole('button', { name: 'Collapse all sections' }))
    expect(screen.queryByText('Alpha body')).not.toBeInTheDocument()
  })
})
