import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { Pods } from '../src/pages/Pods'
import { getPods, getPodEvents } from '../src/api/pods'
import type { PodSummary } from '../src/api/pods'
vi.mock('../src/hooks/useStatus', () => ({ useStatus: () => ({ status: { vm: { running: true } } }) }))
vi.mock('../src/api/pods', () => ({ getPods: vi.fn(), getPodEvents: vi.fn(), pruneTerminalDirectorPods: vi.fn() }))
const name = 'sh-long-common-prefix-sg-survival-1-pod-1'
const sample = (values: Partial<PodSummary>): PodSummary => ({ name, namespace: 'test-namespace', ready: '1/1', status: 'Running', phase: 'Running', restarts: 106, node: 'test-node', ip: '', startTime: '', ...values })
beforeEach(() => {
  vi.mocked(getPods).mockResolvedValue({ ok: true, count: 3, pods: [sample({}), sample({ name: 'test-db-dbdepl-sts-0' }), sample({ name: 'test-dump-20261030-120000-pod', phase: 'Failed', status: 'Error', ready: '0/1' })] })
  vi.mocked(getPodEvents).mockResolvedValue({ ok: true, namespace: 'test', name, events: [], describe: '' })
  Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: vi.fn().mockResolvedValue(undefined) } })
})
afterEach(() => { cleanup(); vi.clearAllMocks() })
it('leads with readable maps and services and excludes failed backup history from readiness', async () => {
  render(<Pods />)
  expect(await screen.findByRole('button', { name: /Hagga Basin/ })).toBeVisible()
  expect(screen.getByRole('button', { name: /Database.*World/ })).toBeVisible()
  expect(screen.getByText('All reported live services are ready.')).toBeVisible()
  expect(screen.queryByText(/Backup ·/)).not.toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'History (1)' }))
  expect(screen.getByText('Failed attempt')).toBeVisible()
  expect(screen.queryByRole('button', { name: /Hagga Basin/ })).not.toBeInTheDocument()
})
it('finds Hagga by its readable name and copies full support details', async () => {
  render(<Pods />)
  await screen.findByRole('button', { name: /Hagga Basin/ })
  fireEvent.change(screen.getByRole('textbox', { name: 'Search services' }), { target: { value: 'hagga' } })
  fireEvent.click(screen.getByRole('button', { name: /Hagga Basin/ }))
  const details = screen.getByRole('region', { name: 'Service details' })
  expect(within(details).getByText(name)).toBeVisible()
  fireEvent.click(within(details).getByRole('button', { name: 'Copy support details' }))
  await waitFor(() => expect(navigator.clipboard.writeText).toHaveBeenCalledWith(expect.stringContaining(`Pod: ${name}`)))
  expect(vi.mocked(navigator.clipboard.writeText).mock.calls[0]?.[0]).toContain('Ready containers: 1/1')
})
it('keeps identity and readiness available when event retrieval fails', async () => {
  vi.mocked(getPodEvents).mockRejectedValue(new Error('Events unavailable'))
  render(<Pods />)
  fireEvent.click(await screen.findByRole('button', { name: /Hagga Basin/ }))
  expect(await screen.findByRole('alert')).toHaveTextContent('Events unavailable')
  expect(screen.getByText(name)).toBeVisible()
  expect(screen.getByRole('button', { name: 'Copy pod name' })).toBeEnabled()
})
it('filters unready services without treating old restart counts as failures', async () => {
  vi.mocked(getPods).mockResolvedValue({ ok: true, count: 2, pods: [sample({ ready: '0/1' }), sample({ name: 'test-db-dbdepl-sts-0' })] })
  render(<Pods />)
  await screen.findByRole('button', { name: /Hagga Basin/ })
  fireEvent.click(screen.getByRole('checkbox', { name: 'Needs attention' }))
  expect(screen.getByText('Not ready')).toBeVisible()
  expect(screen.queryByRole('button', { name: /Database.*World/ })).not.toBeInTheDocument()
})

it.each([
  { phase: 'Succeeded', status: 'Completed', state: 'Completed' },
  { phase: 'Failed', status: 'Error', state: 'Failed attempt' },
])('keeps $phase director jobs in History rather than live service readiness', async ({ phase, status, state }) => {
  vi.mocked(getPods).mockResolvedValue({ ok: true, count: 2, pods: [
    sample({}), sample({ name: 'test-bgd-old-pod', phase, status, ready: '0/1' }),
  ] })
  render(<Pods />)
  await screen.findByRole('button', { name: /Hagga Basin/ })
  expect(screen.queryByRole('button', { name: /Battlegroup director/ })).not.toBeInTheDocument()
  expect(screen.getByText('All reported live services are ready.')).toBeVisible()
  fireEvent.click(screen.getByRole('button', { name: 'History (1)' }))
  expect(screen.getByRole('button', { name: /Battlegroup director/ })).toBeVisible()
  expect(screen.getByText(state)).toBeVisible()
  expect(screen.queryByRole('button', { name: /Hagga Basin/ })).not.toBeInTheDocument()
})
