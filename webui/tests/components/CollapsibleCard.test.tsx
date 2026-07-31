// Regression cover for the shared collapsible section card.
//
// The contract that matters for users: cards start OPEN (the roll-up is purely
// aesthetic, never a way to hide settings from someone who didn't ask), the
// choice sticks per card, and a card explicitly marked defaultOpen={false}
// stays closed until they open it.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render, screen, cleanup } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'
import { CollapsibleCard } from '../../src/components/CollapsibleCard'

describe('CollapsibleCard', () => {
  beforeEach(() => localStorage.clear())
  afterEach(cleanup)

  it('renders open by default and shows its body', () => {
    render(
      <CollapsibleCard id="test.alpha" title="Alpha">
        <p>body content</p>
      </CollapsibleCard>,
    )
    expect(screen.getByText('body content')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /alpha/i })).toHaveAttribute('aria-expanded', 'true')
  })

  it('rolls up on click and persists the choice', async () => {
    const user = userEvent.setup()
    render(
      <CollapsibleCard id="test.beta" title="Beta">
        <p>beta body</p>
      </CollapsibleCard>,
    )

    await user.click(screen.getByRole('button', { name: /beta/i }))
    expect(screen.queryByText('beta body')).not.toBeInTheDocument()
    expect(localStorage.getItem('dst.card.test.beta')).toBe('0')

    // Remount: the collapsed choice survives.
    cleanup()
    render(
      <CollapsibleCard id="test.beta" title="Beta">
        <p>beta body</p>
      </CollapsibleCard>,
    )
    expect(screen.queryByText('beta body')).not.toBeInTheDocument()
  })

  it('honours defaultOpen={false} until the user opens it', async () => {
    const user = userEvent.setup()
    render(
      <CollapsibleCard id="test.gamma" title="Gamma" defaultOpen={false}>
        <p>gamma body</p>
      </CollapsibleCard>,
    )
    expect(screen.queryByText('gamma body')).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: /gamma/i }))
    expect(screen.getByText('gamma body')).toBeInTheDocument()
    expect(localStorage.getItem('dst.card.test.gamma')).toBe('1')
  })

  it('keeps headerRight actions clickable while collapsed', async () => {
    const user = userEvent.setup()
    let clicks = 0
    render(
      <CollapsibleCard
        id="test.delta"
        title="Delta"
        headerRight={<button type="button" onClick={() => { clicks += 1 }}>Refresh</button>}
      >
        <p>delta body</p>
      </CollapsibleCard>,
    )

    await user.click(screen.getByRole('button', { name: /delta/i }))
    expect(screen.queryByText('delta body')).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Refresh' }))
    expect(clicks).toBe(1)
    // Clicking the action must not have re-opened the card.
    expect(screen.queryByText('delta body')).not.toBeInTheDocument()
  })
})
