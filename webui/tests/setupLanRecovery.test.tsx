import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { SetupWizard } from '../src/pages/SetupWizard'
import * as setup from '../src/api/setup'
import { BrowserRouter, Route, Routes } from '../src/router'

vi.mock('../src/api/setup', () => ({
  getHyperVLan: vi.fn(), getHyperVLanCredential: vi.fn(), getHyperVLanInstallStatus: vi.fn(),
  getHyperVLanHostResources: vi.fn(), getPreflight: vi.fn(), getSetupConfig: vi.fn(),
  saveHyperVLan: vi.fn(), testHyperVLan: vi.fn(), saveHyperVLanCredential: vi.fn(), startHyperVLanInstall: vi.fn(),
  cancelHyperVLanInstall: vi.fn(), removeHyperVLanAttempt: vi.fn(),
}))
afterEach(() => { cleanup(); vi.resetAllMocks() })
beforeEach(() => {
  window.history.replaceState(null, '', '/')
  vi.mocked(setup.getSetupConfig).mockResolvedValue({} as never)
  vi.mocked(setup.getPreflight).mockResolvedValue({ checks: [] } as never)
  vi.mocked(setup.getHyperVLan).mockResolvedValue({ mode: 'lan', hostIp: '192.0.2.58', previousVmIp: '192.0.2.219' } as never)
  vi.mocked(setup.getHyperVLanCredential).mockResolvedValue({ exists: true, matchesHost: true, user: 'HOST\\Admin' } as never)
  vi.mocked(setup.getHyperVLanInstallStatus).mockResolvedValue({ running: false, phase: 'error', error: 'The previous installation was interrupted.', steps: [], ip: '' })
  vi.mocked(setup.getHyperVLanHostResources).mockResolvedValue({ ok: true, vmExists: false, drives: [{ drive: 'D:', freeGB: 200 }], switches: ['LAN'], hostRamGB: 64 })
})
it('requires the network choice and sends the chosen fixed address with the world inputs', async () => {
  await openInstall()
  fireEvent.click(screen.getByRole('button', {name:'Check host'}))
  await screen.findByRole('button', {name:'Install VM on host'})
  fireEvent.click(screen.getByRole('button', {name:'Install VM on host'}))
  await screen.findByText('Choose automatic (DHCP) or a fixed VM IP address.')
  expect(setup.startHyperVLanInstall).not.toHaveBeenCalled()
  fireEvent.change(screen.getByLabelText('VM IP address setup'), {target:{value:'static'}})
  expect(screen.getByLabelText('VM IP address')).toHaveValue('192.0.2.219')
  fireEvent.change(screen.getByLabelText(/Router \/ default gateway/), {target:{value:'192.0.2.1'}})
  fireEvent.change(screen.getByLabelText('World name'), {target:{value:'New World'}})
  fireEvent.change(screen.getByLabelText(/Self-hosted server token/), {target:{value:'token'}})
  vi.mocked(setup.startHyperVLanInstall).mockResolvedValue({ok:true,running:true})
  fireEvent.click(screen.getByRole('button', {name:'Install VM on host'}))
  await waitFor(() => expect(setup.startHyperVLanInstall).toHaveBeenCalledWith(expect.objectContaining({
    worldName:'New World', network:{mode:'static',address:'192.0.2.219',prefix:'24',gateway:'192.0.2.1',dns:'1.1.1.1'},resume:false,
  })))
})
async function openInstall() {
  render(<SetupWizard />)
  fireEvent.click(screen.getByRole('button', { name: /Hyper-V over LAN/ }))
  fireEvent.click(screen.getByRole('button', { name: 'Next' }))
  await screen.findByText('HOST\\Admin')
  fireEvent.click(screen.getByRole('button', { name: 'Next' }))
  await screen.findByRole('button', { name: 'Check host' })
}
it('keeps old failures and the install form hidden until a successful host check', async () => {
  await openInstall()
  expect(screen.queryByText('The previous installation was interrupted.')).not.toBeInTheDocument()
  expect(screen.queryByLabelText('World name')).not.toBeInTheDocument()
  expect(screen.queryByLabelText(/Host administrator password/)).not.toBeInTheDocument()
  expect(screen.getByText('Saved administrator:', {exact:false})).toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Check host' }))
  await screen.findByRole('button', { name: 'Install VM on host' })
  expect(setup.getHyperVLanHostResources).toHaveBeenCalledWith('192.0.2.58', undefined, undefined)
  expect(screen.queryByText(/VM running on the host/)).not.toBeInTheDocument()
})
it('offers resume for the recorded partial VM instead of treating it as a completed installation', async () => {
  vi.mocked(setup.getHyperVLanHostResources).mockResolvedValue({ok:true,vmExists:true,canResume:true,attemptDrive:'D:',drives:[],switches:[],hostRamGB:64})
  await openInstall()
  fireEvent.click(screen.getByRole('button', {name:'Check host'}))
  expect(await screen.findByRole('button', {name:'Resume setup'})).toBeEnabled()
  expect(screen.queryByText(/nothing to install/)).not.toBeInTheDocument()
})
it('provides cancellation and clearly waits for the current operation', async () => {
  const active = {running:true,phase:'transfer',ip:'',error:'',steps:[]}
  vi.mocked(setup.getHyperVLanInstallStatus).mockResolvedValue(active)
  vi.mocked(setup.cancelHyperVLanInstall).mockImplementation(async () => {
    vi.mocked(setup.getHyperVLanInstallStatus).mockResolvedValue({...active,cancelRequested:true})
    return {ok:true,running:true,cancelRequested:true}
  })
  await openInstall()
  fireEvent.click(await screen.findByRole('button', {name:'Cancel installation'}))
  await screen.findByText(/Waiting for the current operation to finish/)
  expect(screen.getByRole('button', {name:'Cancelling…'})).toBeDisabled()
})
it('requires confirmation to remove a partial attempt', async () => {
  vi.mocked(setup.getHyperVLanInstallStatus).mockResolvedValue({running:false,phase:'error',ip:'',error:'The previous installation was interrupted.',steps:[],vmId:'fixture'})
  vi.mocked(setup.getHyperVLanHostResources).mockResolvedValue({ok:true,vmExists:true,canResume:true,attemptDrive:'D:',drives:[],switches:[],hostRamGB:64})
  const confirm = vi.spyOn(window,'confirm').mockReturnValue(false)
  await openInstall()
  fireEvent.click(screen.getByRole('button', {name:'Check host'}))
  await screen.findByRole('button', {name:'Resume setup'})
  fireEvent.click(screen.getByRole('button', {name:'Remove this attempt'}))
  expect(confirm).toHaveBeenCalled()
  expect(setup.removeHyperVLanAttempt).not.toHaveBeenCalled()
  confirm.mockRestore()
})
it('requires both override fields and invalidates an earlier host check when credentials change', async () => {
  await openInstall()
  fireEvent.click(screen.getByRole('button', { name: 'Check host' }))
  await screen.findByRole('button', { name: 'Install VM on host' })
  fireEvent.click(screen.getByRole('button', {name:'Change credential'}))
  expect(screen.getByLabelText(/Host administrator username/)).toHaveValue('HOST\\Admin')
  fireEvent.change(screen.getByLabelText(/Host administrator username/), {target:{value:''}})
  fireEvent.change(screen.getByLabelText(/Host administrator password/), { target: { value: 'replacement' } })
  expect(screen.queryByRole('button', { name: 'Install VM on host' })).not.toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Check host' }))
  await screen.findByText(/Enter both the host administrator username/)
  expect(setup.getHyperVLanHostResources).toHaveBeenCalledTimes(1)
  fireEvent.change(screen.getByLabelText(/Host administrator username/), { target: { value: 'HOMEHYPERV\\Other' } })
  fireEvent.click(screen.getByRole('button', { name: 'Check host' }))
  await waitFor(() => expect(setup.getHyperVLanHostResources).toHaveBeenLastCalledWith('192.0.2.58', 'HOMEHYPERV\\Other', 'replacement'))
})

it.each([
  [/Hyper-V over LAN/, 6],
  [/Yes .*already have a server/, 5],
  [/No .*set one up for me/, 6],
] as const)('Finish opens Server Overview for wizard path %s', async (choice, steps) => {
  window.history.replaceState(null, '', '/setup')
  render(<BrowserRouter><Routes>
    <Route path="/setup" element={<SetupWizard />} />
    <Route path="/" element={<h1>Server Overview destination</h1>} />
  </Routes></BrowserRouter>)
  fireEvent.click(screen.getByRole('button', {name: choice}))
  for (let step = 1; step < steps; step++) {
    fireEvent.click(screen.getByRole('button', {name: 'Skip step'}))
  }
  expect(screen.queryByText('Server Health')).not.toBeInTheDocument()
  fireEvent.click(screen.getByRole('link', {name:'Finish'}))
  expect(await screen.findByRole('heading', {name:'Server Overview destination'})).toBeInTheDocument()
  expect(window.location.pathname).toBe('/')
})
