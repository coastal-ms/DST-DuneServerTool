"""Resolve verified native static-marker string-table keys against installed game names."""
from pathlib import Path
import json,struct
ROOT=Path(__file__).resolve().parent

def read_names(reader,sites):
    names=json.loads((ROOT/'poi-world-names.json').read_text())
    def pointer(p):return 0x10000<p<0x800000000000
    sources=[s for s in sites if s.get('ownerName')=='DuneStaticMarkerActor']
    actors=reader.read_many([(s['owner'],880) for s in sources])
    data=[]
    for site,head in zip(sources,actors):
        if struct.unpack_from('<Q',head)[0]!=site['vtable'] or struct.unpack_from('<I',head,8)[0]&0x18030:continue
        p=struct.unpack_from('<Q',head,856)[0]
        if pointer(p):data.append((site,p))
    blocks=reader.read_many([(p,32) for site,p in data]);entries=[]
    for (site,p),b in zip(data,blocks):
        entry=struct.unpack_from('<Q',b,16)[0]
        if pointer(entry):entries.append((site,entry))
    blocks=reader.read_many([(p,40) for site,p in entries]);keys=[]
    for (site,p),b in zip(entries,blocks):
        index=struct.unpack_from('<I',b,16)[0];key=struct.unpack_from('<Q',b,24)[0]
        if not pointer(key) or index>>16>=len(reader.blocks):continue
        if reader.name(index) not in ['ST_Localization_NPCs_World','/Game/Dune/Localization/ST_Localization_NPCs_World.ST_Localization_NPCs_World']:continue
        keys.append((site,key))
    texts=reader.read_many([(p,512) for site,p in keys]);out={}
    for (site,p),b in zip(keys,texts):
        key=b.decode('utf-16-le',errors='replace').split('\0',1)[0]
        if key in names and names[key].strip():out[str(site['entityId'])]={'displayName':names[key],'nameKey':key}
    return out
