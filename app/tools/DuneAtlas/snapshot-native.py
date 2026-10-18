"""Build-guarded, read-only native observations. Related reads are batched."""
from pathlib import Path
import importlib.util,json,struct,datetime,math,os
shared=Path(__file__).resolve().parent
r=Path(os.environ.get('DST_ATLAS_WORLD_ROOT',str(shared)))
field_spec=importlib.util.spec_from_file_location('field_identity',shared/'resource-field-id.py');field_identity=importlib.util.module_from_spec(field_spec);field_spec.loader.exec_module(field_identity)
spec=importlib.util.spec_from_file_location('reflection',r/'inspect-reflection.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
def stamp():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def prefetch_names(indexes):
 blocks={i>>16 for i in indexes}
 if any(b>=len(m.blocks) or not m.blocks[b] for b in blocks):raise ValueError('Invalid name block')
 m.read_many([(m.blocks[b],131072) for b in blocks])
def u32(data,offset):return struct.unpack_from('<I',data,offset)[0]
def u64(data,offset):return struct.unpack_from('<Q',data,offset)[0]
def vec(data,offset):
 value=struct.unpack_from('<3d',data,offset)
 if not all(math.isfinite(v) and abs(v)<1e8 for v in value):raise ValueError('Invalid world location')
 return value
result={'startedAt':stamp(),'pid':m.PID,'startTime':m.context['startTime'],'systems':[],'stormManagers':[],'stormSchedule':None}
if '_ZTV18USandStormSettings' not in m.context['needles']:raise ValueError('Storm settings profile needs discovery')
allowed={'_ZTV18USandStormSettings':'SandStormSettings','_ZTV23UResourceFieldSubsystem':'ResourceFieldSubsystem','_ZTV18USandwormSubsystem':'SandwormSubsystem','_ZTV17USandStormManager':'SandStormManager'}
hits=[h for h in json.loads((r/'native-hits-new.json').read_text()) if h['type'] in allowed and not h['flags']&0x18000 and (h['type']=='_ZTV18USandStormSettings' or not h['flags']&48)]
heads=m.read_many([(h['address'],688 if h['type']=='_ZTV17USandStormManager' else 128 if h['type']=='_ZTV18USandStormSettings' else 320) for h in hits]);prefetch_names([u32(b,24) for b in heads]);resources=None;worm=None
for hit,head in zip(hits,heads):
 kind=hit['type'];p=hit['address']
 if u64(head,0)!=m.context['needles'][kind] or u32(head,8)&(0x18000 if kind=='_ZTV18USandStormSettings' else 48):raise ValueError('Native object identity changed')
 name=m.name(u32(head,24))
 if kind=='_ZTV18USandStormSettings':
  if name!=('DA_SandstormSettings_HaggaBasin' if r.name=='hagga' else 'DA_SandstormSettings_DeepDesert'):continue
  minimum,maximum=struct.unpack_from('<2i',head,112)
  if head[48] not in (0,1) or not 0<minimum<=maximum<=2592000:continue
  schedule={'enabled':bool(head[48]),'minimumSeconds':minimum,'maximumSeconds':maximum}
  if result['stormSchedule'] is not None and result['stormSchedule']!=schedule:raise ValueError('Storm schedule settings disagree')
  result['stormSchedule']=schedule
  continue
 if name!=allowed[kind]:raise ValueError('Native name validation failed')
 row={'type':kind,'address':p,'name':name}
 if name=='SandStormManager':
  row.update(routeId=str(u64(head,456)),reportedLifetime=struct.unpack_from('<f',head,464)[0],start=vec(head,472),finish=vec(head,496));result['stormManagers'].append(row)
 elif name=='ResourceFieldSubsystem':
  ptr,num,cap=struct.unpack_from('<Qii',head,48)
  if not 0<=num<=cap<=100:raise ValueError('Invalid resource map count')
  row.update(begunPlay=head[156],finishedDbLoad=head[157],groups=[]);resources=(row,ptr,num,int.from_bytes(head[64:80],'little'));result['systems'].append(row)
 else:
  ptr,num,cap=struct.unpack_from('<Qii',head,48)
  if not 0<=num<=cap<=1000:raise ValueError('Invalid worm territory count')
  row.update(territories={'pointer':ptr,'count':num,'capacity':cap},worms=[]);worm=(row,ptr,num);result['systems'].append(row)
requests=[]
if resources and resources[2]:requests.append((resources[1],resources[2]*56))
if worm and worm[2]:requests.append((worm[1],worm[2]*8))
m.read_many(requests)
groups=[];territory_ptrs=[]
if resources and resources[2]:
 row,ptr,num,bits=resources;data=m.cache[(ptr,num*56)]
 for i in range(num):
  if not bits>>i&1:continue
  config,fields,n,cap=struct.unpack_from('<QQii',data,i*56)
  if not 0<=n<=cap<=10000:raise ValueError('Invalid resource field array')
  groups.append({'config':config,'fields':fields,'count':n,'activeCount':struct.unpack_from('<i',data,i*56+24)[0]})
if sum(g['count'] for g in groups)>20000:raise ValueError('Resource observation limit')
if worm and worm[2]:territory_ptrs=list(struct.unpack('<'+'Q'*worm[2],m.cache[(worm[1],worm[2]*8)]))
requests=[(g['config'],64) for g in groups]+[(g['fields'],g['count']*8) for g in groups if g['count']]+[(a,1264) for a in territory_ptrs]
m.read_many(requests);prefetch_names([u32(m.cache[(g['config'],64)],24) for g in groups])
objects=[];pawns=[]
for group in groups:
 group['configName']=m.name(u32(m.cache[(group['config'],64)],24));pointers=struct.unpack('<'+'Q'*group['count'],m.cache[(group['fields'],group['count']*8)]) if group['count'] else []
 for p in pointers:objects.append((group,p))
for a in territory_ptrs:
 pawn=u64(m.cache[(a,1264)],848)
 if pawn:pawns.append((a,pawn))
m.read_many([(p,1632) for g,p in objects]+[(p,2080) for a,p in pawns]);active=[];live_pawns=[]
for group,p in objects:
 data=m.cache[(p,1632)]
 active.append((group,{'isActive':bool(data[1248]),'address':p,'nameIndex':u32(data,24),'root':u64(data,1064),'spawnTicks':struct.unpack_from('<q',data,1256)[0],'totalValue':struct.unpack_from('<i',data,1456)[0]}))
for territory,pawn in pawns:
 data=m.cache[(pawn,2080)]
 if u64(data,0)!=m.context['needles']['_ZTV13ASandwormPawn'] or u32(data,8)&48:raise ValueError('Worm pawn type changed')
 root=u64(data,568)
 if root:live_pawns.append({'territory':territory,'pawn':pawn,'root':root,'id':struct.unpack_from('<i',data,1024)[0],'hibernated':bool(data[1874]),'hidden':bool(data[1876]),'animationState':data[2057]})
root_requests=[(p['root'],544) for g,p in active]+[(p['root'],544) for p in live_pawns];m.read_many(root_requests);prefetch_names([p['nameIndex'] for g,p in active])
for group in groups:group['active']=[]
for group,p in active:
 data=m.cache[(p['root'],544)];p.update(name=m.name(p.pop('nameIndex')),parent=u64(data,336),location=vec(data,456))
 p['savedFieldId']=field_identity.field_id(p['location'])
 # SaveDirtyFields persists this counter as value_remaining; 42 native/DB
 # matches include harvested 139290/150000 and 40/5000 fields.
 remaining=struct.unpack_from('<i',m.cache[(p['address'],1632)],1484)[0]
 p['remainingValue']=remaining if 0<=remaining<=p['totalValue'] else None
 if p['isActive']:group['active'].append(p)
 # Dormant field actors can still have a persisted live resource field.
 # Keep their coordinates for an exact map/field-ID join with the current DB.
 group.setdefault('referenceFields',[]).append(p)
if resources:resources[0]['groups']=[{k:v for k,v in g.items() if k!='fields'} for g in groups]
for p in live_pawns:
 data=m.cache[(p['root'],544)];p.update(parent=u64(data,336),location=vec(data,456));worm[0]['worms'].append(p)
storm_spec=importlib.util.spec_from_file_location('storm_reader',shared/'storm-reader.py');storm_module=importlib.util.module_from_spec(storm_spec);storm_spec.loader.exec_module(storm_module);result['storms']=storm_module.read_storms(m,result['stormManagers'])
if result.get('stormSchedule'):
 from atlas_storm_timing import read_anchor
 try:result['stormSchedule'].update(read_anchor(m,result['stormManagers'],'HaggaBasin' if r.name=='hagga' else 'DeepDesert'))
 except (OSError,ValueError,TypeError):pass
result['capturedAt']=stamp()
try:
 vehicle_spec=importlib.util.spec_from_file_location('vehicle_reader',shared/'vehicle-reader.py');vehicle_module=importlib.util.module_from_spec(vehicle_spec);vehicle_spec.loader.exec_module(vehicle_module);result['vehicles']=vehicle_module.read_vehicles(m);result['vehicleError']=None
except Exception as e:result['vehicles']=[];result['vehicleError']=str(e)
result['capturedAt']=stamp()
history_file=r/'storm-route-observations.json';history=json.loads(history_file.read_text()) if history_file.exists() else []
for manager in result['stormManagers']:
 if manager['routeId']=='0':continue
 key=str(m.PID)+':'+m.context['startTime']+':'+manager['routeId'];entry=next((e for e in history if e['key']==key),None)
 if entry is None:
  entry={'key':key,'firstObservedAt':result['capturedAt'],'timingVerified':False,'start':manager['start'],'finish':manager['finish'],'routeId':manager['routeId']};history.append(entry)
 entry['lastObservedAt']=result['capturedAt'];entry['reportedLifetime']=manager['reportedLifetime']
history_file.write_text(json.dumps(history[-200:],indent=2));temp=r/'native-snapshot-current.tmp';temp.write_text(json.dumps(result,indent=2));temp.replace(r/'native-snapshot-current.json')
print(json.dumps({'pid':m.PID,'durationSeconds':(datetime.datetime.fromisoformat(result['capturedAt'])-datetime.datetime.fromisoformat(result['startedAt'])).total_seconds(),'resources':sum(len(g['active']) for g in groups),'worms':len(live_pawns),'storms':len(result['storms'])}))
