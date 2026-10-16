import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { api } from '../src/api/client'
import { CodexOwnership } from '../src/components/CodexOwnership'

vi.mock('../src/api/client', () => ({ api: vi.fn() }))
afterEach(() => { cleanup(); vi.resetAllMocks(); vi.restoreAllMocks() })
const data = { ok: true, owned: 1, missing: 1, total: 2, profileToken: 'one', fragments: [
  { id: 'imperium', category: 'The Known Universe', entryId: 'i', entry: 'The Imperium', fragment: 'Lesson from the Count', owned: true, revealed: true },
  { id: 'water', category: 'The War for Arrakis', entryId: 'w', entry: 'The Water Shippers', fragment: 'Harkonnen Dossier: The Water Shippers', owned: false, revealed: true },
] }

describe('Codex ownership', () => {
  it('shows fragment counts and filters missing lore without offering writes', async () => {
    vi.mocked(api).mockResolvedValue(data)
    render(<CodexOwnership path="/api/solo/codex" profileToken="one" />)
    expect(await screen.findByText('1/2 fragments owned · 1 missing')).toBeInTheDocument()
    expect(screen.getByText('Owned', { selector: 'span' })).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText('Codex ownership'), { target: { value: 'missing' } })
    expect(screen.queryByText('Lesson from the Count')).not.toBeInTheDocument()
    expect(screen.getByText('Harkonnen Dossier: The Water Shippers')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /grant|delete|reset/i })).not.toBeInTheDocument()
  })

  it('searches entry names and fragment titles', async () => {
    vi.mocked(api).mockResolvedValue(data)
    render(<CodexOwnership path="/api/gameplay/players/codex?account_id=1" />)
    await screen.findByText('Lesson from the Count')
    fireEvent.change(screen.getByLabelText('Search codex'), { target: { value: 'WATER SHIPPERS' } })
    expect(screen.queryByText('Lesson from the Count')).not.toBeInTheDocument()
    expect(screen.getByText('Harkonnen Dossier: The Water Shippers')).toBeInTheDocument()
  })

  it('does not show results from a different Solo profile', async () => {
    vi.mocked(api).mockResolvedValue(data)
    render(<CodexOwnership path="/api/solo/codex" profileToken="two" />)
    await screen.findByRole('button', { name: 'Refresh' })
    expect(screen.queryByText('Lesson from the Count')).not.toBeInTheDocument()
    expect(screen.queryByText(/fragments owned/)).not.toBeInTheDocument()
  })

  it('reports a failed read without displaying everything as missing', async () => {
    vi.mocked(api).mockRejectedValue(new Error('Codex records are unavailable'))
    render(<CodexOwnership path="/api/solo/codex" />)
    expect(await screen.findByRole('alert')).toHaveTextContent('Codex records are unavailable')
    expect(screen.queryByText(/fragments owned/)).not.toBeInTheDocument()
  })

  it('reads the self-hosted source envelope without requiring a Solo ok field', async () => {
    vi.mocked(api).mockResolvedValue({ ...data, ok: undefined, source: 'live' })
    render(<CodexOwnership path="/api/gameplay/players/codex?account_id=1" />)
    expect(await screen.findByText('1/2 fragments owned · 1 missing')).toBeInTheDocument()
  })

  it('does not turn an unavailable live database into empty demo ownership', async () => {
    vi.mocked(api).mockResolvedValue({ source: 'demo', liveError: 'Database unavailable', fragments: [], owned: 0, missing: 0, total: 0 })
    render(<CodexOwnership path="/api/gameplay/players/codex?account_id=1" />)
    expect(await screen.findByRole('alert')).toHaveTextContent('Database unavailable')
    expect(screen.queryByText(/fragments owned/)).not.toBeInTheDocument()
  })

  it('grants only selected missing fragments with profile binding and a backup confirmation', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(true)
    vi.mocked(api).mockImplementation(async (_path, options) => options?.method === 'POST' ? { ok: true } : data)
    render(<CodexOwnership path="/api/solo/codex" profileToken="one"
      grant={{ path: '/api/solo/codex/grant', body: { expectedProfileToken: 'one' }, disabled: false, reason: '' }} />)
    fireEvent.click(await screen.findByRole('checkbox', { name: 'Select Harkonnen Dossier: The Water Shippers' }))
    expect(screen.getAllByRole('checkbox')).toHaveLength(1)
    fireEvent.click(screen.getByRole('button', { name: 'Grant selected (1)' }))
    expect(await screen.findByRole('status')).toHaveTextContent('Backup retained')
    expect(confirm).toHaveBeenCalledWith(expect.stringContaining('automatic backup'))
    expect(api).toHaveBeenCalledWith('/api/solo/codex/grant', { method: 'POST', body: JSON.stringify({ expectedProfileToken: 'one', ids: ['water'], confirm: 'GRANT CODEX FRAGMENTS' }) })
  })

  it('does not write after a cancelled confirmation', async () => {
    vi.spyOn(window, 'confirm').mockReturnValue(false)
    vi.mocked(api).mockResolvedValue(data)
    render(<CodexOwnership path="/api/solo/codex" grant={{ path: '/api/solo/codex/grant', body: {}, disabled: false, reason: '' }} />)
    fireEvent.click(await screen.findByRole('checkbox'))
    fireEvent.click(screen.getByRole('button', { name: 'Grant selected (1)' }))
    expect(vi.mocked(api).mock.calls.filter(([, options]) => options?.method === 'POST')).toHaveLength(0)
  })

  it('keeps grants disabled while the game or character is online', async () => {
    vi.mocked(api).mockResolvedValue(data)
    render(<CodexOwnership path="/api/solo/codex" grant={{ path: '/api/solo/codex/grant', body: {}, disabled: true, reason: 'Close Dune first.' }} />)
    expect(await screen.findByRole('checkbox')).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Grant selected (0)' })).toBeDisabled()
    expect(screen.getByText('Close Dune first.')).toBeInTheDocument()
  })

  it('allows an owned but hidden fragment to be selected for reveal repair', async () => {
    vi.mocked(api).mockResolvedValue({ ...data, fragments: [{ ...data.fragments[0], revealed: false }] })
    render(<CodexOwnership path="/api/solo/codex" grant={{ path: '/api/solo/codex/grant', body: {}, disabled: false, reason: '' }} />)
    await screen.findByText('Hidden', { selector: 'span' })
    fireEvent.click(screen.getByRole('checkbox'))
    expect(screen.getByRole('button', { name: 'Grant selected (1)' })).toBeEnabled()
  })
})
