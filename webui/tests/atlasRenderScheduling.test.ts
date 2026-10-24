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


it('preserves the canvas backing store through refreshes and resizes only when needed',()=>{
 const resizeSource=html.slice(html.indexOf('function resizeMapCanvas('),html.indexOf('let drawFrame='))
 const resize=new Function(resizeSource+';return resizeMapCanvas')()
 let width=0,height=0,resets=0
 const target={get width(){return width},set width(v){width=v;resets++},get height(){return height},set height(v){height=v;resets++}}
 resize(target,1400,900,1)
 expect(resets).toBe(2)
 for(let i=0;i<20;i++)resize(target,1400,900,1)
 expect(resets).toBe(2)
 resize(target,1400,900,2)
 expect(width).toBe(2800);expect(height).toBe(1800);expect(resets).toBe(4)
})
