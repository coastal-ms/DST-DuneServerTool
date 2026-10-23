import fs from 'node:fs'
import path from 'node:path'
import { expect, it } from 'vitest'
const html=fs.readFileSync(path.resolve(import.meta.dirname,'../../app/tools/DuneAtlas/index.html'),'utf8')
const source=html.slice(html.indexOf('class MapViewerIdle'),html.indexOf('const viewerIdle='))
const Idle=new Function(source+';return MapViewerIdle')()
it('pauses only the abandoned viewer at one hour and resumes explicitly',()=>{
 let now=0;const idle=new Idle(()=>now),peer=new Idle(()=>now)
 now=3599999;expect(idle.check()).toBe(false)
 peer.activity();now=3600000;expect(idle.check()).toBe(true);expect(peer.check()).toBe(false)
 idle.activity();expect(idle.paused).toBe(true)
 idle.resume();expect(idle.paused).toBe(false);expect(idle.lastActivity).toBe(now)
})
it('extends the deadline for real interaction, not ordinary data refreshes',()=>{
 let now=0;const idle=new Idle(()=>now)
 now=3000000;idle.activity();now=3600000;expect(idle.check()).toBe(false)
 now=6600000;expect(idle.check()).toBe(true)
})
it('supports deliberate keep-live and restores a fresh timeout when unchecked',()=>{
 let now=0;const idle=new Idle(()=>now)
 idle.keep(true);now=7200000;expect(idle.check()).toBe(false)
 idle.keep(false);now+=3599999;expect(idle.check()).toBe(false)
 now++;expect(idle.check()).toBe(true)
})
