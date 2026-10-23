import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { LocalAtlasPreview } from '../src/pages/workspaces/LocalAtlasPreview'
import { StatusProvider } from '../src/hooks/useStatus'
const mocks=vi.hoisted(()=>({awake:vi.fn(),request:vi.fn()}))
vi.mock('../src/hooks/useScreenAwake',()=>({useScreenAwake:(enabled:boolean)=>{mocks.awake(enabled);return enabled?'active':'idle'}}))
vi.mock('../src/api/client',()=>({api:mocks.request}))
vi.mock('../src/hooks/useInstallationMode',()=>({useSoloInstallation:()=>false}))
vi.mock('../src/hooks/useHealthRefresh',()=>({useHealthRefreshPreset:()=>({statusIntervalMs:1000})}))
afterEach(()=>{cleanup();vi.useRealTimers();vi.clearAllMocks()})
it('releases expanded wake lock and pauses only this portal polling until resume or navigation',async()=>{
 vi.useFakeTimers();mocks.request.mockResolvedValue({ts:new Date().toISOString(),vm:{running:true}})
 const view=render(<StatusProvider><LocalAtlasPreview url="/api/v1/maps/atlas/view?embedded=1" /></StatusProvider>)
 const frame=screen.getByTitle('Own-server live atlas') as HTMLIFrameElement
 const send=(data:object,source:Window|null=frame.contentWindow)=>fireEvent(window,new MessageEvent('message',{origin:window.location.origin,source,data}))
 await act(async()=>{})
 send({type:'dst-atlas-toggle-expand'});expect(mocks.awake).toHaveBeenLastCalledWith(true)
 send({type:'dst-atlas-viewer-paused',paused:true},window)
 expect(mocks.awake).toHaveBeenLastCalledWith(true)
 send({type:'dst-atlas-viewer-paused',paused:true})
 expect(mocks.awake).toHaveBeenLastCalledWith(false)
 expect(screen.getByRole('status')).toHaveTextContent('Live map paused')
 const count=mocks.request.mock.calls.length
 await act(async()=>{await vi.advanceTimersByTimeAsync(5000)})
 expect(mocks.request).toHaveBeenCalledTimes(count)
 send({type:'dst-atlas-viewer-paused',paused:false})
 await act(async()=>{})
 expect(mocks.awake).toHaveBeenLastCalledWith(true)
 expect(mocks.request.mock.calls.length).toBeGreaterThan(count)
 send({type:'dst-atlas-viewer-paused',paused:true})
 view.rerender(<StatusProvider><p>Other page</p></StatusProvider>)
 const before=mocks.request.mock.calls.length
 await act(async()=>{await vi.advanceTimersByTimeAsync(2000)})
 expect(mocks.request.mock.calls.length).toBeGreaterThan(before)
})
