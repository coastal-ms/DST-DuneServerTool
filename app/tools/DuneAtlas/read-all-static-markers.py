from pathlib import Path
import json,struct,importlib.util,math
r=Path(__file__).resolve().parent
sp=importlib.util.spec_from_file_location('m',r/'inspect-reflection.py');m=importlib.util.module_from_spec(sp);sp.loader.exec_module(m)
hits=json.loads((r/'static-marker-actor-cache.json').read_text())['actors'];rows=[{**v,'owner':v['address'],'ownerName':'DuneStaticMarkerActor'} for v in hits if v['type']=='_ZTV22ADuneStaticMarkerActor'];m.cache.clear();actors=m.read_many([(v['owner'],1248) for v in rows]);
for row,a in zip(rows,actors):row['root']=struct.unpack_from('<Q',a,568)[0];row['entityId']=str(struct.unpack_from('<q',a,200)[0])
m.cache.clear();roots=m.read_many([(v['root'],560) for v in rows]);assets=[v for v in hits if 'DataAsset' in v['type']];m.cache.clear();assetRaw=m.read_many([(v['address'],64) for v in assets]);indices=[struct.unpack_from('<I',b,o)[0] for b in actors for o in [892,1064,1072]]+[struct.unpack_from('<I',b,o)[0] for b in assetRaw for o in [24,56]];m.cache.clear();m.read_many([(m.blocks[b],131072) for b in set(i>>16 for i in indices)]);defaults={m.name(struct.unpack_from('<I',b,24)[0]):m.name(struct.unpack_from('<I',b,56)[0]) for b in assetRaw}
for row,a,b in zip(rows,actors,roots):
 config=m.name(struct.unpack_from('<I',a,1072)[0]);override=bool(a[888]);t=m.name(struct.unpack_from('<I',a,892)[0]) if override else defaults.get(config,'None');row.update({'type':t,'overrideType':override,'parent':struct.unpack_from('<Q',b,336)[0],'location':struct.unpack_from('<3d',b,456),'rotation':struct.unpack_from('<3d',b,480),'guid':a[1232:1248].hex(),'configPackage':m.name(struct.unpack_from('<I',a,1064)[0]),'configAsset':config})
(r/'native-static-marker-sites.json').write_text(json.dumps(rows,indent=2));import collections;print(collections.Counter(v['type'] for v in rows));print('attached',sum(bool(v['parent']) for v in rows));print('defaults',defaults)
