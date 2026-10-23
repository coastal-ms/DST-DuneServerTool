import fs from 'node:fs'
import path from 'node:path'
import { expect, it, vi } from 'vitest'

const html=fs.readFileSync(path.resolve(import.meta.dirname,'../../app/tools/DuneAtlas/index.html'),'utf8')
const source=html.slice(html.indexOf('let drawFrame='),html.indexOf('function paintMap()'))

it('combines state and hover redraws into one paint per browser frame',()=> {
  let frame!:()=>void
  const request=vi.fn(callback=>{frame=callback;return 1}),paint=vi.fn()
  const draw=new Function('requestAnimationFrame','paintMap','document',source+';return draw')(request,paint,{hidden:false})
  draw();draw();draw()
  expect(request).toHaveBeenCalledOnce()
  expect(paint).not.toHaveBeenCalled()
  frame()
  expect(paint).toHaveBeenCalledOnce()
  draw();frame()
  expect(paint).toHaveBeenCalledTimes(2)
})

it('skips a hidden viewer without disabling future visible paints',()=> {
  let frame!:()=>void
  const document={hidden:true},paint=vi.fn()
  const draw=new Function('requestAnimationFrame','paintMap','document',source+';return draw')((callback:()=>void)=>{frame=callback;return 1},paint,document)
  draw();frame()
  expect(paint).not.toHaveBeenCalled()
  document.hidden=false
  draw();frame()
  expect(paint).toHaveBeenCalledOnce()
})
