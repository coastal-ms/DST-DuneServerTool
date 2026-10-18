import importlib.util
from pathlib import Path
import json,math,hashlib,re,shutil,collections,datetime,os
r=Path(__file__).resolve().parent;saved_spec=importlib.util.spec_from_file_location('saved_pois',(r.parent if r.name=='hagga' else r)/'saved-pois.py');saved_pois=importlib.util.module_from_spec(saved_spec);saved_spec.loader.exec_module(saved_pois);region='HaggaBasin' if r.name=='hagga' else 'DeepDesert';origin,span=(-457200,812800) if region=='HaggaBasin' else (-1270000,2438400);source=json.loads((r/'native-gathering-instances.json').read_text());ctx=json.loads((r/'runtime-context.json').read_text())
if source['pid']!=ctx['pid'] or str(source['startTime'])!=str(ctx['startTime']):raise ValueError('Gathering capture belongs to another process')
def classify(name):
 pickup='_Pickup' in name
 for family,ore in [('Stravidium','StravidiumOre'),('Titanium','TitaniumOre'),('Azurite','AzuriteOre'),('Bauxite','BauxiteOre'),('Basalt','BasaltOre'),('Rhyolite','RhyoliteOre'),('Magnetite','MagnetiteOre'),('Dolomite','DolomiteRock'),('Erythrite','ErythriteOre')]:
  if family in name:return family+'Pickup' if pickup else ore
 if 'ScrapMetal' in name or 'ScrapElectronics' in name:return 'ScrapMetalPart' if pickup else 'ScrapMetalWreckage'
 if 'ImpureFuel' in name:return 'FuelCellPart' if pickup else 'FuelCellWreckage'
 if 'Jasmium' in name:return 'JasmiumPickup' if pickup else 'JasmiumOre'
 if 'SietchStone' in name:return 'SietchStone'
 if 'Saguaro' in name:return 'SaguaroPlant'
 if 'BurroBush' in name:return 'BrittleBush'
 if 'Primrose' in name:return 'PrimroseField'
 if 'Cistanche' in name:return 'CistanchePlant'
 return None
groups=collections.defaultdict(list);unknown=collections.Counter();seen=set()
for p in source['items']:
 t=classify(p['actorName']);loc=p['location'];xyz=[loc[k] for k in ['x','y','z']]
 if not t:unknown[p['actorName']]+=1;continue
 if not all(math.isfinite(n) for n in xyz) or not all(origin<=n<=origin+span for n in xyz[:2]):raise ValueError('Invalid gathering coordinate')
 key=(t,round(xyz[0],2),round(xyz[1],2),round(xyz[2],2))
 if key in seen:continue
 seen.add(key);groups[t].append([p['id'],*xyz])
nativeById={v['id']:v for v in source['items']};savedById={v['id']:v for v in saved_pois.read_saved(r) if v['map']==region}
for c in source['checks']:
 n=nativeById[c['nativeId']]['location'];p=c.get('savedLocation') or savedById[c['dbId']]['location'];c['distance3dMeters']=math.dist([n[k] for k in ['x','y','z']],[p[k] for k in ['x','y','z']])/100
conflicts=[c for c in source['checks'] if c['distance3dMeters']<.02 and classify(c['actorName'])!=c['type']]
if conflicts:raise ValueError('Resource class mapping contradicts exact saved matches: '+str(conflicts[:3]))
selected=source.get('kind');timestamps={}
if selected:groups.setdefault(selected,[])
try:
 previous=json.loads((r/'gathering-manifest.json').read_text())
 if previous['pid']==source['pid'] and str(previous['startTime'])==str(source['startTime']):
  for kind in previous['counts']:
   if kind not in groups and re.fullmatch('[A-Za-z]+',kind):
    cached=json.loads((r/'gathering-data'/previous['version']/(kind+'.json')).read_text());groups[kind]=cached['points'];timestamps[kind]=cached['capturedAt']
except (OSError,ValueError,KeyError):pass
version=hashlib.sha256((source['capturedAt']+str(source['pid'])).encode()).hexdigest()[:12];folder=r/'gathering-data'/version;folder.mkdir(parents=True,exist_ok=True)
for kind,rows in groups.items():
 if not re.fullmatch('[A-Za-z]+',kind):raise ValueError('Unsafe category name')
 target=folder/(kind+'.json');temporary=folder/(kind+'.json.tmp');temporary.write_text(json.dumps({'map':region,'type':kind,'version':version,'capturedAt':timestamps.get(kind,source['capturedAt']),'points':rows},separators=(',',':')));temporary.replace(target)
manifest={k:source[k] for k in ['pid','startTime','capturedAt','completedAt']};manifest.update({'map':region,'version':version,'counts':{k:len(v) for k,v in groups.items()},'unknownClasses':dict(unknown),'exactSavedMatches':sum(c['distanceMeters']<.02 for c in source['checks']),'exact3dSavedMatches':sum(c['distance3dMeters']<.02 for c in source['checks']),'categoryTimes':{k:timestamps.get(k,source['capturedAt']) for k in groups}});temp=r/'gathering-manifest.tmp';temp.write_text(json.dumps(manifest,indent=2));temp.replace(r/'gathering-manifest.json')
# Retain two generated versions in both caches, including durable upgrade data.
def prune_versions(root):
 root=root.resolve();versions=sorted([p for p in root.iterdir() if p.is_dir() and re.fullmatch('[0-9a-f]{12}',p.name)],key=lambda p:p.stat().st_mtime,reverse=True)
 for old in versions[2:]:
  if old.is_symlink() or old.resolve().parent!=root:raise ValueError('Invalid cache cleanup target')
  shutil.rmtree(old)
prune_versions(r/'gathering-data')
shared=os.environ.get('DST_ATLAS_SNAPSHOT_ROOT')
if shared:
 saved=Path(shared)/'gathering'/region;saved.mkdir(parents=True,exist_ok=True)
 destination=saved/'gathering-data'/version
 shutil.copytree(folder,destination,dirs_exist_ok=True)
 temp=saved/'gathering-manifest.tmp';temp.write_text(json.dumps(manifest));temp.replace(saved/'gathering-manifest.json')
 prune_versions(saved/'gathering-data')
print(json.dumps(manifest,indent=2))
