import fs from 'node:fs'
import path from 'node:path'
import { expect, it, vi } from 'vitest'
const html = fs.readFileSync(path.resolve(import.meta.dirname, '../../app/tools/DuneAtlas/index.html'), 'utf8')
const source = html.slice(html.indexOf('async function toggleFullScreen()'), html.indexOf("document.addEventListener('fullscreenchange'"))
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
