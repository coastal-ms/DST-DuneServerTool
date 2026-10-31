import { afterEach, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { SoloMode } from '../src/pages/SoloMode'
import { api } from '../src/api/client'

vi.mock('../src/hooks/useApi', () => ({ useApi: (path: string) => ({
  data: path === '/api/solo/runtime' ? { gameRunning: false, processes: [] } : null,
  loading: false, error: null, refresh: vi.fn(),
}) }))
vi.mock('../src/api/client', () => ({ api: vi.fn().mockRejectedValue(new Error('No live backend in this test')) }))
afterEach(() => { cleanup(); localStorage.clear() })

it.each([
  ['lost harvest', 'Journey', 'Progression', 'Unlocks & rewards'],
  ['backpack', 'Character Inventory', 'Items', 'Character Inventory'],
  ['repair', 'Give & repair', 'Items', 'Give & repair'],
  ['swatch', 'Appearance', 'Items', 'Appearance'],
  ['blueprint', 'Import Blueprint', 'Items', 'Blueprints'],
  ['diagnostics', 'Solo diagnostics', 'Advanced', ''],
  ['backup', 'Retained backups', 'Activity', ''],
])('finds %s without executing a character action', (query, label, home, view) => {
  render(<SoloMode />)
  fireEvent.click(screen.getByRole('button', { name: 'Character tools', exact: true }))
  const input = screen.getByRole('searchbox', { name: 'Find a character tool' })
  fireEvent.change(input, { target: { value: query } })
  const results = within(screen.getByRole('region', { name: 'Character tool search results' }))
  fireEvent.click(results.getByRole('button', { name: `${label} ${home}`, exact: true }))
  expect(within(screen.getByRole('navigation', { name: 'Solo character sections' }))
    .getByRole('button', { name: home, exact: true })).toHaveAttribute('aria-pressed', 'true')
  if (view) expect(within(screen.getByRole('navigation', { name: `Solo ${home} views` }))
    .getByRole('button', { name: view, exact: true })).toHaveAttribute('aria-pressed', 'true')
  expect(input).toHaveValue('')
  expect(vi.mocked(api).mock.calls.some(([, options]) => options?.method && options.method !== 'GET')).toBe(false)
})

it('keeps the current view for an empty or unmatched tool search', () => {
  render(<SoloMode />)
  fireEvent.click(screen.getByRole('button', { name: 'Character tools', exact: true }))
  fireEvent.change(screen.getByRole('searchbox', { name: 'Find a character tool' }), { target: { value: 'no-such-character-tool' } })
  expect(screen.getByRole('status')).toHaveTextContent('No matching character tools.')
  expect(screen.getByText('Character snapshot')).toBeInTheDocument()
})

it('organizes character tools into the shared sections and returns recovery to the existing Backups page', () => {
  render(<SoloMode />)
  fireEvent.click(screen.getByRole('button', { name: 'Character tools', exact: true }))
  const nav = within(screen.getByRole('navigation', { name: 'Solo character sections' }))
  expect(nav.getAllByRole('button').map(button => button.textContent)).toEqual(['Overview', 'Items', 'Progression', 'Activity', 'Advanced'])
  expect(screen.getByText('Character snapshot')).toBeInTheDocument()
  fireEvent.click(nav.getByRole('button', { name: 'Items', exact: true }))
  const itemViews = within(screen.getByRole('navigation', { name: 'Solo Items views' }))
  expect(itemViews.getAllByRole('button').map(button => button.textContent)).toEqual(['Character Inventory', 'Give & repair', 'Appearance', 'Blueprints', 'Vehicles'])
  expect(screen.queryByText('Character fillables')).not.toBeInTheDocument()
  fireEvent.click(itemViews.getByRole('button', { name: 'Give & repair', exact: true }))
  expect(screen.getByText('Character fillables')).toBeInTheDocument()
  expect(screen.getByText('Repair equipment')).toBeInTheDocument()
  fireEvent.click(itemViews.getByRole('button', { name: 'Vehicles', exact: true }))
  expect(screen.getByText('Give Vehicle Kit')).toBeInTheDocument()
  expect(screen.queryByText('Character fillables')).not.toBeInTheDocument()
  fireEvent.click(itemViews.getByRole('button', { name: 'Blueprints', exact: true }))
  expect(screen.getByRole('button', { name: 'Import blueprint', exact: true })).toBeInTheDocument()
  expect(screen.queryByText('Currencies')).not.toBeInTheDocument()
  fireEvent.click(nav.getByRole('button', { name: 'Progression', exact: true }))
  const progressionViews = within(screen.getByRole('navigation', { name: 'Solo Progression views' }))
  expect(progressionViews.getAllByRole('button').map(button => button.textContent)).toEqual(['Specializations', 'Unlocks & rewards'])
  fireEvent.click(progressionViews.getByRole('button', { name: 'Unlocks & rewards', exact: true }))
  for (const label of ['Complete Story','Complete Contracts','Complete Codex','Complete Tutorials','Faction Progression Unlocks']) expect(screen.getByText(label, {selector:'summary'})).toBeInTheDocument()
  fireEvent.click(screen.getByText('Complete Story', {selector:'summary'}))
  expect(screen.getByText('Complete Story', {selector:'summary'}).closest('details')).toHaveAttribute('open')
  expect(screen.getByRole('heading', {name:'Reset to Post-NPE (keep skills & points)'})).toBeInTheDocument()
  expect(screen.getByRole('button', {name:'Reset to Post-NPE (keep skills & points)'})).toBeDisabled()
  expect(screen.queryByRole('button', {name:/Back to unlocks/})).not.toBeInTheDocument()
  expect(screen.queryByText('Character tags')).not.toBeInTheDocument()
  fireEvent.click(nav.getByRole('button', { name: 'Advanced', exact: true }))
  expect(screen.getByText('Solo diagnostics')).toBeInTheDocument()
  fireEvent.click(nav.getByRole('button', { name: 'Activity', exact: true }))
  expect(screen.getByText('Recovery history')).toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Open Backups', exact: true }))
  expect(screen.queryByRole('navigation', { name: 'Solo character sections' })).not.toBeInTheDocument()
  expect(screen.getAllByRole('button', { name: 'Backups', exact: true })).toHaveLength(1)
})

it('expands Solo item tools inline while keeping sibling cards accessible', () => {
  render(<SoloMode />)
  fireEvent.click(screen.getByRole('button', { name: 'Character tools', exact: true }))
  const homes = within(screen.getByRole('navigation', { name: 'Solo character sections' }))
  fireEvent.click(homes.getByRole('button', { name: 'Items', exact: true }))
  const views = within(screen.getByRole('navigation', { name: 'Solo Items views' }))
  fireEvent.click(views.getByRole('button', { name: 'Give & repair', exact: true }))
  expect(screen.queryByRole('button', { name: 'Repair all carried equipment', exact: true })).not.toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Repair equipment', exact: true }))
  expect(screen.getByRole('button', { name: 'Repair all carried equipment', exact: true })).toBeDisabled()
  expect(screen.queryByRole('button', { name: 'Give item', exact: true })).not.toBeInTheDocument()
  expect(screen.queryByRole('button', { name: 'Back to give & repair', exact: true })).not.toBeInTheDocument()
  expect(screen.getByRole('button', { name: 'Repair equipment', exact: true })).toHaveAttribute('aria-expanded','true')
  fireEvent.click(screen.getByRole('button', { name: 'Give Item', exact: true }))
  expect(screen.getByRole('button', { name: 'Give item', exact: true })).toBeDisabled()
  expect(screen.queryByRole('button', { name: 'Repair all carried equipment', exact: true })).not.toBeInTheDocument()
  fireEvent.click(views.getByRole('button', { name: 'Character Inventory', exact: true }))
  fireEvent.click(views.getByRole('button', { name: 'Give & repair', exact: true }))
  expect(screen.queryByRole('button', { name: 'Give item', exact: true })).not.toBeInTheDocument()
  expect(screen.getByRole('button', { name: 'Give Item', exact: true })).toBeInTheDocument()
  expect(vi.mocked(api).mock.calls.some(([, options]) => options?.method && options.method !== 'GET')).toBe(false)
})
