import { act, cleanup, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { SoloGrantDelivery } from '../src/components/solo/SoloGrantDelivery'
import { getSoloNativeGrants, type SoloNativeGrantResult } from '../src/api/solo'
vi.mock('../src/api/solo', () => ({getSoloNativeGrants: vi.fn()}))
const job: SoloNativeGrantResult = {ok: true, mode: 'native', requestId: 'a'.repeat(32), status: 'queued', completed: 0, total: 1, message: 'Queued for next launch.'}
beforeEach(() => {vi.useFakeTimers()})
afterEach(() => {cleanup(); vi.useRealTimers(); vi.resetAllMocks()})

it('reads once without idle polling when there are no queued requests', async () => {
  vi.mocked(getSoloNativeGrants).mockResolvedValue({ok: true, requests: []})
  await act(async () => {render(<SoloGrantDelivery profileToken="profile" gameRunning revision={0} />)})
  await act(async () => {vi.advanceTimersByTime(10000)})
  expect(getSoloNativeGrants).toHaveBeenCalledTimes(1)
})

it('shows queued distinctly and stops polling after delivery', async () => {
  vi.mocked(getSoloNativeGrants).mockResolvedValueOnce({ok: true, requests: [job]})
    .mockResolvedValue({ok: true, requests: [{...job, status: 'delivered', completed: 1, message: 'Backpack verified.'}]})
  await act(async () => {render(<SoloGrantDelivery profileToken="profile" gameRunning revision={0} />)})
  expect(screen.getByText('Queued')).toBeInTheDocument()
  expect(screen.queryByText('Delivered')).not.toBeInTheDocument()
  await act(async () => {vi.advanceTimersByTime(1500)})
  expect(screen.getByText('Delivered')).toBeInTheDocument()
  await act(async () => {vi.advanceTimersByTime(10000)})
  expect(getSoloNativeGrants).toHaveBeenCalledTimes(2)
})

it('does not poll a closed game and refreshes when it starts', async () => {
  vi.mocked(getSoloNativeGrants).mockResolvedValue({ok: true, requests: [job]})
  let view: ReturnType<typeof render>
  await act(async () => {view = render(<SoloGrantDelivery profileToken="profile" gameRunning={false} revision={0} />)})
  await act(async () => {vi.advanceTimersByTime(10000)})
  expect(getSoloNativeGrants).toHaveBeenCalledTimes(1)
  await act(async () => {view.rerender(<SoloGrantDelivery profileToken="profile" gameRunning revision={0} />)})
  expect(getSoloNativeGrants).toHaveBeenCalledTimes(2)
})

it('shows interrupted delivery without claiming success or retrying it', async () => {
  vi.mocked(getSoloNativeGrants).mockResolvedValue({ok: true, requests: [{...job, status: 'uncertain', message: 'Check your backpack before retrying.'}]})
  await act(async () => {render(<SoloGrantDelivery profileToken="profile" gameRunning revision={0} />)})
  expect(screen.getByText('Check backpack')).toBeInTheDocument()
  expect(screen.queryByText('Delivered')).not.toBeInTheDocument()
  await act(async () => {vi.advanceTimersByTime(10000)})
  expect(getSoloNativeGrants).toHaveBeenCalledTimes(1)
})
