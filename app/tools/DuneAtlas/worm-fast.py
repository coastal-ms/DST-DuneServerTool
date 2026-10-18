"""Fast read-only worm observations from validated cached pawn/root identities."""
from pathlib import Path
import json,struct,datetime,math,importlib.util
ROOT=Path(__file__).resolve().parent
class WormReader:
 def __init__(self,root=ROOT):
  self.root=Path(root)
  self.module=None;self.identity=None
 def read(self,native):
  ROOT=self.root
  context=json.loads((ROOT/'runtime-context.json').read_text())
  identity=(context['pid'],context['startTime'])
  if native['pid']!=context['pid'] or str(native.get('startTime'))!=str(context['startTime']):raise ValueError('Waiting for matching runtime snapshot')
  if self.identity!=identity:
   spec=importlib.util.spec_from_file_location('worm_memory',ROOT/'inspect-reflection.py');self.module=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.module);self.identity=identity
  m=self.module;m.cache.clear()
  system=next(s for s in native['systems'] if s['name']=='SandwormSubsystem');worms=system.get('worms',[])
  if not worms and system['territories']['count']:raise ValueError('Waiting for live worm identities')
  storms=native.get('storms',[]);vehicles=native.get('vehicles',[])
  started=datetime.datetime.now(datetime.timezone.utc).isoformat()
  requests=[(system['address'],64)]+[(w['pawn'],2080) for w in worms]+[(w['root'],544) for w in worms]+[(s['actor'],1552) for s in storms]+[(s['root'],544) for s in storms]+[(v['address'],576) for v in vehicles]+[(v['root'],544) for v in vehicles]
  payload=m.read_many(requests);head=payload[0]
  if struct.unpack_from('<Q',head)[0]!=context['needles']['_ZTV18USandwormSubsystem']:raise ValueError('Worm subsystem identity changed')
  if struct.unpack_from('<i',head,56)[0]!=system['territories']['count']:raise ValueError('Worm territories changed')
  items=[]
  for w,pawn,root in zip(worms,payload[1:1+len(worms)],payload[1+len(worms):1+2*len(worms)]):
   if struct.unpack_from('<Q',pawn)[0]!=context['needles']['_ZTV13ASandwormPawn'] or struct.unpack_from('<I',pawn,8)[0]&48:raise ValueError('Worm pawn identity changed')
   if struct.unpack_from('<Q',pawn,568)[0]!=w['root'] or struct.unpack_from('<i',pawn,1024)[0]!=w['id']:raise ValueError('Worm root identity changed')
   if struct.unpack_from('<Q',root,336)[0]:raise ValueError('Attached worm root requires transform composition')
   location=struct.unpack_from('<3d',root,456)
   if not all(math.isfinite(v) and abs(v)<1e8 for v in location):raise ValueError('Invalid worm location')
   items.append({'id':w['id'],'location':location,'hibernated':bool(pawn[1874]),'hidden':bool(pawn[1876])})
  storm_items=[];offset=1+2*len(worms)
  for expected,actor,root in zip(storms,payload[offset:offset+len(storms)],payload[offset+len(storms):offset+2*len(storms)]):
   if struct.unpack_from('<Q',actor)[0]!=expected['vtable'] or struct.unpack_from('<Q',actor,1152)[0]!=int(expected['id']):continue
   if struct.unpack_from('<Q',actor,568)[0]!=expected['root'] or struct.unpack_from('<Q',root,336)[0]:continue
   remaining,total=struct.unpack_from('<2f',actor,1260)
   if not 0<remaining<=total<100000:continue
   location=struct.unpack_from('<3d',root,456)
   if not all(math.isfinite(v) for v in location):continue
   storm_items.append({'id':expected['id'],'location':location,'start':expected['start'],'finish':expected['finish'],'remaining':remaining,'total':total,'rotation':struct.unpack_from('<3d',root,480),'scale':struct.unpack_from('<3d',root,504),'zones':expected.get('zones',[])})
  vehicle_items=[];offset=1+2*len(worms)+2*len(storms)
  for expected,actor,root in zip(vehicles,payload[offset:offset+len(vehicles)],payload[offset+len(vehicles):]):
   if struct.unpack_from('<Q',actor)[0]!=expected['vtable'] or struct.unpack_from('<I',actor,8)[0]&0x18030:continue
   if str(struct.unpack_from('<q',actor,200)[0])!=expected['entityId'] or struct.unpack_from('<Q',actor,568)[0]!=expected['root']:continue
   if struct.unpack_from('<Q',root,336)[0]:continue
   location=struct.unpack_from('<3d',root,456)
   if all(math.isfinite(v) and abs(v)<1e8 for v in location):vehicle_items.append({'entityId':expected['entityId'],'location':location})
  return {'pid':context['pid'],'startTime':context['startTime'],'startedAt':started,'capturedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'items':items,'storms':storm_items,'vehicles':vehicle_items}
