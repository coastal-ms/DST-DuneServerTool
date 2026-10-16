import { afterEach, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { SoloDeck, type SoloDeckStatus } from '../src/components/solo/SoloDeck'

const request = vi.hoisted(() => vi.fn())
vi.mock('../src/api/client', () => ({ api: request }))
afterEach(() => { cleanup(); vi.resetAllMocks() })

const connected: SoloDeckStatus = {
  ok: true, paired: true, connected: true, readOnly: true, error: '',
  report: { os: { VERSION_ID: 'test' }, installations: [], saves: [], game_processes: [], errors: [], settings_candidates: [
    { saved_root: '/deck/save', files: [{ file: 'Engine.ini', path: '/deck/save/Config/Windows/Engine.ini', exists: true, duplicates: [], values: [
      { section: 'ConsoleVariables', key: 'Vehicle.MaxVehiclesPerPlayer', value: '12' },
    ] }] },
  ] },
}

it('reads only the Deck endpoint and offers no write control', async () => {
  request.mockResolvedValue(connected)
  render(<SoloDeck />)
  await screen.findByText('Vehicle.MaxVehiclesPerPlayer')
  expect(screen.getByText('12')).toBeInTheDocument()
  expect(request).toHaveBeenCalledWith('/api/solo/deck')
  expect(screen.queryByRole('button', { name: /apply|grant|launch|restore/i })).not.toBeInTheDocument()
})

it('hides earlier settings when the refreshed Deck is disconnected', async () => {
  request.mockResolvedValueOnce(connected).mockResolvedValueOnce({ ...connected, connected: false, report: null, error: 'Steam Deck is unavailable. It may be off or asleep.' })
  render(<SoloDeck />)
  await screen.findByText('Vehicle.MaxVehiclesPerPlayer')
  fireEvent.click(screen.getByRole('button', { name: 'Refresh Deck' }))
  const notice = await screen.findByText('Steam Deck is unavailable. It may be off or asleep.')
  expect(notice).toHaveAttribute('role', 'status')
  expect(notice).not.toHaveClass('text-danger')
  expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  expect(screen.queryByText('Vehicle.MaxVehiclesPerPlayer')).not.toBeInTheDocument()
})

it('shows pairing instructions without loading any local save', async () => {
  request.mockResolvedValue({ ...connected, paired: false, connected: false, report: null })
  render(<SoloDeck />)
  await screen.findByText('Connect your Steam Deck')
  await waitFor(() => expect(request).toHaveBeenCalledTimes(1))
  expect(request.mock.calls.every(call => call[0] === '/api/solo/deck')).toBe(true)
})

it('shows a comparison without implying that a missing Deck override is a game default', async () => {
  request.mockResolvedValue({ ...connected, comparison: { available: true, error: '', differenceCount: 1, differences: [
    { file: 'Game.ini', section: 'test', key: 'ExampleSetting', deckValue: null, pcValue: '15', action: 'Would copy to Deck', warning: 'Changing worm settings can affect bases built on sand. Review before syncing.' },
  ] } })
  render(<SoloDeck />)
  await screen.findByText('1 difference in explicit settings.')
  expect(screen.getByText('No override')).toBeInTheDocument()
  expect(screen.getByText('Would copy to Deck')).toBeInTheDocument()
  expect(screen.getByText(/bases built on sand/)).toBeInTheDocument()
  expect(screen.queryByText('Separate approval required')).not.toBeInTheDocument()
  expect(screen.queryByRole('button', { name: /sync|apply/i })).not.toBeInTheDocument()
})

it('shows pairing identity only after enabling pairing, without running transfers', async () => {
  request.mockImplementation(async path=>path==='/api/solo/deck/pairing'?{ok:true,addresses:['192.0.2.10:18749'],code:'ABCDEF',certificateFingerprint:'fixture-fingerprint',expires:'2026-10-15T23:00:00Z'}:connected)
  render(<SoloDeck />)
  await screen.findByText('Vehicle.MaxVehiclesPerPlayer')
  fireEvent.click(screen.getByRole('button',{name:'Enable pairing'}))
  await screen.findByText('fixture-fingerprint')
  expect(screen.getByText('192.0.2.10:18749')).toBeInTheDocument()
  expect(request).toHaveBeenCalledWith('/api/solo/deck/pairing',{method:'POST',body:'{}'})
  fireEvent.click(screen.getByRole('button',{name:'Refresh pairing code'}))
  await waitFor(()=>expect(request.mock.calls.filter(call=>call[0]==='/api/solo/deck/pairing')).toHaveLength(2))
  expect(request.mock.calls.some(call=>String(call[0]).endsWith('/apply'))).toBe(false)
})

it('requires Cloud preparation before the final settings sync and submits only its preview token', async () => {
  const capable={...connected,report:{...connected.report!,settings_write_capabilities:['managed-ini-v1']}}
  request.mockImplementation(async path=>{
    if(path==='/api/solo/deck/settings/preview')return {ok:true,token:'fixture-token',rows:[{file:'Engine.ini',key:'Test',pcValue:'1',deckValue:'0'}]}
    if(path==='/api/solo/deck/settings/apply')return {ok:true,saveUnchanged:true,remainingDifferences:0,backup:'/fixture/backup'}
    return capable
  })
  render(<SoloDeck />)
  fireEvent.click(await screen.findByRole('button',{name:'Preview settings sync'}))
  const approve=await screen.findByRole('button',{name:'Approve and sync settings to Deck'})
  expect(approve).toBeDisabled()
  fireEvent.click(screen.getByRole('checkbox',{name:/I loaded the intended save/}))
  fireEvent.click(approve)
  await waitFor(()=>expect(request).toHaveBeenCalledWith('/api/solo/deck/settings/apply',{method:'POST',body:JSON.stringify({token:'fixture-token',confirmed:true,cloudConfirmed:true})}))
  expect(await screen.findByText(/Settings now match DST/)).toBeInTheDocument()
})
