import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent if Path(__file__).resolve().parent.name=="hagga" else Path(__file__).resolve().parent))
import atlas_process
import sys
"""Read verified runtime small-shipwreck site actors without asserting activity."""
from pathlib import Path
import json,struct,math,datetime,subprocess

def read_sites(root,m,region,origin,span,attempt=0):
 cache=root/'wreck-actor-cache.json'
 try:
  data=json.loads(cache.read_text());age=(datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(data['capturedAt'])).total_seconds()
  current=data['pid']==m.PID and str(data['startTime'])==str(m.context['startTime']) and 0<=age<120
 except Exception:current=False
 if not current:
  result=atlas_process.run([sys.executable,str(root/'find-wreck-actors.py')],capture_output=True,text=True,timeout=35,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
  if result.returncode:raise ValueError('Wreck actor discovery unavailable')
  data=json.loads(cache.read_text())
 if data['pid']!=m.PID or str(data['startTime'])!=str(m.context['startTime']):raise ValueError('Wreck source identity changed')
 actors=[v for v in data['actors'] if v['type']=='_ZTV17ADynamicEncounter']
 if len(actors)>1000:raise ValueError('Unexpected encounter count')
 m.cache.clear();raws=m.read_many([(v['address'],1128) for v in actors]);candidates=[]
 for actor,b in zip(actors,raws):
  if struct.unpack_from('<Q',b)[0]!=actor['vtable'] or struct.unpack_from('<I',b,8)[0]&0x18030:continue
  ni=struct.unpack_from('<I',b,24)[0];asset=struct.unpack_from('<I',b,1104)[0];scene=struct.unpack_from('<Q',b,568)[0]
  if not ni or ni>>16>=len(m.blocks) or asset>>16>=len(m.blocks) or not 0x10000<scene<0x800000000000:continue
  candidates.append((actor,ni,asset,scene,struct.unpack_from('<q',b,200)[0]))
 m.cache.clear();m.read_many([(m.blocks[i],131072) for i in {n>>16 for a,ni,asset,scene,eid in candidates for n in [ni,asset]}]);named=[(a,scene,m.name(asset),eid) for a,ni,asset,scene,eid in candidates if m.name(ni)=='BP_DE_Dsrt_C' and region=='DeepDesert' and m.name(asset)=='DA_DE_120_SmallShipWreck_DeepDesert_01']
 lifetimes={};timerObservedAt=None
 if named:
  poolFile=root/'dynamic-encounter-pool-cache.json'
  try:
   poolCache=json.loads(poolFile.read_text())
   if poolCache['pid']!=m.PID or str(poolCache['startTime'])!=str(m.context['startTime']):raise ValueError('Pool process changed')
  except Exception:
   command=atlas_process.run([sys.executable,str(root/'find-dynamic-encounter-pool.py')],capture_output=True,text=True,timeout=35,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
   if command.returncode:raise ValueError('Encounter lifetime discovery unavailable')
   poolCache=json.loads(poolFile.read_text())
  pools=[v for v in poolCache['actors'] if v['type']=='_ZTV14TComponentPoolI26FDynamicEncounterComponentE']
  if len(pools)!=1:raise ValueError('Encounter lifetime pool is ambiguous')
  pool=pools[0];m.cache.clear();h=m.read_many([(pool['address'],624)])[0]
  if struct.unpack_from('<Q',h)[0]!=pool['vtable']:raise ValueError('Encounter pool identity changed')
  ptr,n,cap=struct.unpack_from('<Qii',h,584)
  if not 0<=n<=cap<10000:raise ValueError('Invalid encounter pool size')
  if n:
   m.cache.clear();entries=b''.join(m.read_many([(ptr+o,min(65536,n*24-o)) for o in range(0,n*24,65536)]));wanted={eid for a,scene,asset,eid in named};parts=[]
   for i in range(n):
    eid,component=struct.unpack_from('<qQ',entries,i*24)
    if eid in wanted:parts.append((i,eid,component))
   m.cache.clear();values=m.read_many([(component,12) for i,eid,component in parts]);timerObservedAt=datetime.datetime.now(datetime.timezone.utc).isoformat()
   m.cache.clear();post=m.read_many([(ptr+i*24,16) for i,eid,component in parts]);poolAfter=m.read_many([(pool['address']+584,16)])[0]
   if poolAfter!=h[584:600]:
    if attempt<1:return read_sites(root,m,region,origin,span,attempt+1)
    raise ValueError('Encounter pool changed during read')
   for (i,eid,component),value,check in zip(parts,values,post):
    seconds=struct.unpack_from('<f',value,4)[0]
    if check==struct.pack('<qQ',eid,component) and math.isfinite(seconds) and 0<seconds<86400:lifetimes[eid]=seconds
 m.cache.clear();roots=m.read_many([(scene,544) for actor,scene,asset,eid in named]);result=[]
 for (actor,scene,asset,eid),b in zip(named,roots):
  parent=struct.unpack_from('<Q',b,336)[0];p=struct.unpack_from('<3d',b,456)
  if eid not in lifetimes or parent or not all(math.isfinite(v) for v in p) or not all(origin<=v<=origin+span for v in p[:2]):continue
  result.append({'id':'wreck-site:'+str(actor['address']),'map':region,'type':'SmallShipwreckSite','location':dict(zip(['x','y','z'],p)),'source':'server encounter actor','encounterEntityId':str(eid),'encounterRemainingSeconds':lifetimes[eid],'encounterObservedAt':timerObservedAt,'visibilityUnverified':True,'runtimeDefinition':asset})
 return result
