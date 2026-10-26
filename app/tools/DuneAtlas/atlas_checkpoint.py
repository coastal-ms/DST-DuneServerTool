"""Atomic last-success observations; cached timestamps never become live reads."""
from pathlib import Path
import datetime, hashlib, json, os, threading, time

READERS=('inspect-reflection.py','worm-fast.py','snapshot-native.py','resource-field-id.py')
_lock=threading.RLock()
_written={}

def signature(root):
    root=Path(root)
    return {'readers':{n:hashlib.sha256((root/n).read_bytes()).hexdigest() for n in READERS},
            'scope':os.environ.get('DST_MAP_NAMESPACE','')+':'+hashlib.sha256((root/'remote.ps1').read_bytes()).hexdigest()}

def read(path):
    path=Path(path)
    if path.stat().st_size>16777216:raise ValueError('Checkpoint too large')
    return json.loads(path.read_text(encoding='utf-8-sig'))

def stamp(value):
    value=datetime.datetime.fromisoformat(value['capturedAt'])
    if value.tzinfo is None or value>datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=5):raise ValueError('Invalid checkpoint time')
    return value

def same(value,context):
    return bool(context.get('startTime')) and value.get('pid',0)>0 and value.get('pid')==context.get('pid') and str(value.get('startTime'))==str(context.get('startTime'))

def save(snapshots,root,region,value,native=False):
    """Position writes are bounded to one small checkpoint per region per 5s."""
    root=Path(root);folder=root if region=='DeepDesert' else root/'hagga'
    key=(str(snapshots),region,native)
    with _lock:
        if not native and time.monotonic()-_written.get(key,float('-inf'))<5:return
        try:
            context=read(folder/'runtime-context.json')
            if not same(value,context):return
            stamp(value)
            record={'signature':signature(root),'context':context,'value':value}
            if native:record['hits']=read(folder/'native-hits-new.json')
            path=Path(snapshots)/('last-native-' if native else 'last-positions-')
            path=path.with_name(path.name+region+'.json')
            temp=path.with_suffix('.tmp')
            temp.write_text(json.dumps(record),encoding='utf-8');temp.replace(path)
            _written[key]=time.monotonic()
        except (OSError,ValueError,KeyError,TypeError):pass

def restore(snapshots,root):
    root=Path(root);result={}
    try:expected=signature(root)
    except OSError:return result
    for region,prefix in (('DeepDesert',''),('HaggaBasin','hagga')):
        folder=root if not prefix else root/'hagga'
        native_key='native' if not prefix else 'haggaNative'
        feed_key='wormFeed' if not prefix else 'haggaWormFeed'
        try:
            current=read(folder/'native-snapshot-current.json');context=read(folder/'runtime-context.json')
            if same(current,context) and isinstance(current.get('systems'),list):
                stamp(current);result[native_key]=current
        except (OSError,ValueError,KeyError,TypeError):pass
        try:
            record=read(Path(snapshots)/('last-native-'+region+'.json'))
            context=read(folder/'runtime-context.json');frame=record['value']
            if record['signature']!=expected or record['context'].get('sha256')!=context.get('sha256') or not same(frame,record['context']):raise ValueError('Incompatible checkpoint')
            newest=stamp(frame)
            try:
                current=read(folder/'native-snapshot-current.json')
                if same(current,context) and stamp(current)>newest:raise ValueError('Current discovery is newer')
            except FileNotFoundError:pass
            for name,data in (('runtime-context.json',record['context']),('native-hits-new.json',record['hits']),('native-snapshot-current.json',frame)):
                temp=folder/(name+'.checkpoint.tmp');temp.write_text(json.dumps(data),encoding='utf-8');temp.replace(folder/name)
            result[native_key]=frame
        except (OSError,ValueError,KeyError,TypeError):pass
        try:
            context=read(folder/'runtime-context.json')
            positions=read(Path(snapshots)/('last-positions-'+region+'.json'))
            feed=positions['value']
            if native_key in result and positions['signature']==expected and positions['context'].get('sha256')==context.get('sha256') and same(feed,context) and same(result[native_key],context):
                stamp(feed);result[feed_key]=feed
        except (OSError,ValueError,KeyError,TypeError):pass
    return result
