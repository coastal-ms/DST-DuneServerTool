import fs from 'node:fs'
import path from 'node:path'
import { expect, it, vi } from 'vitest'
const html = fs.readFileSync(path.resolve(import.meta.dirname, '../../app/tools/DuneAtlas/index.html'), 'utf8')
it.each([[1024,768],[768,1024],[1180,820],[390,844]])('uses the whole expanded %ix%i viewport even with layers open', (width,height) => {
 const boundsSource=html.slice(html.indexOf('function viewBounds()'),html.indexOf('const gatheringCache='))
 const document={querySelector:()=>({hidden:false,getBoundingClientRect:()=>({right:280})})}
 const expanded=new Function('document','innerWidth','innerHeight',`const embeddedExpanded=true,mapOnly=false;${boundsSource};return viewBounds()`)(document,width,height)
 expect(expanded).toEqual({left:0,top:0,width,height})
})
const source = html.slice(html.indexOf('async function toggleFullScreen()'), html.indexOf('let embeddedExpanded='))
it('asks the embedding portal to expand without requiring browser fullscreen', async () => {
 const postMessage=vi.fn(),requestFullscreen=vi.fn(),window={parent:{postMessage}}
 const document={fullscreenElement:null,documentElement:{requestFullscreen}}
 const control=new Function('window','document','draw','let zoom=2,pan={x:1,y:2};'+source+';return toggleFullScreen')(window,document,vi.fn())
 await control()
 expect(postMessage).toHaveBeenCalledWith({type:'dst-atlas-toggle-expand'},'*')
 expect(requestFullscreen).not.toHaveBeenCalled()
})
it('fits a zoomed or panned map even when fullscreen is unavailable or rejected', async () => {
 for (const request of [undefined, vi.fn().mockRejectedValue(new Error('Unavailable')), vi.fn().mockResolvedValue(undefined)]) {
  const draw = vi.fn()
  const document = { fullscreenElement: null, documentElement: { requestFullscreen: request } }
  const control = new Function('document', 'draw', 'let zoom=.5,pan={x:100,y:50};'+source+';return {toggleFullScreen,view:()=>({zoom,pan})}')(document, draw)
  await expect(control.toggleFullScreen()).resolves.toBeUndefined()
  expect(control.view()).toEqual({ zoom: 1, pan: { x: 0, y: 0 } })
  expect(draw).toHaveBeenCalledTimes(2)
 }
})
it('exits fullscreen through the same fit action', async () => {
 const exitFullscreen=vi.fn().mockResolvedValue(undefined)
 const document={fullscreenElement:{},exitFullscreen,documentElement:{}}
 const control=new Function('document','draw','let zoom=2,pan={x:1,y:2};'+source+';return toggleFullScreen')(document,vi.fn())
 await control()
 expect(exitFullscreen).toHaveBeenCalledOnce()
})
