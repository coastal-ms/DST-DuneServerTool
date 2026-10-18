from pathlib import Path
import json,base64,re,struct,subprocess,os,sys
try:import atlas_process
except ModuleNotFoundError:
    sys.path.insert(0,str(Path(__file__).resolve().parent.parent));import atlas_process
ROOT=Path(__file__).resolve().parent
READ_PREFIX='read-memory-'+str(os.getpid())
context=json.loads((ROOT/'runtime-context.json').read_text())
PID=int(context['pid'])
cache={}
def read_many(requests):
    for a,n in requests:
        if (a,n) in cache:continue
        for (base,size),data in list(cache.items()):
            if base<=a and a+n<=base+size:
                cache[(a,n)]=data[a-base:a-base+n];break
    expanded={}
    for a,n in requests:
        if (a,n) not in cache and n>=64 and (a%4096 or n%4096):
            base=a&~4095;expanded[(a,n)]=(base,((a-base+n+4095)//4096)*4096)
    if expanded:
        read_many(list(dict.fromkeys(expanded.values())))
        for (a,n),(base,size) in expanded.items():cache[(a,n)]=cache[(base,size)][a-base:a-base+n]
    todo=[(a,n) for a,n in requests if (a,n) not in cache]
    if todo:
        for a,n in todo:
            if not(0x10000<a<0x800000000000 and 0<n<=131072):raise ValueError('Invalid bounded read')
        body=base64.b64encode(b''.join(struct.pack('<2Q',a,n) for a,n in todo)).decode()
        command=f'set -o pipefail; base64 -d | sudo nice -n 19 /var/lib/dst-atlas/readers/bulk /proc/{PID}/mem | base64'
        if context.get('startTime'):
            command=f'test "$(cut -d " " -f22 /proc/{PID}/stat)" = "{int(context["startTime"])}" || exit 73\n'+command
        (ROOT/(READ_PREFIX+'-input.b64')).write_text(body)
        (ROOT/(READ_PREFIX+'.cmd')).write_text(command)
        result=atlas_process.run(['pwsh','-NoProfile','-File',str(ROOT/'remote.ps1'),'-CommandFile',str(ROOT/(READ_PREFIX+'.cmd')),'-OutputFile',str(ROOT/(READ_PREFIX+'.txt')),'-InputFile',str(ROOT/(READ_PREFIX+'-input.b64'))],capture_output=True,text=True,timeout=35)
        if result.returncode:raise RuntimeError(result.stderr)
        payload=base64.b64decode((ROOT/(READ_PREFIX+'.txt')).read_text());offset=0
        for expected_a,expected_n in todo:
            if offset+16>len(payload):raise ValueError('Missing bounded read header')
            a,n=struct.unpack_from('<2Q',payload,offset);offset+=16
            if (a,n)!=(expected_a,expected_n) or offset+n>len(payload):raise ValueError('Unexpected bounded read record')
            cache[(a,n)]=payload[offset:offset+n];offset+=n
        if offset!=len(payload):raise ValueError('Unexpected trailing read bytes')
        for suffix in ['-input.b64','.cmd','.txt']:(ROOT/(READ_PREFIX+suffix)).unlink(missing_ok=True)
    return [cache[(a,n)] for a,n in requests]

if context.get('namePoolTable'):
    pool=read_many([(int(context['namePoolTable'])-16,2048)])[0]
else:
    head=json.loads((ROOT/'reflection-head.json').read_text())
    pool=bytes.fromhex(head[str(0x5569134d3d18)])
blocks=struct.unpack_from('<254Q',pool,16)
def name(index):
    block=index>>16;offset=(index&65535)*2
    raw=read_many([(blocks[block],131072)])[0]
    header=struct.unpack_from('<H',raw,offset)[0];length=header>>6;wide=header&1
    return raw[offset+2:offset+2+length*(2 if wide else 1)].decode('utf-16-le' if wide else 'utf-8',errors='replace')

if __name__=='__main__':
    chains={'SandStormManager':0x7f7f1891ef80,'ResourceFieldSubsystem':0x7f7f4d2c7840}
    rows=[]
    for kind,ptr in chains.items():
        visited=set()
        while ptr and len(visited)<100:
            if ptr in visited:raise ValueError('Cyclic property list')
            visited.add(ptr);raw=read_many([(ptr,128)])[0]
            nxt=struct.unpack_from('<Q',raw,32)[0];index=struct.unpack_from('<I',raw,40)[0]
            field={'class':kind,'field':name(index),'offset':struct.unpack_from('<i',raw,76)[0],'size':struct.unpack_from('<i',raw,56)[0],'arrayDim':struct.unpack_from('<i',raw,52)[0],'address':ptr,'raw':raw.hex()}
            rows.append(field);print(kind,field['field'],hex(field['offset']),field['size'],flush=True);ptr=nxt
    (ROOT/'reflected-properties.json').write_text(json.dumps(rows,indent=2))
