import fs from 'node:fs'
import path from 'node:path'
import {expect,it} from 'vitest'
const html=fs.readFileSync(path.resolve(import.meta.dirname,'../../app/tools/DuneAtlas/index.html'),'utf8')
const source=html.slice(html.indexOf('function stormTrailExtent('),html.indexOf('\n',html.indexOf('function stormTrailExtent(')))
const extent=new Function('point',source+';return stormTrailExtent')((u:number,v:number)=>({u,v}))
it.each([[1,0],[-1,0],[0,1],[0,-1],[1,1],[-1,-1],[1,-1],[-1,1]])('spans the whole map for a short observed direction %s,%s',(u,v)=>{
 const trail=[{location:[.4,.4,0]},{location:[.4+u*.02,.4+v*.02,0]}]
 const result=extent(trail),length=Math.hypot(u,v),direction={u:u/length,v:v/length}
 const projection=(p:{u:number;v:number})=>p.u*direction.u+p.v*direction.v
 const corners=[{u:0,v:0},{u:0,v:1},{u:1,v:0},{u:1,v:1}].map(projection)
 expect(projection(result.start)).toBeCloseTo(Math.min(...corners))
 expect(projection(result.end)).toBeCloseTo(Math.max(...corners))
 expect(result.delta.u*u+result.delta.v*v).toBeGreaterThan(0)
})
it('uses observed motion even when native route endpoints disagree',()=>{
 const result=extent([{location:[.2,.2,0],start:[0,0,0],finish:[0,1,0]},{location:[.21,.2,0]}])
 expect(result.delta.u).toBeCloseTo(1);expect(result.delta.v).toBeCloseTo(0)
})
it('uses the native direction for one observation and rejects an unknown direction',()=>{
 const delta=extent([{location:[.1,.1,0],start:[0,0,0],finish:[1,1,0]}]).delta
 expect(delta.u).toBeCloseTo(1);expect(delta.v).toBeCloseTo(1)
 expect(extent([{location:[.1,.1,0]}])).toBeNull()
})
