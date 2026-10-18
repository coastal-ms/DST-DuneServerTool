"""Bounded cold-start and restart recovery; only invokes read-only observers."""
import atlas_process
from pathlib import Path
import json,subprocess,sys,os,datetime,hashlib
import atlas_readers

def restore_cached_runtime(root):
 """Reuse compatible observer addresses; the fast reader revalidates the process.

 Never refresh timestamps here. A changed process must pass normal discovery.
 """
 root=Path(root)
 if root.parent.name!='runtimes':return {}
 result={}
 compatible=('inspect-reflection.py','worm-fast.py','snapshot-native.py','resource-field-id.py')
 try:manifest={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in compatible}
 except (OSError,ValueError,KeyError):return result
 candidates=sorted((p for p in root.parent.iterdir() if p.is_dir() and p!=root),key=lambda p:p.stat().st_mtime,reverse=True)[:32]
 for relative,key in (('', 'native'),('hagga','haggaNative')):
  target=root/relative
  try:
   current=json.loads((target/'runtime-context.json').read_text())
   if current.get('pid',0)>0:continue
   expected=current['sha256']
  except (OSError,ValueError,KeyError):continue
  choices=[]
  for candidate in candidates:
   folder=candidate/relative
   try:
    previous={name:hashlib.sha256((candidate/name).read_bytes()).hexdigest() for name in compatible}
    if any(not manifest.get(name) or previous.get(name)!=manifest[name] for name in compatible):continue
    paths={name:folder/name for name in ('runtime-context.json','native-hits-new.json','native-snapshot-current.json')}
    if any(path.stat().st_size>16777216 for path in paths.values()):continue
    context=json.loads(paths['runtime-context.json'].read_text());frame=json.loads(paths['native-snapshot-current.json'].read_text())
    if context.get('sha256')!=expected or context.get('pid',0)<=0 or frame.get('pid')!=context['pid'] or str(frame.get('startTime'))!=str(context.get('startTime')):continue
    if not isinstance(frame.get('systems'),list) or not isinstance(context.get('needles'),dict) or not context['needles']:continue
    captured=datetime.datetime.fromisoformat(frame['capturedAt'])
    age=(datetime.datetime.now(datetime.timezone.utc)-captured).total_seconds()
    if not 0<=age<=86400:continue
    json.loads(paths['native-hits-new.json'].read_text())
    choices.append((captured,paths,frame))
   except (OSError,ValueError,KeyError,TypeError):continue
  if not choices:continue
  _,paths,frame=max(choices,key=lambda value:value[0])
  import shutil
  for name,path in paths.items():shutil.copyfile(path,target/name)
  result[key]=frame
 return result

def execute(root,name,timeout):
 root=Path(root);script=root/name
 if not script.exists():script=root.parent/name
 env={**os.environ,'DST_ATLAS_WORLD_ROOT':str(root.resolve())}
 result=atlas_process.run([sys.executable,str(script)],cwd=root,env=env,capture_output=True,text=True,timeout=timeout,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
 return result.returncode==0

def collect_native(root,run=execute):
 root=Path(root)
 atlas_readers.ensure(root)
 if not run(root,'snapshot-native.py',120):
  if not run(root,'discover-runtime.py',80) or not run(root,'snapshot-native.py',120):
   raise RuntimeError('Native observation unavailable for this server build or process')
 value=json.loads((root/'native-snapshot-current.json').read_text())
 context=json.loads((root/'runtime-context.json').read_text())
 if value.get('pid')!=context.get('pid') or str(value.get('startTime'))!=str(context.get('startTime')):
  raise RuntimeError('Native observation belongs to another process')
 return value

def collect_pois(root,shared,run=execute):
 root=Path(root);shared=Path(shared)
 atlas_readers.ensure(shared)
 def observe():
  # The common bootstrap accepts the target map directory as its one argument.
  result=atlas_process.run([sys.executable,str(shared/'ensure-poi-discovery.py'),str(root)],cwd=root,capture_output=True,text=True,timeout=300,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
  return result.returncode==0 and run(root,'export-native-pois.py',80)
 if not observe():raise RuntimeError('Map point observation unavailable for this process')
