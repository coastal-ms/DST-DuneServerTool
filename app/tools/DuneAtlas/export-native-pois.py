from pathlib import Path
import json,struct,importlib.util,math
r=Path(__file__).resolve().parent
sp=importlib.util.spec_from_file_location('m',r/'inspect-reflection.py');m=importlib.util.module_from_spec(sp);sp.loader.exec_module(m)
region='HaggaBasin' if r.name=='hagga' else 'DeepDesert';origin,span=(-457200,812800) if region=='HaggaBasin' else (-1270000,2438400)
import datetime,collections,os
sites=json.loads((r/'native-static-marker-sites.json').read_text());surveys=[v for v in json.loads((r/'poi-actor-cache.json').read_text())['actors'] if v['type']=='_ZTV20AFogOfWarSurveyPoint'];m.cache.clear();surveyHeads=m.read_many([(v['address'],576) for v in surveys]);
for v,raw in zip(surveys,surveyHeads):v['root']=struct.unpack_from('<Q',raw,568)[0]
m.cache.clear(); identities=m.read_many([(v.get('owner',v.get('address')),576) for v in sites+surveys])
for v,raw in zip(sites+surveys,identities):
 if struct.unpack_from('<Q',raw,568)[0]!=v['root'] or struct.unpack_from('<Q',raw)[0]!=v['vtable'] or struct.unpack_from('<I',raw,8)[0]&0x18030:raise ValueError('Static actor identity changed')
roots={v['root'] for v in sites+surveys};components={};todo=roots
for depth in range(16):
 if not todo:break
 m.cache.clear();raws=m.read_many([(ptr,560) for ptr in todo]);new=set()
 for ptr,raw in zip(todo,raws):
  parent=struct.unpack_from('<Q',raw,336)[0];components[ptr]={'parent':parent,'p':struct.unpack_from('<3d',raw,456),'r':struct.unpack_from('<3d',raw,480),'s':struct.unpack_from('<3d',raw,504),'absolute':raw[552]}
  if parent and parent not in components:new.add(parent)
 todo=new
else:raise ValueError('Attachment depth exceeds bound')
def qrot(q,v):
 x,y,z,w=q;vx,vy,vz=v;tx=2*(y*vz-z*vy);ty=2*(z*vx-x*vz);tz=2*(x*vy-y*vx);return (vx+w*tx+y*tz-z*ty,vy+w*ty+z*tx-x*tz,vz+w*tz+x*ty-y*tx)
def quat(r):
 pitch,yaw,roll=[math.radians(a)/2 for a in r];sp,cp=math.sin(pitch),math.cos(pitch);sy,cy=math.sin(yaw),math.cos(yaw);sr,cr=math.sin(roll),math.cos(roll);return(cr*sp*sy-sr*cp*cy,-cr*sp*cy-sr*cp*sy,cr*cp*sy-sr*sp*cy,cr*cp*cy+sr*sp*sy)
def mul(a,b):
 x,y,z,w=a;X,Y,Z,W=b;return(w*X+x*W+y*Z-z*Y,w*Y-x*Z+y*W+z*X,w*Z+x*Y-y*X+z*W,w*W-x*X-y*Y-z*Z)
worlds={}
def world(ptr,seen=()):
 if ptr in worlds:return worlds[ptr]
 if ptr in seen:raise ValueError('Attachment cycle')
 c=components[ptr];p,q,s=c['p'],quat(c['r']),c['s']
 if c['parent']:
  pp,pq,ps=world(c['parent'],seen+(ptr,))
  if not c['absolute']&4:p=tuple(a+b for a,b in zip(pp,qrot(pq,tuple(a*b for a,b in zip(p,ps)))))
  if not c['absolute']&8:q=mul(pq,q)
  if not c['absolute']&16:s=tuple(a*b for a,b in zip(s,ps))
 worlds[ptr]=(p,q,s);return worlds[ptr]
nameSpec=importlib.util.spec_from_file_location('poi_names',(r.parent if r.name=='hagga' else r)/'read-poi-names.py');nameReader=importlib.util.module_from_spec(nameSpec);nameSpec.loader.exec_module(nameReader)
try:resolvedNames=nameReader.read_names(m,sites);namesError=None
except Exception as e:resolvedNames={};namesError=str(e)
items=[]
for v in sites:
 t=v['type']
 if t=='None':continue
 p=world(v['root'])[0]
 if not all(math.isfinite(n) for n in p) or not all(origin<=n<=origin+span for n in p[:2]):continue
 items.append({'id':'native:'+v['entityId'],'map':region,'type':t,'location':dict(zip(['x','y','z'],p)),'source':'server actor','survey':False,**resolvedNames.get(str(v['entityId']),{})})
for v in surveys:
 p=world(v['root'])[0]
 if not all(math.isfinite(n) for n in p) or not all(origin<=n<=origin+span for n in p[:2]):continue
 items.append({'id':'survey:'+str(v['address']),'map':region,'type':'SurveyPoint','location':dict(zip(['x','y','z'],p)),'source':'server actor attachment transform','survey':True})
wreckSpec=importlib.util.spec_from_file_location('wreck_sites',r/'wreck-sites.py');wrecks=importlib.util.module_from_spec(wreckSpec);wreckSpec.loader.exec_module(wrecks)
try:items.extend(wrecks.read_sites(r,m,region,origin,span));wreckError=None
except Exception as e:wreckError=str(e)
out={'pid':m.PID,'startTime':m.context['startTime'],'capturedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'items':items,'wreckError':wreckError,'namesError':namesError};tmp=r/('native-pois-current.'+str(os.getpid())+'.tmp');tmp.write_text(json.dumps(out,indent=2));tmp.replace(r/'native-pois-current.json');print(collections.Counter(v['type'] for v in items))
