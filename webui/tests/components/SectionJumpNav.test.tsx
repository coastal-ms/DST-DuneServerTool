import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React, { useRef } from 'react'
import { BrowserRouter } from '../../src/router'
import { CollapsibleCard } from '../../src/components/CollapsibleCard'
import { SectionJumpNav } from '../../src/components/SectionJumpNav'
import { COMMAND_DECK_KEY, setCommandDeck } from '../../src/hooks/useCommandDeck'

const scrollIntoView = vi.fn()
const nestedClick = vi.fn()

function Fixture({ hideBeta = false }: { hideBeta?: boolean } = {}) {
  const ref = useRef<HTMLElement | null>(null)
  return (
    <BrowserRouter>
      <main ref={ref}>
        <SectionJumpNav containerRef={ref} />
        <CollapsibleCard id="test.alpha" title="Alpha">
          <p>Alpha body</p>
          <button type="button" aria-expanded="false" onClick={nestedClick}>Nested disclosure</button>
        </CollapsibleCard>
        <div hidden={hideBeta}><CollapsibleCard id="test.beta" title="Beta" defaultOpen={false}><p>Beta body</p></CollapsibleCard></div>
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

    await user.click(screen.getByRole('button', { name: /Alpha/ }))
    expect(screen.getByText('Alpha body')).toBeInTheDocument()
    expect(screen.getByText('Beta body')).toBeInTheDocument()
    expect(select).toHaveValue('test.beta')

    await user.selectOptions(select, 'test.alpha')
    expect(screen.queryByText('Beta body')).not.toBeInTheDocument()
    expect(nestedClick).not.toHaveBeenCalled()

    await user.click(screen.getByRole('button', { name: 'Collapse all sections' }))
    expect(screen.queryByText('Alpha body')).not.toBeInTheDocument()
  })
  it('removes hidden tab sections and collects them again when their tab becomes visible', async () => {
    const view = render(<Fixture />)
    const select = await screen.findByRole('combobox', { name: 'Jump to section' })
    expect(within(select).getByRole('option', { name: 'Beta' })).toBeInTheDocument()
    view.rerender(<Fixture hideBeta />)
    await waitFor(() => expect(screen.queryByRole('combobox', { name: 'Jump to section' })).not.toBeInTheDocument())
    view.rerender(<Fixture />)
    const restored = await screen.findByRole('combobox', { name: 'Jump to section' })
    expect(within(restored).getByRole('option', { name: 'Beta' })).toBeInTheDocument()
  })
  it('exposes focused section buttons in the new workspace without dispatching nested actions', async () => {
    localStorage.setItem(COMMAND_DECK_KEY, '1')
    const user = userEvent.setup()
    render(<Fixture />)
    const navigation = await screen.findByRole('navigation', { name: 'Workspace sections' })
    const beta = navigation.querySelector<HTMLButtonElement>('button:nth-child(2)')!
    await user.click(beta)
    expect(await screen.findByText('Beta body')).toBeInTheDocument()
    expect(screen.queryByText('Alpha body')).not.toBeInTheDocument()
    expect(nestedClick).not.toHaveBeenCalled()
    expect(beta).toHaveAttribute('aria-pressed', 'true')
  })
  it('recovers all section headers and removes focus markers on mode exit and unmount', async () => {
    localStorage.setItem(COMMAND_DECK_KEY, '1')
    const user = userEvent.setup()
    const view = render(<Fixture />)
    const navigation = await screen.findByRole('navigation', { name: 'Workspace sections' })
    const alpha = document.querySelector('[data-section-nav-id="test.alpha"]')!
    await user.click(within(navigation).getByRole('button', { name: 'Beta', exact: true }))
    expect(alpha).toHaveAttribute('data-portal-section-inactive')
    await user.click(screen.getByRole('button', { name: 'All sections' }))
    expect(alpha).not.toHaveAttribute('data-portal-section-inactive')
    await user.click(within(navigation).getByRole('button', { name: 'Beta', exact: true }))
    act(() => setCommandDeck(false))
    expect(alpha).not.toHaveAttribute('data-portal-section-inactive')
    act(() => setCommandDeck(true))
    await user.click(within(screen.getByRole('navigation', { name: 'Workspace sections' })).getByRole('button', { name: 'Beta', exact: true }))
    view.unmount()
    expect(alpha).not.toHaveAttribute('data-portal-section-inactive')
  })
  it('keeps nested ancestors visible and never mistakes a child toggle for its parent toggle', async () => {
    localStorage.setItem(COMMAND_DECK_KEY, '1')
    function NestedFixture() {
      const ref = useRef<HTMLElement | null>(null)
      return <BrowserRouter><main ref={ref}>
        <SectionJumpNav containerRef={ref} />
        <section data-section-nav-id="parent" data-section-nav-label="Parent">
          <CollapsibleCard id="child" title="Child" defaultOpen={false}><p>Child content</p></CollapsibleCard>
        </section>
        <section data-section-nav-id="sibling" data-section-nav-label="Sibling">Sibling content</section>
      </main></BrowserRouter>
    }
    const user = userEvent.setup()
    render(<NestedFixture />)
    const navigation = await screen.findByRole('navigation', { name: 'Workspace sections' })
    await user.click(within(navigation).getByRole('button', { name: 'Parent', exact: true }))
    expect(screen.queryByText('Child content')).not.toBeInTheDocument()
    await user.click(within(navigation).getByRole('button', { name: 'Child', exact: true }))
    expect(screen.getByText('Child content')).toBeInTheDocument()
    expect(document.querySelector('[data-section-nav-id="parent"]')).not.toHaveAttribute('data-portal-section-inactive')
    expect(document.querySelector('[data-section-nav-id="child"]')).not.toHaveAttribute('data-portal-section-inactive')
    expect(document.querySelector('[data-section-nav-id="sibling"]')).toHaveAttribute('data-portal-section-inactive')
  })
})
