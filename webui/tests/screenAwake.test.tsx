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
afterEach(()=> { cleanup();delete (navigator as unknown as {wakeLock?:unknown}).wakeLock;vi.restoreAllMocks() })
describe('expanded map screen wake lock',()=> {
  it('requests only while expanded and releases on restore',async()=> {
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
  it('shows when the device releases a lock automatically',async()=> {
    const lock=sentinel(),request=vi.fn().mockResolvedValue(lock)
    Object.defineProperty(navigator,'wakeLock',{configurable:true,value:{request}})
    render(<Fixture />)
    await screen.findByText('active')
    act(()=>lock.dispatchEvent(new Event('release')))
    expect(screen.getByText('unavailable')).toBeInTheDocument()
    expect(request).toHaveBeenCalledOnce()
  })
})
