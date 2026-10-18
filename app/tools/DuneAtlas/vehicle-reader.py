import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent if Path(__file__).resolve().parent.name=="hagga" else Path(__file__).resolve().parent))
import atlas_process
import sys,os
"""Read-only native vehicle positions, linked by reflected Actor.EntityId to DB entity IDs."""
from pathlib import Path
import json,struct,subprocess,datetime,math
R=Path(__file__).resolve().parent

def read_vehicles(m):
 R=m.ROOT
 p=R/'vehicle-actor-cache.json'
 try:cache=json.loads(p.read_text())
 except (FileNotFoundError,ValueError):cache={}
 age=(datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(cache['capturedAt'])).total_seconds() if cache.get('capturedAt') else 1e9
 if cache.get('pid')!=m.PID or cache.get('startTime')!=m.context['startTime'] or age>120:
  result=atlas_process.run([sys.executable,str(Path(__file__).resolve().parent/'find-live-vehicles.py')],env={**os.environ,'DST_ATLAS_WORLD_ROOT':str(R)},capture_output=True,text=True,timeout=45)
  if result.returncode:raise ValueError('Native vehicle discovery unavailable')
  cache=json.loads(p.read_text())
 if cache['pid']!=m.PID or cache['startTime']!=m.context['startTime']:raise ValueError('Vehicle process identity changed')
 actors=cache['actors'];raw=m.read_many([(a['address'],576) for a in actors]);items=[]
 for a,o in zip(actors,raw):
  if struct.unpack_from('<Q',o)[0]!=a['vtable'] or struct.unpack_from('<I',o,8)[0]&0x18030:continue
  root=struct.unpack_from('<Q',o,568)[0]
  if root:items.append({**a,'entityId':str(struct.unpack_from('<q',o,200)[0]),'root':root})
 roots=m.read_many([(p['root'],544) for p in items]);valid=[]
 for p,o in zip(items,roots):
  location=struct.unpack_from('<3d',o,456)
  if struct.unpack_from('<Q',o,336)[0] or not all(math.isfinite(v) and abs(v)<1e8 for v in location):continue
  p['location']=location;valid.append(p)
 return valid
