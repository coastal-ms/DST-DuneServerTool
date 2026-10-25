import fs from 'node:fs'
import path from 'node:path'
import { beforeEach, expect, it } from 'vitest'
const html=fs.readFileSync(path.resolve(import.meta.dirname,'../../app/tools/DuneAtlas/index.html'),'utf8')
const source=html.slice(html.indexOf('function detailsPanel('),html.indexOf('canvas.onclick=e=>'))
const items=[{type:'bases',label:'Base 145\n930 pieces',details:{baseId:145,model:{name:'Base 145'}}},{type:'vehicles',label:'Scout\nFuel 75%'}]
let controls: {showNearbyMarkers:(items:unknown[])=>void,showMarkerDetails:(marker:unknown,nearby?:unknown[])=>void}
beforeEach(()=>{document.body.innerHTML='<div id="inspect"></div>';controls=new Function('document','resourceUrl',source+';return {showNearbyMarkers,showMarkerDetails}')(document,(p:string)=>p)})
it('opens every clustered item and returns to the list without hover',()=>{
 controls.showNearbyMarkers(items)
 const list=()=>[...document.querySelectorAll<HTMLButtonElement>('.nearby-item')]
 expect(list()).toHaveLength(2)
 list()[0].click()
 expect(document.querySelector('#inspect')?.textContent).toContain('930 pieces')
 expect(document.querySelector('img')?.getAttribute('src')).toBe('/bases/145.svg')
 document.querySelector<HTMLButtonElement>('.details-back')!.click()
 list()[1].click()
 expect(document.querySelector('#inspect')?.textContent).toContain('Fuel 75%')
 document.querySelector<HTMLButtonElement>('[aria-label="Close details"]')!.click()
 expect(document.querySelector<HTMLElement>('#inspect')!.style.display).toBe('none')
})
it('renders marker labels as text and preserves base download access',()=>{
 controls.showMarkerDetails({...items[0],label:'<img src=x onerror=alert(1)>\n930 pieces'})
 expect(document.querySelectorAll('img')).toHaveLength(1)
 expect(document.querySelector('.details-heading strong')?.textContent).toContain('<img')
 expect(document.querySelector('a')?.getAttribute('download')).toBe('base-145.json')
 expect(document.querySelector('.details-back')).toBeNull()
})
