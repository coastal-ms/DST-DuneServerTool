"""Private local map research service. All game SQL uses a READ ONLY transaction."""
import atlas_process
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import datetime, json, subprocess, threading, time, secrets, urllib.parse, re, gzip, hashlib, os, sys
from collections import deque
import atlas_gathering
import atlas_preferences
import atlas_live
import atlas_runtime
import atlas_assets
import atlas_lifecycle
import atlas_history

ROOT=Path(__file__).resolve().parent
REPO=Path(os.environ['DST_ATLAS_APP_ROOT']).resolve()
SNAPSHOT_ROOT=Path(os.environ.get('DST_ATLAS_SNAPSHOT_ROOT',str(ROOT))).resolve()
PREFERENCES_ROOT=Path(os.environ.get('DST_ATLAS_PREFERENCES_ROOT',str(ROOT))).resolve()
ASSET_ROOT=Path(os.environ.get('DST_ATLAS_ASSET_ROOT',str(ROOT/'icons'))).resolve()
SNAPSHOT_ROOT.mkdir(parents=True,exist_ok=True)
PREFERENCES_ROOT.mkdir(parents=True,exist_ok=True)
access=ROOT/'access.json'
if not access.exists():access.write_text(json.dumps({'key':secrets.token_urlsafe(24)}),encoding='utf-8')
KEY=json.loads(access.read_text(encoding='utf-8'))['key']
state={'connected':False,'error':'Waiting for first read-only database snapshot','snapshot':None}
try:
    cached_native=json.loads((ROOT/'native-snapshot-current.json').read_text())
    current_context=json.loads((ROOT/'runtime-context.json').read_text())
    if cached_native['pid']==current_context['pid'] and (datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(cached_native['capturedAt'])).total_seconds()<180:state['native']=cached_native
except Exception:
    pass
legacy_roots=[ROOT]
if ROOT.parent.name=='runtimes':legacy_roots+=sorted(ROOT.parent.iterdir())[:32]
history_frames,storm_profiles=atlas_history.load(SNAPSHOT_ROOT,legacy_roots)
storm_history=deque(history_frames,maxlen=501)
state['stormHistory']=list(storm_history)
state['stormProfiles']=storm_profiles
try:state['baseModels']=json.loads((ROOT/'base-models-current.json').read_text())
except (FileNotFoundError,ValueError):pass
wire_cache={}
wire_lock=threading.RLock()
lock=threading.RLock()
stop=threading.Event()

