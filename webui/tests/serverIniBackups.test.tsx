import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { ServerIniBackups } from '../src/pages/gameconfig/ServerIniBackups'

const request = vi.hoisted(() => vi.fn())
vi.mock('../src/api/client', () => ({ api: request }))
const file = { path: '/srv/UserSettings/UserGame.ini.dstbak-1', name: 'UserGame.ini.dstbak-1', folder: 'UserSettings', size: 10, modified: 1, sha256: 'a'.repeat(64) }
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.resetAllMocks() })

it('downloads before enabling deletion and sends only the selected backups', async () => {
  request.mockResolvedValueOnce({ backups: [file] }).mockResolvedValueOnce({ filename: 'Server-INI-Backups.zip', base64: btoa('zip') }).mockResolvedValueOnce({ deleted: 1, results: [{ path: file.path, ok: true }] })
  URL.createObjectURL = vi.fn(() => 'blob:zip'); URL.revokeObjectURL = vi.fn()
  const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
  vi.spyOn(window, 'confirm').mockReturnValue(true)
  render(<ServerIniBackups vmRunning />)
  fireEvent.click(screen.getByText('Server INI Backup File Download and Delete'))
  fireEvent.click(await screen.findByRole('checkbox'))
  expect(screen.getByText('Delete downloaded backups')).toBeDisabled()
  fireEvent.click(screen.getByText('Download selected ZIP'))
  await waitFor(() => expect(screen.getByText('Delete downloaded backups')).toBeEnabled())
  expect(click).toHaveBeenCalledOnce()
  fireEvent.click(screen.getByText('Delete downloaded backups'))
  await screen.findByText('Deleted 1 backup(s).')
  expect(request).toHaveBeenLastCalledWith('/api/gameconfig/ini-backups/delete', { method: 'POST', body: JSON.stringify({ files: [file] }) })
  expect(screen.queryByRole('checkbox')).not.toBeInTheDocument()
})

it('keeps deletion disabled after a failed download', async () => {
  request.mockResolvedValueOnce({ backups: [file] }).mockRejectedValueOnce(new Error('Backup changed'))
  render(<ServerIniBackups vmRunning />)
  fireEvent.click(screen.getByText('Server INI Backup File Download and Delete'))
  fireEvent.click(await screen.findByRole('checkbox'))
  fireEvent.click(screen.getByText('Download selected ZIP'))
  expect(await screen.findByRole('alert')).toHaveTextContent('Backup changed')
  expect(screen.getByText('Delete downloaded backups')).toBeDisabled()
  expect(request).toHaveBeenCalledTimes(2)
})

it('does not read the server until opened and disables the option when the VM is off', () => {
  render(<ServerIniBackups vmRunning={false} />)
  expect(screen.getByText('Server INI Backup File Download and Delete')).toBeDisabled()
  expect(request).not.toHaveBeenCalled()
})
