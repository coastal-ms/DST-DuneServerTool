import { render, screen, waitFor, cleanup } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, expect, it, vi } from 'vitest'
import { IniBackupsCard } from '../src/pages/settings/IniBackupsCard'
import { api } from '../src/api/client'
vi.mock('../src/api/client', () => ({ api: vi.fn() }))
vi.mock('../src/util/viewer', () => ({ isLocalViewer: () => true }))
afterEach(() => { cleanup(); vi.clearAllMocks() })
it('shows the install backup directory without opening it until requested', async () => {
  vi.mocked(api).mockResolvedValue({ path: 'C:/DST/DST/INI Backups' })
  render(<IniBackupsCard />)
  expect(await screen.findByText('C:/DST/DST/INI Backups')).toBeInTheDocument()
  expect(api).toHaveBeenCalledExactlyOnceWith('/api/gameconfig/backup-folder')
  await userEvent.click(screen.getByRole('button', { name: 'Open folder' }))
  await waitFor(() => expect(api).toHaveBeenCalledWith('/api/gameconfig/backup-folder/open', { method: 'POST' }))
})

it('replaces the loading message when the backup location request fails', async () => {
  vi.mocked(api).mockRejectedValue(new Error('Unavailable'))
  render(<IniBackupsCard />)
  expect(await screen.findByRole('alert')).toHaveTextContent('Unavailable')
  expect(screen.queryByText('Reading backup location…')).not.toBeInTheDocument()
  expect(screen.getByRole('button', { name: 'Open folder' })).toBeDisabled()
})
