import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent if Path(__file__).resolve().parent.name=="hagga" else Path(__file__).resolve().parent))
import atlas_process
"""Rebuild process-bound POI discovery on a fresh runtime or process change."""
from pathlib import Path
import json,subprocess,sys,hashlib,os,re

STAGES=('find-poi-actors.py','find-static-marker-actors.py','read-all-static-markers.py')
FILES=('poi-actor-cache.json','static-marker-actor-cache.json','native-static-marker-sites.json')

def digests(root):return {name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in FILES}

def context(root):
 value=json.loads((root/'runtime-context.json').read_text(encoding='utf-8-sig'))
 if not isinstance(value.get('pid'),int) or value['pid']<=0 or not str(value.get('startTime','')).isdigit() or not re.fullmatch('[0-9a-f]{64}',str(value.get('sha256',''))):
  raise ValueError('Waiting for a verified runtime identity')
 return value

def identity(value):return value['pid'],str(value['startTime']),value.get('sha256')

def cache_ready(root,expected):
 try:
  ready=json.loads((root/'poi-discovery-ready.json').read_text())
  if tuple(ready.get('identity',[]))!=expected or ready.get('files')!=digests(root):return False
  for name in ('poi-actor-cache.json','static-marker-actor-cache.json'):
   value=json.loads((root/name).read_text(encoding='utf-8-sig'))
   if (value.get('pid'),str(value.get('startTime')))!=expected[:2] or not isinstance(value.get('actors'),list):return False
  return isinstance(json.loads((root/'native-static-marker-sites.json').read_text(encoding='utf-8-sig')),list)
 except (OSError,ValueError,KeyError):return False

def ensure(root,run=None):
 root=Path(root).resolve();expected=identity(context(root))
 if cache_ready(root,expected):return {'rebuilt':False,'pid':expected[0]}
 def execute(name):
  result=atlas_process.run([sys.executable,str(root/name)],cwd=root,capture_output=True,text=True,timeout=90,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
  if result.returncode:raise RuntimeError('Map point discovery unavailable at '+name)
 runner=run or execute
 for name in STAGES:
  if identity(context(root))!=expected:raise ValueError('Runtime changed during map point discovery')
  runner(name)
  if identity(context(root))!=expected:raise ValueError('Runtime changed during map point discovery')
 manifest={'identity':list(expected),'files':digests(root)}
 temp=root/('poi-discovery-ready.'+str(os.getpid())+'.tmp');temp.write_text(json.dumps(manifest));temp.replace(root/'poi-discovery-ready.json')
 if not cache_ready(root,expected):raise ValueError('Discovery did not produce matching process-bound map points')
 return {'rebuilt':True,'pid':expected[0]}

if __name__=='__main__':print(json.dumps(ensure(Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).parent)))
