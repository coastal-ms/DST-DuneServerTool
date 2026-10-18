from pathlib import Path
import os,sys
sys.path.insert(0,str(Path(__file__).resolve().parent.parent if Path(__file__).resolve().parent.name=="hagga" else Path(__file__).resolve().parent))
from atlas_gathering import classify
import json,struct,importlib.util,math,datetime,collections
r=Path(__file__).resolve().parent;saved_spec=importlib.util.spec_from_file_location('saved_pois',(r.parent if r.name=='hagga' else r)/'saved-pois.py');saved_pois=importlib.util.module_from_spec(saved_spec);saved_spec.loader.exec_module(saved_pois);startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat();sp=importlib.util.spec_from_file_location('bounded',r/'bounded-memory.py');mod=importlib.util.module_from_spec(sp);sp.loader.exec_module(mod);reader=mod.Reader();ctx=reader.context
cache=json.loads((r/'poi-source-actor-cache.json').read_text())
if cache['pid']!=ctx['pid'] or str(cache['startTime'])!=str(ctx['startTime']):raise ValueError('Resource discovery belongs to different process')
region='HaggaBasin' if r.name=='hagga' else 'DeepDesert';origin,span=(-457200,812800) if region=='HaggaBasin' else (-1270000,2438400)
known={str(v['address']):v for v in cache['actors']};sites=[{'id':str(v['address']),'type':v['type']} for v in cache['actors'] if v['type'] in ['_ZTV20AResourceNodeSpawner','_ZTV30AHarvestableInstancedMeshActor']];print('Reading resource actors',len(sites),flush=True)
selected=os.environ.get('DST_ATLAS_GATHERING_KIND')
namecache={}
try:
 saved=json.loads((r/'gathering-actor-names.json').read_text())
 if saved['pid']==ctx['pid'] and str(saved['startTime'])==str(ctx['startTime']):namecache=saved['names']
except (OSError,ValueError,KeyError):pass
sites=[v for v in sites if v['id'] not in namecache or not selected or classify(namecache[v['id']])==selected]
heads=reader.read([(int(v['id']),32) for v in sites]);nameSpec=importlib.util.spec_from_file_location('names',r/'inspect-reflection.py');names=importlib.util.module_from_spec(nameSpec);nameSpec.loader.exec_module(names);indices={struct.unpack_from('<I',b,24)[0] for b in heads};blocks=list(dict.fromkeys(names.blocks[i>>16] for i in indices));namebuffers=reader.read([(ptr,131072) for ptr in blocks]);names.cache.update({(ptr,131072):buf for ptr,buf in zip(blocks,namebuffers)});nameMap={i:names.name(i) for i in indices}
for v,h in zip(sites,heads):v['name']=nameMap[struct.unpack_from('<I',h,24)[0]]
namecache.update({v['id']:v['name'] for v in sites});tmp=r/'gathering-actor-names.tmp';tmp.write_text(json.dumps({'pid':ctx['pid'],'startTime':ctx['startTime'],'names':namecache}));tmp.replace(r/'gathering-actor-names.json')
selected=os.environ.get("DST_ATLAS_GATHERING_KIND")
if selected:
 pairs=[(v,h) for v,h in zip(sites,heads) if classify(v["name"])==selected];sites=[v for v,h in pairs];heads=[h for v,h in pairs]
heads=reader.read([(int(v['id']),1224) for v in sites])
nodes=[];harvest=[]
for v,h in zip(sites,heads):
 if any(k in v['name'] for k in ['Door','EMFGenerator']):continue
 if struct.unpack_from('<Q',h)[0]!=known[v['id']]['vtable'] or struct.unpack_from('<I',h,8)[0]&0x18030:raise ValueError('Resource actor identity changed')
 if v['type']=='_ZTV20AResourceNodeSpawner':
  ptr=struct.unpack_from('<Q',h,1160)[0]
  if ptr:nodes.append((v,ptr))
 else:
  ptr,n,cap=struct.unpack_from('<Qii',h,1208)
  if not 0<=n<=cap<=128:raise ValueError('Invalid harvestable component array')
  if n:harvest.append((v,ptr,n))
print('Reading harvestable component lists',len(harvest),flush=True);arrays=reader.read([(ptr,n*8) for v,ptr,n in harvest])
for (v,ptr,n),b in zip(harvest,arrays):nodes.extend((v,component) for component in struct.unpack('<'+'Q'*n,b) if component)
unique=list(dict.fromkeys(ptr for v,ptr in nodes));print('Reading mesh components',len(unique),flush=True);buffers=reader.read([(ptr,1920) for ptr in unique]);components={};records=[];symbols=json.loads((r/'all-native-vtables.json').read_text());allowed={ctx['exeBase']+v['value']+16 for v in symbols if v['name'] in ['_ZTV41UHierarchicalInstancedStaticMeshComponent','_ZTV34UHarvestableInstancedMeshComponent','_ZTV36UFoliageInstancedStaticMeshComponent','_ZTV29UInstancedStaticMeshComponent','_ZTV18UResourceComponent']};byPtr={ptr:b for ptr,b in zip(unique,buffers)}
(r/'gathering-component-stage.json').write_text(json.dumps({'context':ctx,'nodes':nodes,'unique':unique,'capturedAt':datetime.datetime.now(datetime.timezone.utc).isoformat()}));(r/'gathering-component-stage.bin').write_bytes(b''.join(buffers));excluded=collections.Counter()
def scene(b):
 p=struct.unpack_from('<3d',b,456);rot=struct.unpack_from('<3d',b,480);scale=struct.unpack_from('<3d',b,504)
 if not all(math.isfinite(v) and abs(v)<1e9 for v in p+rot+scale):raise ValueError('Invalid scene transform')
 return {'parent':struct.unpack_from('<Q',b,336)[0],'p':p,'r':rot,'s':scale,'absolute':b[552]}