def collect_once():
    started=time.monotonic()
    try:
        result=atlas_process.run(['pwsh','-NoProfile','-File',str(ROOT/'query.ps1'),'-SqlFile',str(ROOT/'collect.sql'),'-OutputFile',str(ROOT/'latest-query.json')],capture_output=True,text=True,timeout=35,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        if result.returncode: raise RuntimeError('Database snapshot failed; see private collector log')
        value=json.loads((ROOT/'latest-query.json').read_text(encoding='utf-8-sig'))
        snapshot=json.loads(value['rows'][0][0])
        if snapshot['readOnly']!='on': raise RuntimeError('Read-only transaction was not confirmed')
        with lock: state.update(connected=True,error=None,snapshot=snapshot,queryMs=value['durationMs'])
    except atlas_process.Cancelled:
        raise
    except Exception as e:
        with lock: state.update(connected=False,error=str(e))
        with (ROOT/'collector.log').open('a',encoding='utf-8') as f:f.write(datetime.datetime.now(datetime.timezone.utc).isoformat()+' '+str(e)+'\n')

def collect_native_once(region="DeepDesert"):
    folder=ROOT if region=="DeepDesert" else ROOT/"hagga"
    native_key="native" if region=="DeepDesert" else "haggaNative"
    error_key="nativeError" if region=="DeepDesert" else "haggaNativeError"
    started=time.monotonic()
    try:
        with lock:previous=state.get(native_key)
        value=atlas_runtime.collect_native(folder)
        for storm in value.get('storms',[]):
            if storm.get('zones'):
                profile_key=str(value['pid'])+':'+str(json.loads((folder/'runtime-context.json').read_text())['startTime'])+':'+storm['id']
                with lock:
                    storm_profiles[profile_key]={k:storm[k] for k in ['zones','rotation','scale']}
                    storm_profiles[profile_key].update(capturedAt=value['capturedAt'],source='Observed native storm zone dimensions and root transform')
                    atlas_history.save(SNAPSHOT_ROOT,storm_history,storm_profiles)
        with lock: state.update({native_key:value,error_key:None,"stormProfiles":dict(storm_profiles)})
        if previous and (previous.get('pid'),str(previous.get('startTime')))!=(value.get('pid'),str(value.get('startTime'))):
            gathering_queue.reset_world(region)
            with control:
                urgent_jobs.add('gathering');waiting_jobs['gathering']=0
                atlas_process.cancel_job('gathering');control.notify_all()
    except atlas_process.Cancelled:
        raise
    except Exception as e:
        with lock: state.update({error_key:str(e)})

worm_readers={}
def collect_worms_once(region="DeepDesert"):
    folder=ROOT if region=="DeepDesert" else ROOT/"hagga"
    native_key="native" if region=="DeepDesert" else "haggaNative"
    feed_key="wormFeed" if region=="DeepDesert" else "haggaWormFeed"
    error_key="wormError" if region=="DeepDesert" else "haggaWormError"
    if region not in worm_readers:
        import importlib.util
        spec=importlib.util.spec_from_file_location('worm_fast',ROOT/'worm-fast.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);reader=module.WormReader(folder)
        worm_readers[region]=reader
    reader=worm_readers[region]
    started=time.monotonic()
    try:
        with lock: native=state.get(native_key)
        if not native:raise ValueError('Waiting for native discovery')
        feed=reader.read(native)
        if feed.get('storms'):
            observed={'map':region,'pid':feed['pid'],'startTime':feed.get('startTime'),'capturedAt':feed['capturedAt'],'storms':feed['storms']}
            with lock:
                storm_history.append(observed)
                retained=atlas_history.compact(storm_history)
                storm_history.clear();storm_history.extend(retained)
                atlas_history.save(SNAPSHOT_ROOT,storm_history,storm_profiles)
        with lock:state.update({feed_key:feed,error_key:None,"stormHistory":list(storm_history)})
    except atlas_process.Cancelled:
        raise
    except Exception as e:
        # Keep the last timestamped reading through a transient failure. The
        # viewer still expires stale observations; a failed read is not zero.
        with lock:state.update({error_key:str(e)})

def collect_base_models_once():
    started=time.monotonic()
    try:
        result=atlas_process.run(['pwsh','-NoProfile','-File',str(ROOT/'query.ps1'),'-SqlFile',str(ROOT/'base-models.sql'),'-OutputFile',str(ROOT/'base-models-query.json')],capture_output=True,text=True,timeout=45,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        if result.returncode:raise ValueError('Base layout read unavailable')
        result=atlas_process.run([sys.executable,str(ROOT/'base-miniatures.py')],capture_output=True,text=True,timeout=45,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        if result.returncode:raise ValueError('Base miniature generation unavailable')
        value=json.loads((SNAPSHOT_ROOT/'base-models-current.json').read_text(encoding='utf-8'))
        with lock:state.update(baseModels=value,baseModelError=None)
    except atlas_process.Cancelled:
        raise
    except Exception as e:
        with lock:state.update(baseModelError=str(e))

def collect_pois_once():
    started=time.monotonic()
    errors={}
    for folder in [ROOT,ROOT/'hagga']:
        try:
            atlas_runtime.collect_pois(folder,ROOT)
        except Exception as e:errors['HaggaBasin' if folder.name=='hagga' else 'DeepDesert']=str(e)
    with lock:state['poiErrors']=errors

def gathering_metadata(region='DeepDesert'):
    if region not in ['DeepDesert','HaggaBasin']:raise ValueError('Unknown map')
    folder=ROOT if region=='DeepDesert' else ROOT/'hagga'
    value=json.loads((folder/'gathering-manifest.json').read_text());context=json.loads((folder/'runtime-context.json').read_text())
    now=datetime.datetime.now(datetime.timezone.utc) if state.get('live') or state.get('refreshing') else datetime.datetime.fromisoformat(state['frozenAt']);age=(now-datetime.datetime.fromisoformat(value['capturedAt'])).total_seconds()
    with lock:feed=state.get('wormFeed');snapshot=state.get('snapshot')
    if value['pid']!=context['pid'] or str(value['startTime'])!=str(context['startTime']) or not 0<=age<1200:raise ValueError('Expired gathering geometry')
    server='DeepDesert_1' if region=='DeepDesert' else 'Survival_1'
    if not snapshot or not any(v['map']==server and v['alive'] and v['ready'] for v in snapshot['servers']):raise ValueError('World is not ready')
    if region=='DeepDesert':
        if not feed or feed['pid']!=value['pid'] or (now-datetime.datetime.fromisoformat(feed['capturedAt'])).total_seconds()>=max(12,state.get('refreshSeconds',3)*2):raise ValueError('World read is stale')
    else:
        live=state.get('haggaWormFeed')
        if not live or live['pid']!=value['pid'] or str(live['startTime'])!=str(value['startTime']) or (now-datetime.datetime.fromisoformat(live['capturedAt'])).total_seconds()>=max(12,state.get('refreshSeconds',3)*2):raise ValueError('World read is stale')
    if not re.fullmatch('[0-9a-f]{12}',value['version']):raise ValueError('Invalid geometry version')
    return value

def collect_gathering_once():
    key=gathering_queue.next()
    if not key:return
    region,kind=key;folder=ROOT if region=='DeepDesert' else ROOT/'hagga'
    try:
        context=json.loads((folder/'runtime-context.json').read_text())
        # Cold upgrades begin with a bootstrap identity. Waiting for native
        # discovery is not a failed category read and must not incur a retry delay.
        if context.get('pid',0)<=0:return
        atlas_runtime.atlas_readers.ensure(ROOT)
        try:
            cache=json.loads((folder/'poi-source-actor-cache.json').read_text())
            ready=cache['pid']==context['pid'] and str(cache['startTime'])==str(context['startTime']) and (datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(cache['capturedAt'])).total_seconds()<900
        except (OSError,ValueError,KeyError):ready=False
        scripts=([('find-poi-sources.py',60)] if not ready else [])+[('read-gathering-instances.py',420),('publish-gathering.py',30)]
        env={**os.environ,'DST_ATLAS_GATHERING_KIND':kind,'DST_ATLAS_SNAPSHOT_ROOT':str(SNAPSHOT_ROOT)}
        for script,timeout in scripts:
            with (folder/(script+'.log')).open('w',encoding='utf-8') as log:
                result=atlas_process.run([sys.executable,str(folder/script)],env=env,stdout=log,stderr=subprocess.STDOUT,text=True,timeout=timeout)
            if result.returncode:raise ValueError(region+' gathering read unavailable')
        gathering_queue.finish(key)
        with lock:
            state.setdefault('gatheringErrors',{})[region]=None
            state['gatheringUpdatedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat()
    except atlas_process.Cancelled:raise
    except Exception as e:
        gathering_queue.finish(key,False)
        with lock:state.setdefault('gatheringErrors',{})[region]=str(e)


try:
    seeded=json.loads((SNAPSHOT_ROOT/'static-state-seed.json').read_text(encoding='utf-8-sig'))
    state.update(seeded)
except (FileNotFoundError,ValueError):pass
try:static_pois=json.loads((SNAPSHOT_ROOT/'static-pois-seed.json').read_text(encoding='utf-8-sig'))
except (FileNotFoundError,ValueError):static_pois={'items':[],'sources':[]}
# Carry compatible addresses across installer bundles before starting workers.
state.update(atlas_runtime.restore_cached_runtime(ROOT))
state.update(stormHistory=list(storm_history),stormProfiles=storm_profiles,preferencesSupported=True,live=False,refreshing=False,stopping=False,frozenAt=state.get('frozenAt') or (state.get('wormFeed') or {}).get('capturedAt') or (state.get('snapshot') or {}).get('observedAt') or datetime.datetime.now(datetime.timezone.utc).isoformat(),activity=[])
def restore_base_data():
    import importlib.util
    best=None;latest=''
    try:
        value=json.loads((SNAPSHOT_ROOT/'base-models-current.json').read_text(encoding='utf-8'))
        if isinstance(value.get('models'),dict):best=value;latest=value.get('observedAt','')
    except (OSError,ValueError):pass
    for folder in legacy_roots:
        try:
            path=folder/'base-models-query.json'
            if path.stat().st_size>67108864:continue
            source=json.loads(json.loads(path.read_text(encoding='utf-8-sig'))['rows'][0][0])
            if source.get('readOnly')!='on' or source.get('observedAt','')<=latest:continue
            spec=importlib.util.spec_from_file_location('base_layouts',ROOT/'base-miniatures.py')
            renderer=importlib.util.module_from_spec(spec);spec.loader.exec_module(renderer)
            best=renderer.build(source,SNAPSHOT_ROOT);latest=source['observedAt']
        except (OSError,ValueError,KeyError,TypeError,IndexError):continue
    if best:state['baseModels']=best
restore_base_data()

def restore_gathering_data():
    import shutil
    for region,folder in [('DeepDesert',ROOT),('HaggaBasin',ROOT/'hagga')]:
        saved=SNAPSHOT_ROOT/'gathering'/region
        if saved.is_dir() and not (folder/'gathering-manifest.json').exists():
            shutil.copytree(saved,folder,dirs_exist_ok=True)
restore_gathering_data()

control=threading.Condition()
live_enabled=atlas_live.load(PREFERENCES_ROOT)
state['live']=live_enabled
if live_enabled:state['liveStartedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat()
refresh_generation=0
refresh_required=set()
refresh_background=set()
completed={}
waiting_jobs={}
urgent_jobs=set()
active_jobs=set()
MAX_ACTIVE_JOBS=3
JOB_PERIODS={'db':10,'native':15,'positions':3,'haggaNative':15,'haggaPositions':3,'bases':60,'pois':60,'gathering':900}
saved_preferences=atlas_preferences.load(PREFERENCES_ROOT) or {}
state['refreshSeconds']=saved_preferences.get('refreshSeconds',3)
gathering_queue=atlas_gathering.Queue(saved_preferences)
if gathering_queue.selected:
    urgent_jobs.add('gathering');waiting_jobs['gathering']=0
for region,folder in [('DeepDesert',ROOT),('HaggaBasin',ROOT/'hagga')]:
    try:
        manifest=json.loads((folder/'gathering-manifest.json').read_text())
        context=json.loads((folder/'runtime-context.json').read_text())
        if manifest['pid']==context['pid'] and str(manifest['startTime'])==str(context['startTime']):
            for kind,stamp in manifest.get('categoryTimes',{}).items():
                age=(datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(stamp)).total_seconds()
                gathering_queue.finished[(region,kind)]=time.monotonic()-max(0,age)
    except (OSError,ValueError,KeyError):pass

def job_period(name):
    seconds=state.get('refreshSeconds',3)
    if name=='gathering':return 1
    if name in ('positions','haggaPositions'):return seconds
    return max(JOB_PERIODS[name],seconds)

marker_icon_body=None
marker_icon_lock=threading.Lock()

def replace_snapshot(source,target):
    for attempt in range(4):
        try:source.replace(target);return
        except PermissionError:
            if attempt==3:return
            time.sleep(.05)

def capture_static_files():
    global static_pois
    items=[];sources=[]
    for folder in [ROOT,ROOT/'hagga']:
        try:
            value=json.loads((folder/'native-pois-current.json').read_text());context=json.loads((folder/'runtime-context.json').read_text())
            if value['pid']!=context['pid'] or str(value['startTime'])!=str(context['startTime']):continue
            items.extend(value['items']);sources.append({k:value[k] for k in ['pid','startTime','capturedAt']})
        except Exception:items.extend(v for v in static_pois.get('items',[]) if v.get('map')==('HaggaBasin' if folder.name=='hagga' else 'DeepDesert'))
    static_pois={'items':items,'sources':sources}
    with lock:
        frozen=json.dumps(state)
        (SNAPSHOT_ROOT/'static-state-seed.tmp').write_text(frozen,encoding='utf-8');replace_snapshot(SNAPSHOT_ROOT/'static-state-seed.tmp',SNAPSHOT_ROOT/'static-state-seed.json')
        (SNAPSHOT_ROOT/'static-pois-seed.tmp').write_text(json.dumps(static_pois),encoding='utf-8');replace_snapshot(SNAPSHOT_ROOT/'static-pois-seed.tmp',SNAPSHOT_ROOT/'static-pois-seed.json')

SNAPSHOT_TIMEOUT=120

def expire_snapshot(generation):
    """Bound the whole refresh, including cold discovery and dependent reads."""
    global refresh_required,refresh_background
    with control:
        if generation!=refresh_generation or not state['refreshing']:return
        refresh_required=set()
        refresh_background=set()
        atlas_process.cancel()
        with lock:
            state.update(refreshing=False,stopping=bool(active_jobs),refreshError='Snapshot refresh timed out after 2 minutes. Last available data is shown. Retry or start live for continuing discovery.')
            if not active_jobs:
                state['frozenAt']=datetime.datetime.now(datetime.timezone.utc).isoformat()
                capture_static_files()
        control.notify_all()

def collection_worker(name,observe):
    last_finished=None
    cooldown=0
    while not stop.is_set():
        with control:
            generation=refresh_generation
            requested=name in (refresh_required|refresh_background) and completed.get(name,0)<generation
            ready=live_enabled and (name in urgent_jobs or last_finished is None or time.monotonic()-last_finished>=max(job_period(name),cooldown))
            dependency='haggaNative' if name=='haggaPositions' else 'native'
            if requested and name in ('positions','haggaPositions','pois','gathering') and (completed.get(dependency,0)<generation or completed.get('db',0)<generation):ready=False;requested=False
            if requested and name in refresh_background and any(completed.get(k,0)<generation for k in refresh_required):
                control.wait(timeout=.3);continue
            def lane(job):return 'positions' if job in ('db','positions','haggaPositions') else 'optional' if job in ('gathering','pois') else 'core'
            lane_busy=any(lane(job)==lane(name) for job in active_jobs)
            # Optional discovery yields its remote I/O between bounded batches;
            # it cannot hold database/native jobs behind a whole resource scan.
            if requested or ready:waiting_jobs.setdefault(name,time.monotonic())
            else:waiting_jobs.pop(name,None)
            peers=[k for k in waiting_jobs if lane(k)==lane(name)]
            first=min(peers,key=lambda k:waiting_jobs[k]) if peers else name
            resource=gathering_queue.next()
            if live_enabled and resource in gathering_queue.selected and resource not in gathering_queue.finished and lane(name)=='optional':first='gathering'
            if (not requested and not ready) or len(active_jobs)>=MAX_ACTIVE_JOBS or lane_busy or first!=name:
                control.wait(timeout=.3);continue
            waiting_jobs.pop(name,None)
            urgent_jobs.discard(name)
            active_jobs.add(name)
            with lock:state['activity']=sorted(active_jobs)
        started=time.monotonic()
        try:
            mode="positions" if name in ("db","positions","haggaPositions") else "optional" if name in ("gathering","pois") else "core"
            with atlas_process.priority(mode,ROOT/"io-budget",name):observe()
        except atlas_process.Cancelled:
            pass
        except Exception as e:
            with lock:state[name+'Error']=str(e)
        finally:
            with control:
                active_jobs.discard(name);completed[name]=max(generation,completed.get(name,0));last_finished=time.monotonic()
                # Expensive reads get at least as much idle time as work time.
                # A slow SSH read must never become a continuous launch loop.
                cooldown=min(5,last_finished-started) if name=="gathering" else last_finished-started
                with lock:
                    state['activity']=sorted(active_jobs)
                    if state['refreshing'] and all(completed.get(k,0)>=refresh_generation for k in refresh_required):
                        state['refreshing']=False
                        if not live_enabled:
                            state['frozenAt']=datetime.datetime.now(datetime.timezone.utc).isoformat();capture_static_files()
                    if not live_enabled and not active_jobs and not state['refreshing']:
                        state['stopping']=False;state['frozenAt']=datetime.datetime.now(datetime.timezone.utc).isoformat();capture_static_files()
                control.notify_all()

class Handler(BaseHTTPRequestHandler):
    def handle_one_request(self):
        try:super().handle_one_request()
        except (BrokenPipeError,ConnectionResetError,ConnectionAbortedError):self.close_connection=True

    def do_POST(self):
        global live_enabled,refresh_generation,refresh_required,refresh_background
        url=urllib.parse.urlsplit(self.path);host=self.headers.get('Host')
        if host not in (f'127.0.0.1:{self.server.server_port}',f'localhost:{self.server.server_port}') or urllib.parse.parse_qs(url.query).get('key')!=[KEY]:return self.send_error(403)
        if self.headers.get('Origin') not in (None,'http://'+host):return self.send_error(403)
        if self.headers.get('Content-Type','').split(';')[0]!='application/json':return self.send_error(415)
        try:
            length=int(self.headers.get('Content-Length','0'))
            if not 0<length<=(40960 if url.path=='/preferences' else 2048):raise ValueError()
            payload=json.loads(self.rfile.read(length))
            if not isinstance(payload,dict):raise ValueError()
        except Exception:return self.send_error(400)
        if url.path=='/preferences':
            try:
                with control:
                    if self.headers.get('X-DST-Atlas-Timing')=='remote':
                        payload['refreshSeconds']=state.get('refreshSeconds',3)
                    previous=atlas_preferences.load(PREFERENCES_ROOT) or {}
                    preferences=atlas_preferences.save(PREFERENCES_ROOT,payload)
                    with lock:state['refreshSeconds']=preferences['refreshSeconds']
                    old_selected=set(gathering_queue.selected)
                    gathering_queue.update(preferences)
                    added=set(preferences['layers'])-set(previous.get('layers',[]))
                    target='gathering' if gathering_queue.selected-old_selected else 'pois' if any(v.startswith('poi:') for v in added) else None
                    if target:
                        urgent_jobs.add(target);waiting_jobs[target]=0
                        for job in active_jobs & {'gathering','pois'}:atlas_process.cancel_job(job)
                    control.notify_all()
                body=json.dumps(preferences).encode()
            except ValueError:return self.send_error(400,'Invalid map selections')
            self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(body);return
        if url.path not in ('/live/start','/live/stop','/refresh'):return self.send_error(404)
        if self.headers.get('X-DST-Atlas-Timing')=='remote' and url.path!='/live/start':return self.send_error(403,'Only the local host can stop or refresh map collection')
        with control:
            if url.path=='/live/start':
                if state['stopping'] or (active_jobs-{'gathering'}) and not live_enabled:return self.send_error(409,'Map collection is stopping')
                try:atlas_live.save(PREFERENCES_ROOT,True)
                except OSError:return self.send_error(500,'Could not save the Live preference. Please retry.')
                atlas_process.reset()
                if not live_enabled:
                    # A new Live session bypasses the previous scan's idle cooldown.
                    # Keep lane limits and normal recovery pauses for subsequent reads.
                    urgent_jobs.update(('db','positions','haggaPositions','native','haggaNative'))
                    with lock:state['liveStartedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat()
                live_enabled=True
                with lock:state.update(live=True,stopping=False,refreshError=None)
            elif url.path=='/live/stop':
                try:atlas_live.save(PREFERENCES_ROOT,False)
                except OSError:return self.send_error(500,'Could not save the Live preference. Please retry.')
                live_enabled=False
                refresh_required=set()
                refresh_background=set()
                atlas_process.cancel()
                with lock:
                    state.update(live=False,refreshing=False,stopping=bool(active_jobs),frozenAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
                    if not active_jobs:capture_static_files()
            else:
                if live_enabled or state['refreshing'] or (active_jobs-{'gathering'}):return self.send_error(409,'Wait for current collection to finish')
                atlas_process.reset()
                refresh_generation+=1;refresh_required={'db','native','positions','haggaNative','haggaPositions'}
                refresh_background={'bases','pois'} | ({'gathering'} if payload.get('gathering') else set())
                with lock:state.update(refreshing=True,refreshError=None)
                deadline=threading.Timer(SNAPSHOT_TIMEOUT,expire_snapshot,args=(refresh_generation,))
                deadline.daemon=True;deadline.start()
            control.notify_all()
            with lock:body=json.dumps({'live':state['live'],'refreshing':state['refreshing'],'stopping':state['stopping']}).encode()
        self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(body)

    def do_GET(self):
        global marker_icon_body
        url=urllib.parse.urlsplit(self.path)
        if self.headers.get('Host') not in (f'127.0.0.1:{self.server.server_port}',f'localhost:{self.server.server_port}'):
            return self.send_error(403)
        if urllib.parse.parse_qs(url.query).get('key')!=[KEY]:return self.send_error(403)
        if url.path=='/preferences':
            body=json.dumps(atlas_preferences.load(PREFERENCES_ROOT)).encode();mime='application/json'
        elif url.path=='/marker-icons':
            with marker_icon_lock:
                if marker_icon_body is None:marker_icon_body=json.dumps(atlas_assets.marker_icons(ASSET_ROOT,ROOT/'icons')).encode()
                body=marker_icon_body
            mime='application/json'
        elif url.path=='/state':
            with lock:body=json.dumps({**state,'canControlTiming':self.headers.get('X-DST-Atlas-Timing')!='remote','canControlCollection':self.headers.get('X-DST-Atlas-Timing')!='remote','canStartCollection':True}).encode()
            mime='application/json'
        elif url.path in ['/gathering','/gathering/HaggaBasin']:
            try:body=json.dumps(gathering_metadata('HaggaBasin' if url.path.endswith('/HaggaBasin') else 'DeepDesert')).encode()
            except Exception:body=json.dumps({'counts':{},'unavailable':True}).encode()
            mime='application/json'
        elif re.fullmatch(r'/gathering/(DeepDesert|HaggaBasin)/[A-Za-z]+',url.path):
            try:
                region=url.path.split('/')[2];manifest=gathering_metadata(region);kind=url.path.rsplit('/',1)[1];folder=ROOT if region=='DeepDesert' else ROOT/'hagga'
                if kind not in manifest['counts']:return self.send_error(404)
                body=(folder/'gathering-data'/manifest['version']/(kind+'.json')).read_bytes()
            except Exception:return self.send_error(503)
            mime='application/json'
        elif url.path=='/pois' and not state.get('live') and not state.get('refreshing'):
            body=json.dumps(static_pois).encode();mime='application/json'
        elif url.path=='/pois':
            items=[];sources=[]
            for region,folder in [('DeepDesert',ROOT),('HaggaBasin',ROOT/'hagga')]:
                try:
                    value=json.loads((folder/'native-pois-current.json').read_text())
                    context=json.loads((folder/'runtime-context.json').read_text())
                    age=(datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(value['capturedAt'])).total_seconds()
                    if value['pid']!=context['pid'] or str(value['startTime'])!=str(context['startTime']) or not 0<=age<120:raise ValueError('Expired map point actor read')
                    items.extend(value['items']);sources.append({k:value[k] for k in ['pid','startTime','capturedAt']})
                except Exception:items.extend(v for v in static_pois.get('items',[]) if v.get('map')==region)
            body=json.dumps({'items':items,'sources':sources}).encode();mime='application/json'
        elif re.fullmatch(r'/bases/[0-9]{1,20}\.(svg|json)',url.path):
            name=url.path.rsplit('/',1)[1]
            target=SNAPSHOT_ROOT/'bases'/name
            if not target.is_file():return self.send_error(404)
            body=target.read_bytes();mime='application/json' if name.endswith('.json') else 'image/svg+xml'
        elif re.fullmatch(r'/icons/[a-z0-9-]+\.(svg|png|webp)',url.path):
            name=url.path.rsplit('/',1)[1]
            if name.startswith('poi-'):
                target=REPO/'webui/dist/wickmaps'/name[4:]
                if not target.is_file():target=REPO.parent/'webui/public/wickmaps'/name[4:]
            else:target=atlas_assets.icon_path(name,ASSET_ROOT,ROOT/'icons')
            if target is None or not target.is_file():return self.send_error(404)
            body=target.read_bytes();mime={'.svg':'image/svg+xml','.png':'image/png','.webp':'image/webp'}[target.suffix]
        elif url.path=='/':body=(ROOT/'index.html').read_bytes();mime='text/html; charset=utf-8'
        else:return self.send_error(404)
        etag='"'+hashlib.sha256(body).hexdigest()+'"'
        if self.headers.get('If-None-Match')==etag:
            self.send_response(304);self.send_header('ETag',etag);self.send_header('Cache-Control','no-store');self.end_headers();return
        compressed=False
        if mime=='application/json' and len(body)>1024 and 'gzip' in self.headers.get('Accept-Encoding',''):
            with wire_lock:
                entry=wire_cache.get(url.path)
                if not entry or entry[0]!=etag:
                    entry=(etag,gzip.compress(body,compresslevel=3,mtime=0));wire_cache[url.path]=entry
                    if len(wire_cache)>80:wire_cache.pop(next(iter(wire_cache)))
                body=entry[1]
            compressed=True
        self.send_response(200);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(body)));self.send_header('Cache-Control','no-store');self.send_header('ETag',etag);self.send_header('Vary','Accept-Encoding');self.send_header('X-Content-Type-Options','nosniff')
        if compressed:self.send_header('Content-Encoding','gzip')
        self.end_headers();self.wfile.write(body)
    def log_message(self,*args):pass

if __name__=='__main__':
    host_guard=atlas_lifecycle.from_environment()
    port=int(os.environ.get('DST_ATLAS_PORT','0'))
    if not 0<=port<=65535:raise ValueError('Invalid local atlas port')
    server=ThreadingHTTPServer(('127.0.0.1',port),Handler)
    for name,observer in [('db',collect_once),('native',collect_native_once),('positions',collect_worms_once),('haggaNative',lambda:collect_native_once('HaggaBasin')),('haggaPositions',lambda:collect_worms_once('HaggaBasin')),('bases',collect_base_models_once),('pois',collect_pois_once),('gathering',collect_gathering_once)]:
        threading.Thread(target=collection_worker,args=(name,observer),daemon=True).start()
    import os
    (ROOT/'ready.json').write_text(json.dumps({'pid':os.getpid(),'url':f'http://127.0.0.1:{server.server_port}/?key='+KEY,'readOnly':True}),encoding='utf-8')
    def watch_backend():
        global live_enabled
        try:
            if host_guard.wait_for_exit(stop):
                try:
                    with control:
                        live_enabled=False
                        with lock:
                            state.update(live=False,refreshing=False,stopping=False,frozenAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
                            capture_static_files()
                finally:
                    stop.set()
                    with control:control.notify_all()
                    server.shutdown()
        finally:host_guard.close()
    if host_guard:threading.Thread(target=watch_backend,daemon=True).start()
    try:server.serve_forever()
    finally:stop.set();atlas_process.cancel();server.server_close()
