import type { BlueprintFile } from '../api/gameplay'

// Map base downloads contain native transforms; portable blueprints contain
// local coordinates. Match the existing server base export's centering and axes.
export function parseBlueprintFile(text: string): BlueprintFile {
  const data = JSON.parse(text)
  if (!data || typeof data !== 'object') throw new Error('Choose a DST blueprint or downloaded base layout.')
  if (Array.isArray(data.instances)) return data as BlueprintFile
  if (data.schematic !== true || !Array.isArray(data.pieces) || !Array.isArray(data.placeables)) {
    throw new Error('Choose a DST blueprint or downloaded base layout.')
  }
  const number = (n: unknown): number => {
    if (typeof n !== 'number' || !Number.isFinite(n)) throw new Error('The base layout contains an invalid transform.')
    return n
  }
  const type = (s: unknown): string => {
    if (typeof s !== 'string' || !s.trim()) throw new Error('The base layout contains a missing building type.')
    return s
  }
  const euler = (values: unknown[]) => {
    let [x,y,z,w] = values.map(number)
    const length = Math.hypot(x,y,z,w)
    if (!length) throw new Error('The base layout contains an invalid rotation.')
    x/=length; y/=length; z/=length; w/=length
    const degrees = 180 / Math.PI
    return [Math.atan2(2*(w*x+y*z),1-2*(x*x+y*y))*degrees,
      Math.asin(Math.max(-1,Math.min(1,2*(w*y-z*x))))*degrees,
      Math.atan2(2*(w*z+x*y),1-2*(y*y+z*z))*degrees]
  }
  const pieces = data.pieces.map((p: unknown) => {
    if (!Array.isArray(p) || !Array.isArray(p[4]) || p[4].length !== 7) throw new Error('The base layout contains an invalid building piece.')
    return {building_type:type(p[3]), t:p[4].map(number) as number[]}
  }) as {building_type:string;t:number[]}[]
  if (!pieces.length) throw new Error('The base layout has no building pieces.')
  const center = [0,1,2].map(axis => pieces.reduce((sum,p) => sum+p.t[axis],0)/pieces.length)
  return {
    name: typeof data.name === 'string' ? data.name : '',
    instances:pieces.map(p => ({building_type:p.building_type,x:p.t[0]-center[0],y:p.t[1]-center[1],z:p.t[2]-center[2],rotation:euler(p.t.slice(3))[2]})),
    placeables:data.placeables.map((p: {type:unknown;location:Record<string,unknown>;rotation:Record<string,unknown>},i:number) => {
      if (!p?.location || !p.rotation) throw new Error('The base layout contains an invalid placeable.')
      const angles=euler(['x','y','z','w'].map(k=>p.rotation[k]))
      return {placeable_id:i+1,building_type:type(p.type),x:number(p.location.x)-center[0],y:number(p.location.y)-center[1],z:number(p.location.z)-center[2],rx:angles[1],ry:angles[2],rz:angles[0]}
    }),
    pentashields:[],
  }
}
