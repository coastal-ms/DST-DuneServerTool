import {expect,it} from 'vitest'
import {parseBlueprintFile} from '../src/util/blueprintFile'
const layout={schematic:true,name:'Map base',pieces:[['10','20',0,'Floor',[100,200,300,0,0,0,1]],['10','20',1,'Wall',[300,200,500,0,0,Math.SQRT1_2,Math.SQRT1_2]]],placeables:[{id:'99',type:'Storage_Placeable',location:{x:250,y:200,z:350},rotation:{x:0,y:0,z:Math.SQRT1_2,w:Math.SQRT1_2}}]}
it('converts a downloaded map layout into centered portable pieces and placeables',()=>{
 const bp=parseBlueprintFile(JSON.stringify(layout))
 expect(bp.instances[0]).toEqual({building_type:'Floor',x:-100,y:0,z:-100,rotation:0})
 expect(bp.instances[1].rotation).toBeCloseTo(90)
 expect(bp.placeables[0]).toMatchObject({placeable_id:1,building_type:'Storage_Placeable',x:50,y:0,z:-50,rx:0,rz:0})
 expect(bp.placeables[0].ry).toBeCloseTo(90)
 expect(bp.pentashields).toEqual([])
})
it('preserves portable blueprint IDs, stability and pentashield references',()=>{
 const bp={name:'Portable',instances:[{building_type:'Floor',x:0,y:0,z:0,rotation:0,instance_id:3,provides_stability:true}],placeables:[],pentashields:[{placeable_id:7,scale:[2,3,4]}]}
 expect(parseBlueprintFile(JSON.stringify(bp))).toEqual(bp)
})
it.each([{}, {pieces:[]}, {...layout,pieces:[['10','20',0,'Floor',[1,2]]]}, {...layout,pieces:[['10','20',0,'Floor',[1,2,3,0,0,0,0]]]}])('rejects incomplete or invalid layouts',data=>{
 expect(()=>parseBlueprintFile(JSON.stringify(data))).toThrow()
})
