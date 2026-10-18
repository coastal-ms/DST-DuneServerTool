import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent if Path(__file__).resolve().parent.name=="hagga" else Path(__file__).resolve().parent))
import atlas_process
"""Exact bounded O_RDONLY memory reads through the existing guarded helper."""
from pathlib import Path
import json,struct,base64,subprocess,os
ROOT=Path(__file__).resolve().parent
class Reader:
 def __init__(self):self.context=json.loads((ROOT/'runtime-context.json').read_text());self.prefix='gathering-read-'+str(os.getpid())
 def read(self,requests):
  out=[]
  batches=[];batch=[];size=0
  for request in requests:
   if batch and (len(batch)>=4096 or size+request[1]>1048576):batches.append(batch);batch=[];size=0
   batch.append(request);size+=request[1]
  if batch:batches.append(batch)
  for batch in batches:
   for a,n in batch:
    if not 0x10000<a<0x800000000000 or not 0<n<=131072:raise ValueError('Invalid bounded memory read')
   body=base64.b64encode(b''.join(struct.pack('<2Q',a,n) for a,n in batch)).decode();ctx=self.context
   command=f'test "$(cut -d " " -f22 /proc/{int(ctx["pid"])}/stat)" = "{int(ctx["startTime"])}" || exit 73\nset -o pipefail; base64 -d | sudo nice -n 19 /var/lib/dst-atlas/readers/bulk /proc/{int(ctx["pid"])}/mem | base64'
   inp=ROOT/(self.prefix+'.b64');cmd=ROOT/(self.prefix+'.cmd');resultPath=ROOT/(self.prefix+'.txt');inp.write_text(body);cmd.write_text(command)
   result=atlas_process.run(['pwsh','-NoProfile','-File',str(ROOT/'remote.ps1'),'-CommandFile',str(cmd),'-OutputFile',str(resultPath),'-InputFile',str(inp)],capture_output=True,text=True,timeout=35)
   if result.returncode:raise RuntimeError('Guarded gathering read failed')
   payload=base64.b64decode(resultPath.read_text());pos=0
   for expected in batch:
    if pos+16>len(payload):raise ValueError('Truncated read result')
    a,n=struct.unpack_from('<2Q',payload,pos);pos+=16
    if (a,n)!=expected or pos+n>len(payload):raise ValueError('Unexpected read result')
    out.append(payload[pos:pos+n]);pos+=n
   if pos!=len(payload):raise ValueError('Trailing read data')
   for path in [inp,cmd,resultPath]:path.unlink(missing_ok=True)
  return out
