import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { UsageCountCard } from '../src/pages/settings/UsageCountCard'
import { api } from '../src/api/client'
vi.mock('../src/api/client', () => ({ api: vi.fn() }))
afterEach(() => { cleanup(); vi.resetAllMocks() })
describe('Anonymous usage setting', () => {
  it('shows the enabled default and saves an explicit opt-out immediately', async () => {
    vi.mocked(api).mockResolvedValueOnce({ values: {} }).mockResolvedValueOnce({ ok: true })
    render(<UsageCountCard />)
    const toggle = await screen.findByRole('checkbox')
    await waitFor(() => expect(toggle).toBeEnabled())
    expect(toggle).toBeChecked()
    fireEvent.click(toggle)
    await waitFor(() => expect(toggle).not.toBeChecked())
    expect(api).toHaveBeenLastCalledWith('/api/config', { method: 'PUT', body: JSON.stringify({ values: { AnonymousUsageEnabled: 'false' } }) })
  })
  it('preserves a saved opt-out when reopening Settings', async () => {
    vi.mocked(api).mockResolvedValue({ values: { AnonymousUsageEnabled: 'false' } })
    render(<UsageCountCard />)
    await waitFor(() => expect(screen.getByRole('checkbox')).toBeEnabled())
    expect(screen.getByRole('checkbox')).not.toBeChecked()
    expect(api).toHaveBeenCalledTimes(1)
  })
  it('does not change the displayed saved preference if saving fails', async () => {
    vi.mocked(api).mockResolvedValueOnce({ values: { AnonymousUsageEnabled: 'false' } }).mockRejectedValueOnce(new Error('offline'))
    render(<UsageCountCard />)
    await waitFor(() => expect(screen.getByRole('checkbox')).toBeEnabled())
    fireEvent.click(screen.getByRole('checkbox'))
    expect(await screen.findByRole('alert')).toHaveTextContent('Could not save')
    expect(screen.getByRole('checkbox')).not.toBeChecked()
  })
  it('does not offer an unknown default after a failed load', async () => {
    vi.mocked(api).mockRejectedValue(new Error('offline'))
    render(<UsageCountCard />)
    expect(await screen.findByRole('alert')).toHaveTextContent('Could not load')
    expect(screen.getByRole('checkbox')).toBeDisabled()
  })
})
