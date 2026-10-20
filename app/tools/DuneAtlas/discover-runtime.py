import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent if Path(__file__).resolve().parent.name=="hagga" else Path(__file__).resolve().parent))
import atlas_builds
import atlas_process
from pathlib import Path
import subprocess,json,re,struct,base64,importlib.util
R=Path(__file__).resolve().parent
def remote(command,output,input=None):
 cmd=R/'discovery-command.sh';cmd.write_text(command,encoding='utf-8')
 args=['pwsh','-NoProfile','-File',str(R/'remote.ps1'),'-CommandFile',str(cmd),'-OutputFile',str(R/output)]
 if input:args+=['-InputFile',str(R/input)]
 result=atlas_process.run(args,capture_output=True,text=True,timeout=35)
 if result.returncode:raise RuntimeError('Read-only runtime discovery failed: '+result.stderr[-500:])
 return (R/output).read_text()
layout=remote('''for d in /proc/[0-9]*; do
 test -r "$d/cmdline" || continue
 sudo readlink "$d/exe" 2>/dev/null | grep -q DuneSandboxServer || continue
 sudo tr '\\0' '\\n' < "$d/cmdline" | grep -q DeepDesert_1 || continue
 echo PID ${d##*/}; echo START $(cut -d ' ' -f22 "$d/stat"); sudo sha256sum "$d/exe"; sudo cat "$d/maps"; break
done
''','discovered-layout.txt')
identity=re.search(r'^PID (\d+)',layout,re.M)
if not identity:raise RuntimeError('Deep Desert server is not running yet')
pid=int(identity[1]);start=re.search(r'^START (\d+)',layout,re.M)[1]
digest=re.search(r'^([0-9a-f]{64})\s+',layout,re.M)
if not digest:raise RuntimeError('Server executable identity unavailable')
base=int(next(line.split('-')[0] for line in layout.splitlines() if '/home/dune/server/' in line and ' r-xp ' in line),16)
build=atlas_builds.profile(R,digest[1],runtime={'pid':pid,'started':start,'base':base,'maps':layout,'remote':remote});EXPECTED=digest[1]
pooloffset=build['namePoolTableOffset']
syms=build['symbols'];names=['_ZTV17USandStormManager','_ZTV18USandwormSubsystem','_ZTV23UResourceFieldSubsystem','_ZTV13ASandwormPawn','_ZTV18USandStormSettings'];needles={n:base+syms[n]+16 for n in names};records=[]
for line in layout.splitlines():
 match=re.match(r'([0-9a-f]+)-([0-9a-f]+) rw.p .*',line)
 if not match or '/home/dune/server/' in line:continue
 a,b=[int(x,16) for x in match.groups()]
 for p in range(a,b,8388608):records.append(struct.pack('<6Q',p,min(8388608,b-p),*[v for k,v in needles.items() if k!='_ZTV13ASandwormPawn']))
(R/'discovery-scan.b64').write_text(base64.b64encode(b''.join(records)).decode())
raw=remote(f'''test "$(cut -d ' ' -f22 /proc/{pid}/stat)" = "{start}" || exit 73
set -o pipefail; base64 -d | sudo nice -n 19 /var/lib/dst-atlas/readers/scan /proc/{pid}/mem 2>/tmp/dst-map-discovery-stats-01a148d9 | base64
''','discovery-hits.b64','discovery-scan.b64')
context={'pid':pid,'startTime':start,'exeBase':base,'sha256':EXPECTED,'namePoolTable':base+pooloffset,'needles':needles}
# The class/name validation in each snapshot fails closed if this build profile differs.
tmp=R/'runtime-context.tmp';tmp.write_text(json.dumps(context,indent=2));tmp.replace(R/'runtime-context.json')
data=base64.b64decode(raw);off=0;hits=[];types={v:k for k,v in needles.items()}
while off<len(data):
 a,t,n=struct.unpack_from('<3Q',data,off);off+=24;obj=data[off:off+n];off+=n
 if n!=512:raise ValueError('Unexpected native reader record')
 hits.append({'address':a,'type':types[t],'flags':struct.unpack_from('<I',obj,8)[0],'data':obj.hex()})
tmp=R/'native-hits-new.tmp';tmp.write_text(json.dumps(hits,indent=2));tmp.replace(R/'native-hits-new.json')
print(json.dumps({'pid':pid,'candidates':len(hits),'buildVerified':True}))
