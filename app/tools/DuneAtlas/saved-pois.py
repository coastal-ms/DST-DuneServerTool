"""Current saved map locations for cross-checking native gathering positions."""
from pathlib import Path
import json

def read_saved(root):
 root=Path(root);shared=root.parent if root.name=='hagga' else root
 try:
  query=json.loads((shared/'latest-query.json').read_text(encoding='utf-8-sig'))
  snapshot=json.loads(query['rows'][0][0])
  if snapshot.get('readOnly')!='on':raise ValueError('Unverified database snapshot')
  return snapshot.get('locations',[])
 except (OSError,ValueError,KeyError,IndexError):
  try:return json.loads((root/'poi-records.json').read_text(encoding='utf-8-sig'))['items']
  except (OSError,ValueError,KeyError):return []
