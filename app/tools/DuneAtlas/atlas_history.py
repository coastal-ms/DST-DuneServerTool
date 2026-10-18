"""Keep bounded observed storm records outside versioned runtime folders."""
import datetime,json,math
from pathlib import Path

def load(root,legacy_roots=()):
    frames={};profiles={}
    for folder in [*legacy_roots,Path(root)]:
        folder=Path(folder)
        try:
            path=folder/'storm-history-v1.json'
            if path.stat().st_size>8388608:continue
            value=json.loads(path.read_text(encoding='utf-8'))
            values=value.get('frames',[]);profiles.update(value.get('profiles',{}))
        except (OSError,ValueError):
            values=[]
            try:
                path=folder/'storm-position-observations.jsonl'
                if path.stat().st_size<=8388608:
                    for line in path.read_text(encoding='utf-8').splitlines():
                        try:values.append(json.loads(line))
                        except ValueError:pass
            except OSError:pass
            try:profiles.update(json.loads((folder/'storm-zone-profiles.json').read_text(encoding='utf-8')))
            except (OSError,ValueError):pass
        for frame in values:
            try:
                datetime.datetime.fromisoformat(frame['capturedAt'])
                if not isinstance(frame['pid'],int) or not isinstance(frame['storms'],list):continue
                if not all(len(s['location'])==3 and all(math.isfinite(n) for n in s['location']) for s in frame['storms']):continue
                frames[(frame['capturedAt'],str(frame['pid']),str(frame['startTime']))]=frame
            except (KeyError,TypeError,ValueError):continue
    result=[frames[k] for k in sorted(frames)][-500:]
    keys={str(f['pid'])+':'+str(f['startTime'])+':'+str(s['id']) for f in result for s in f['storms']}
    return result,{k:v for k,v in profiles.items() if k in keys}

def save(root,frames,profiles):
    root=Path(root);root.mkdir(parents=True,exist_ok=True)
    temp=root/'storm-history-v1.tmp'
    temp.write_text(json.dumps({'frames':list(frames)[-500:],'profiles':profiles}),encoding='utf-8')
    temp.replace(root/'storm-history-v1.json')
