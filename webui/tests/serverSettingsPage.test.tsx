import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import { ServerSettings } from '../src/pages/ServerSettings'

const statusMock = vi.hoisted(() => vi.fn())

vi.mock('../src/hooks/useStatus', () => ({
  useStatus: statusMock,
}))

vi.mock('../src/pages/gameconfig/OfficialRetailServerSettingsCard', () => ({
  OfficialRetailServerSettingsCard: ({ vmRunning }: { vmRunning: boolean }) => (
    <div data-testid="retail-settings-card">{vmRunning ? 'VM running' : 'VM stopped'}</div>
  ),
}))

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('Server Settings page', () => {
  it('hosts the Official Retail settings card with live VM state', () => {
    statusMock.mockReturnValue({ status: { vm: { running: true } } })

    render(<ServerSettings />)

    expect(screen.getByRole('heading', { name: 'Server Settings' })).toBeInTheDocument()
    expect(screen.getByText(/ServerCustomSettings\.ini/)).toBeInTheDocument()
    expect(screen.getByTestId('retail-settings-card')).toHaveTextContent('VM running')
  })
})