for ptr,b in byPtr.items():
 if struct.unpack_from('<Q',b)[0] not in allowed or struct.unpack_from('<I',b,8)[0]&0x18030:excluded[str(struct.unpack_from('<Q',b)[0])]+=1;continue
 components[ptr]=scene(b)
for v,ptr in nodes:
 if ptr not in components:continue
 b=byPtr[ptr];data,n,cap=struct.unpack_from('<Qii',b,1904)
 if not 0<=n<=cap<=100000:raise ValueError('Invalid instance array')
 if n:records.append({'actor':v['id'],'name':v['name'],'component':ptr,'data':data,'count':n})
todo={v['parent'] for v in components.values() if v['parent'] and v['parent'] not in components}
for depth in range(16):
 if not todo:break
 print('Reading scene parents',depth,len(todo),flush=True);raw=reader.read([(ptr,560) for ptr in todo]);new=set()
 for ptr,b in zip(todo,raw):
  if struct.unpack_from('<I',b,8)[0]&0x18030:raise ValueError('Destroyed scene parent')
  components[ptr]=scene(b);parent=components[ptr]['parent']
  if parent and parent not in components:new.add(parent)
 todo=new
else:raise ValueError('Attachment depth exceeded')
# Use the same verified Unreal rotator/quaternion composition as the POI exporter.
source=(r/'export-native-pois.py').read_text();exec(source[source.index('def qrot('):source.index('items=[]')])
requests=[];pieces=[]
for v in records:
 for off in range(0,v['count']*128,131072):requests.append((v['data']+off,min(131072,v['count']*128-off)));pieces.append((v,off))
print('Reading instance matrices',sum(v['count'] for v in records),flush=True);raws=reader.read(requests);print('Validating instance arrays',len(records),flush=True);post=reader.read([(v['component']+1904,16) for v in records]);stable={v['component'] for v,b in zip(records,post) if struct.unpack_from('<Qi',b)==(v['data'],v['count'])};out=[];degenerate=0
for (v,off),b in zip(pieces,raws):
 if v['component'] not in stable:continue
 pp,pq,ps=world(v['component'])
 for local in range(0,len(b),128):
  matrix=struct.unpack_from('<16d',b,local)
  if not all(math.isfinite(a) for a in matrix) or any(abs(matrix[j])>1e-8 for j in [3,7,11]) or abs(matrix[15]-1)>1e-8:raise ValueError('Invalid instance affine matrix')
  if any(sum(matrix[i+j]**2 for j in range(3))<1e-12 for i in [0,4,8]):degenerate+=1;continue
  pos=tuple(a+c for a,c in zip(pp,qrot(pq,tuple(a*s for a,s in zip(matrix[12:15],ps)))))
  if not all(origin<=a<=origin+span for a in pos[:2]):continue
  out.append({'id':'gather:'+v['actor']+':'+str((off+local)//128),'actorName':v['name'],'location':dict(zip(['x','y','z'],pos))})
print('Matching saved sites',len(out),flush=True);db=[v for v in saved_pois.read_saved(r) if v['map']==region and any(t in v['type'] for t in ['Ore','Pickup','Rock','BrittleBush','PrimroseField','FuelCell','ScrapMetal'])];grid=collections.defaultdict(list)
for v in out:grid[(math.floor(v['location']['x']/100),math.floor(v['location']['y']/100))].append(v)
counts=collections.defaultdict(collections.Counter);checks=[]
for p in db:
 x,y=p['location']['x'],p['location']['y'];gx,gy=math.floor(x/100),math.floor(y/100);near=[n for dx in [-1,0,1] for dy in [-1,0,1] for n in grid.get((gx+dx,gy+dy),[])];near=sorted(near,key=lambda n:math.hypot(n['location']['x']-x,n['location']['y']-y))
 if near:
  n=near[0];d=math.hypot(n['location']['x']-x,n['location']['y']-y)/100
  if d<1:counts[n['actorName']][p['type']]+=1;checks.append({'dbId':p['id'],'savedLocation':p['location'],'type':p['type'],'actorName':n['actorName'],'nativeId':n['id'],'distanceMeters':d})
result={'kind':selected,'pid':ctx['pid'],'startTime':ctx['startTime'],'capturedAt':startedAt,'completedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'map':region,'items':out,'matchedTypes':{k:dict(v) for k,v in counts.items()},'checks':checks,'componentCount':len(unique),'excludedComponentVtables':dict(excluded),'unstableArraysSkipped':len(records)-len(stable),'degenerateInstancesSkipped':degenerate};tmp=r/'native-gathering-instances.tmp';tmp.write_text(json.dumps(result,separators=(',',':')));tmp.replace(r/'native-gathering-instances.json');print(json.dumps({'instances':len(out),'checks':len(checks),'matchedTypes':result['matchedTypes']},indent=2),flush=True)
