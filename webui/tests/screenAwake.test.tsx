import React from 'react'
import { act, cleanup, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useScreenAwake } from '../src/hooks/useScreenAwake'

function Fixture({enabled=true}:{enabled?:boolean}) { return <span>{useScreenAwake(enabled)}</span> }
function sentinel() {
  const value=new EventTarget() as EventTarget & {release:ReturnType<typeof vi.fn>}
  value.release=vi.fn().mockResolvedValue(undefined)
  return value
}
let visible:DocumentVisibilityState='visible'
beforeEach(()=> { visible='visible';vi.spyOn(document,'visibilityState','get').mockImplementation(()=>visible) })
afterEach(()=> { cleanup();delete (navigator as unknown as {wakeLock?:unknown}).wakeLock;vi.restoreAllMocks();vi.useRealTimers() })
describe('visible map screen wake lock',()=> {
  it('requests while enabled and releases when the viewer pauses or closes',async()=> {
    const lock=sentinel(),request=vi.fn().mockResolvedValue(lock)
    Object.defineProperty(navigator,'wakeLock',{configurable:true,value:{request}})
    const view=render(<Fixture enabled={false}/>)
    expect(request).not.toHaveBeenCalled()
    view.rerender(<Fixture />)
    expect(await screen.findByText('active')).toBeInTheDocument()
    expect(request).toHaveBeenCalledExactlyOnceWith('screen')
    view.rerender(<Fixture enabled={false}/>)
    expect(lock.release).toHaveBeenCalledOnce()
  })
  it('releases when hidden and reacquires on returning to the expanded map',async()=> {
    const first=sentinel(),second=sentinel(),request=vi.fn().mockResolvedValueOnce(first).mockResolvedValueOnce(second)
    Object.defineProperty(navigator,'wakeLock',{configurable:true,value:{request}})
    const view=render(<Fixture />)
    await screen.findByText('active')
    act(()=>{visible='hidden';document.dispatchEvent(new Event('visibilitychange'))})
    expect(first.release).toHaveBeenCalledOnce()
    act(()=>{visible='visible';document.dispatchEvent(new Event('visibilitychange'))})
    await waitFor(()=>expect(request).toHaveBeenCalledTimes(2))
    await screen.findByText('active')
    view.unmount()
    expect(second.release).toHaveBeenCalledOnce()
  })
  it('releases an in-flight request if the map was closed before it resolved',async()=> {
    const lock=sentinel();let resolve!:(value:unknown)=>void
    Object.defineProperty(navigator,'wakeLock',{configurable:true,value:{request:vi.fn(()=>new Promise(r=>{resolve=r}))}})
    const view=render(<Fixture />)
    view.unmount()
    await act(async()=>{resolve(lock)})
    expect(lock.release).toHaveBeenCalledOnce()
  })
  it('reports unsupported or refused locks without breaking the map or retrying continuously',async()=> {
    const view=render(<Fixture />)
    expect(await screen.findByText('unavailable')).toBeInTheDocument()
    view.unmount()
    const request=vi.fn().mockRejectedValue(new Error('Power saving'))
    Object.defineProperty(navigator,'wakeLock',{configurable:true,value:{request}})
    render(<Fixture />)
    expect(await screen.findByText('unavailable')).toBeInTheDocument()
    expect(request).toHaveBeenCalledOnce()
  })
  it('recovers one automatic release without repeatedly fighting device power policy',async()=> {
    vi.useFakeTimers()
    const first=sentinel(),second=sentinel(),request=vi.fn().mockResolvedValueOnce(first).mockResolvedValueOnce(second)
    Object.defineProperty(navigator,'wakeLock',{configurable:true,value:{request}})
    render(<Fixture />)
    await act(async()=>{})
    act(()=>first.dispatchEvent(new Event('release')))
    expect(screen.getByText('unavailable')).toBeInTheDocument()
    await act(async()=>{await vi.advanceTimersByTimeAsync(250)})
    expect(request).toHaveBeenCalledTimes(2)
    expect(screen.getByText('active')).toBeInTheDocument()
    act(()=>second.dispatchEvent(new Event('release')))
    await act(async()=>{await vi.advanceTimersByTimeAsync(10000)})
    expect(request).toHaveBeenCalledTimes(2)
    expect(screen.getByText('unavailable')).toBeInTheDocument()
  })
  it('retries a refused request after interaction and cleans up late requests across pagehide',async()=> {
    let resolve!:(value:unknown)=>void
    const lock=sentinel(),request=vi.fn().mockRejectedValueOnce(new Error('Gesture needed')).mockImplementationOnce(()=>new Promise(r=>{resolve=r}))
    Object.defineProperty(navigator,'wakeLock',{configurable:true,value:{request}})
    render(<Fixture />)
    await screen.findByText('unavailable')
    act(()=>window.dispatchEvent(new Event('dst-screen-awake-retry')))
    expect(request).toHaveBeenCalledTimes(2)
    act(()=>window.dispatchEvent(new Event('pagehide')))
    await act(async()=>{resolve(lock)})
    expect(lock.release).toHaveBeenCalledOnce()
  })
  it('renews from an explicit gesture but does not churn a held lock on ordinary map activity',async()=> {
    const first=sentinel(),second=sentinel(),request=vi.fn().mockResolvedValueOnce(first).mockResolvedValueOnce(second)
    Object.defineProperty(navigator,'wakeLock',{configurable:true,value:{request}})
    render(<Fixture />)
    await screen.findByText('active')
    act(()=>window.dispatchEvent(new Event('dst-screen-awake-activity')))
    expect(request).toHaveBeenCalledOnce()
    act(()=>window.dispatchEvent(new Event('dst-screen-awake-retry')))
    expect(first.release).toHaveBeenCalledOnce()
    await waitFor(()=>expect(request).toHaveBeenCalledTimes(2))
    await screen.findByText('active')
  })
  it('replaces a released sentinel on return even if its release event was missed',async()=> {
    const first=sentinel(),second=sentinel(),request=vi.fn().mockResolvedValueOnce(first).mockResolvedValueOnce(second)
    Object.defineProperty(navigator,'wakeLock',{configurable:true,value:{request}})
    render(<Fixture />)
    await screen.findByText('active')
    Object.defineProperty(first,'released',{value:true})
    act(()=>window.dispatchEvent(new Event('focus')))
    await waitFor(()=>expect(request).toHaveBeenCalledTimes(2))
  })
})
