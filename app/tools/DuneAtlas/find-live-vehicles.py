import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent if Path(__file__).resolve().parent.name=="hagga" else Path(__file__).resolve().parent))
import atlas_builds
import atlas_process
import os
"""Discover event actors from fresh process mappings, read only and build guarded."""
from pathlib import Path
import json,struct,base64,re,subprocess,datetime
R=Path(os.environ.get('DST_ATLAS_WORLD_ROOT',str(Path(__file__).resolve().parent)));c=json.loads((R/'runtime-context.json').read_text());pid=int(c['pid']);start=int(c['startTime'])
def remote(command,output,input=None):
 (R/'vehicle-discovery.cmd').write_text(command)
 args=['pwsh','-NoProfile','-File',str(R/'remote.ps1'),'-CommandFile',str(R/'vehicle-discovery.cmd'),'-OutputFile',str(R/output)]
 if input:args+=['-InputFile',str(R/input)]
 result=atlas_process.run(args,capture_output=True,text=True,timeout=35)
 if result.returncode:raise RuntimeError('Event discovery failed: '+result.stderr[-300:])
 return (R/output).read_text()
guard=f'test "$(cut -d " " -f22 /proc/{pid}/stat)" = "{start}" || exit 73\n'
layout=remote(guard+f'sudo cat /proc/{pid}/maps','vehicle-process-layout.txt');syms=atlas_builds.symbol_rows(R,c['sha256'],'all-native-vtables.json');names=['_ZTV16ADuneOrnithopter','_ZTV20ADuneSandbikeVehicle','_ZTV19ADuneWheeledVehicle','_ZTV21ADuneContainerVehicle'];needles=[c['exeBase']+next(s['value'] for s in syms if s['name']==n)+16 for n in names];records=[]
for line in layout.splitlines():
 match=re.match(r'([0-9a-f]+)-([0-9a-f]+) rw.p .*',line)
 if not match or '/home/dune/server/' in line:continue
 a,b=[int(x,16) for x in match.groups()]
 for p in range(a,b,8388608):records.append(struct.pack('<6Q',p,min(8388608,b-p),*needles))
(R/'vehicle-discovery-input.b64').write_text(base64.b64encode(b''.join(records)).decode())
raw=remote(guard+f'set -o pipefail; base64 -d | sudo nice -n 19 /var/lib/dst-atlas/readers/scan /proc/{pid}/mem 2>/tmp/dst-map-event-stats-01a148d9 | base64','vehicle-discovery-output.b64','vehicle-discovery-input.b64');payload=base64.b64decode(raw);off=0;actors=[];types=dict(zip(needles,names))
while off<len(payload):
 a,t,n=struct.unpack_from('<3Q',payload,off);off+=24;obj=payload[off:off+n];off+=n
 if n!=512:raise ValueError('Unexpected event discovery record')
 flags=struct.unpack_from('<I',obj,8)[0]
 if flags&48:continue
 actors.append({'address':a,'type':types[t],'vtable':t,'flags':flags})
value={'pid':pid,'startTime':str(start),'capturedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'actors':actors};temp=R/'vehicle-actor-cache.tmp';temp.write_text(json.dumps(value,indent=2));temp.replace(R/'vehicle-actor-cache.json');print(json.dumps({'pid':pid,'actors':[{k:v for k,v in x.items() if k not in ['address','vtable']} for x in actors]}))
