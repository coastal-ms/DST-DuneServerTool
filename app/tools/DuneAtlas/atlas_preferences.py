"""Bounded, versioned user selections; contains no game or connection state."""
import json,re,os,threading
from pathlib import Path

_lock=threading.Lock()

def validate(value):
 if not isinstance(value,dict) or set(value)-{'region','layers','refreshSeconds'}:raise ValueError('Invalid selections')
 if value.get('region') not in ('DeepDesert','HaggaBasin'):raise ValueError('Invalid map')
 layers=value.get('layers')
 if not isinstance(layers,list) or len(layers)>256:raise ValueError('Invalid selections')
 known={'vehicles','bases','resources','spice-small','spice-medium','spice-large','flour','worms','storms','history','grid'}
 for layer in layers:
  if not isinstance(layer,str) or len(layer)>160 or (layer not in known and not re.fullmatch(r'poi:[A-Za-z0-9:._-]+',layer)):
   raise ValueError('Invalid layer')
 seconds=value.get('refreshSeconds',3)
 if type(seconds) is not int or seconds not in (1,3,5,10,30,60):raise ValueError('Invalid refresh speed')
 # Upgrade the old combined checkbox to the new Large-only default.
 if 'resources' in layers:
  layers=[v for v in layers if v!='resources']+([] if any(v.startswith('spice-') for v in layers) else ['spice-large'])
 return {'region':value['region'],'layers':sorted(set(layers)),'refreshSeconds':seconds}

def load(root):
 try:
  path=Path(root)/'preferences-v1.json'
  if path.stat().st_size>40960:return None
  return validate(json.loads(path.read_text(encoding='utf-8')))
 except (OSError,ValueError):return None

def save(root,value):
 value=validate(value);path=Path(root)/'preferences-v1.json'
 with _lock:
  temp=path.with_name('preferences-v1.'+str(os.getpid())+'.tmp')
  temp.write_text(json.dumps(value,ensure_ascii=True),encoding='utf-8');temp.replace(path)
 return value
