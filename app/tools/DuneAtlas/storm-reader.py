import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent if Path(__file__).resolve().parent.name=="hagga" else Path(__file__).resolve().parent))
import atlas_process
import sys,os
"""Read observed storm actors; never invent a route or live position."""
from pathlib import Path
import json,subprocess,struct,math,datetime
R=Path(__file__).resolve().parent
def read_storms(m,managers):
 R=m.ROOT
 cache_file=R/'event-actor-cache.json';cache=json.loads(cache_file.read_text()) if cache_file.exists() else {}
 valid=cache.get('pid')==m.PID and cache.get('startTime')==m.context['startTime']
 candidates=[a for a in cache.get('actors',[]) if a['type']=='_ZTV14ASandStormBase'] if valid else []
 ids={s['routeId'] for s in managers if s['routeId']!='0'}
 if ids and (not candidates or ids!=set(cache.get('managerRouteIds',[]))):
  result=atlas_process.run([sys.executable,str(Path(__file__).resolve().parent/'find-event-actors.py')],env={**os.environ,'DST_ATLAS_WORLD_ROOT':str(R)},capture_output=True,text=True,timeout=80)
  if result.returncode:raise RuntimeError('Storm actor discovery unavailable')
  cache=json.loads(cache_file.read_text());cache['managerRouteIds']=sorted(ids);temp=cache_file.with_suffix('.tmp');temp.write_text(json.dumps(cache,indent=2));temp.replace(cache_file);candidates=[a for a in cache['actors'] if a['type']=='_ZTV14ASandStormBase']
 if not candidates:return []
 payload=m.read_many([(a['address'],1552) for a in candidates]);pending=[]
 for candidate,obj in zip(candidates,payload):
  if struct.unpack_from('<Q',obj)[0]!=candidate['vtable'] or struct.unpack_from('<I',obj,8)[0]&48:continue
  remaining,total=struct.unpack_from('<2f',obj,1260)
  if not(0<remaining<=total<100000):continue
  root=struct.unpack_from('<Q',obj,568)[0]
  if not root:continue
  pending.append({'id':str(struct.unpack_from('<Q',obj,1152)[0]),'actor':candidate['address'],'vtable':candidate['vtable'],'root':root,'start':struct.unpack_from('<3d',obj,1160),'finish':struct.unpack_from('<3d',obj,1184),'remaining':remaining,'total':total})
 # Read actual zone definitions and attachment transforms; reject unsupported chains.
 zone_ptrs={p['actor']:list(struct.unpack_from('<6Q',obj,904)) for p,obj in [(p,payload[candidates.index(next(c for c in candidates if c['address']==p['actor']))]) for p in pending]}
 all_zones=list(dict.fromkeys(z for values in zone_ptrs.values() for z in values if z))
 zone_raw=dict(zip(all_zones,m.read_many([(z,1920) for z in all_zones])))
 data_ptrs=list(dict.fromkeys(struct.unpack_from('<Q',v,1896)[0] for v in zone_raw.values() if struct.unpack_from('<Q',v,1896)[0]))
 data_raw=dict(zip(data_ptrs,m.read_many([(z,224) for z in data_ptrs])))
 parent_ptrs=list(dict.fromkeys(struct.unpack_from('<Q',v,336)[0] for v in zone_raw.values() if struct.unpack_from('<Q',v,336)[0]))
 parent_raw=dict(zip(parent_ptrs,m.read_many([(z,544) for z in parent_ptrs])))
 for p in pending:
  p['zones']=[]
  for z in zone_ptrs[p['actor']]:
   if z not in zone_raw:continue
   v=zone_raw[z];data=data_raw.get(struct.unpack_from('<Q',v,1896)[0]);par=parent_raw.get(struct.unpack_from('<Q',v,336)[0])
   if not data or not par:continue
   if struct.unpack_from('<Q',par,336)[0]!=p['root']:continue
   if any(abs(x)>1e-5 for x in struct.unpack_from('<6d',par,456)) or any(abs(x-1)>1e-5 for x in struct.unpack_from('<3d',par,504)):continue
   width,length=struct.unpack_from('<2f',data,56)
   if not 0<width<100000 or not 0<length<100000:continue
   p['zones'].append({'component':z,'offset':struct.unpack_from('<3d',v,456),'rotation':struct.unpack_from('<3d',v,480),'widthMeters':width,'lengthMeters':length,'damaging':bool(data[160]),'warning':bool(data[163]),'shiftsSands':bool(data[185])})
 roots=m.read_many([(p['root'],544) for p in pending]);storms=[]
 for p,obj in zip(pending,roots):
  if struct.unpack_from('<Q',obj,336)[0]:continue
  p['location']=struct.unpack_from('<3d',obj,456);p['rotation']=struct.unpack_from('<3d',obj,480);p['scale']=struct.unpack_from('<3d',obj,504)
  if all(math.isfinite(v) for key in ['location','start','finish'] for v in p[key]):storms.append(p)
 return storms
