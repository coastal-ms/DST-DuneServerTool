import fs from 'node:fs'
import path from 'node:path'
import { expect, it } from 'vitest'
const html=fs.readFileSync(path.resolve(import.meta.dirname,'../../app/tools/DuneAtlas/index.html'),'utf8')
const source=html.slice(html.indexOf('function recordedStormTrails('),html.indexOf('function mapPoiCatalog('))
const {encounterVisible,recordedStormTrails}=new Function(source+';return {encounterVisible,recordedStormTrails}')()
it('expires an observed ship at its remaining lifetime and rejects unknown timers',()=>{
 const now=Date.parse('2026-10-24T06:00:00Z'),ship={type:'SmallShipwreckSite',encounterObservedAt:new Date(now).toISOString(),encounterRemainingSeconds:60}
 expect(encounterVisible(ship,now+59999)).toBe(true)
 expect(encounterVisible(ship,now+60000)).toBe(false)
 expect(encounterVisible({...ship,encounterRemainingSeconds:0},now)).toBe(false)
 expect(encounterVisible({...ship,encounterObservedAt:undefined},now)).toBe(false)
 expect(encounterVisible({...ship,encounterRemainingSeconds:60},now-10000)).toBe(false)
 expect(encounterVisible({type:'Shipwreck'},now)).toBe(true)
})
it('keeps completed trails when the current process reuses an older storm ID',()=>{
 const frame=(map:string,pid:number,id:string,time:number)=>({map,pid,startTime:'start'+pid,capturedAt:new Date(time).toISOString(),storms:[{id,location:[0,0,0]}]})
 const frames=[frame('DeepDesert',1,'1',1000),frame('DeepDesert',2,'2',2000),frame('DeepDesert',3,'1',3000),frame('HaggaBasin',4,'4',4000)]
 const result=recordedStormTrails(frames,{pid:3,startTime:'start3'},[{id:'1'}],'DeepDesert')
 expect(result.map(([key]:[string])=>key)).toEqual(['1:start1:1','2:start2:2'])
 expect(recordedStormTrails(frames,null,[],'HaggaBasin')).toHaveLength(1)
})
