"""Refresh owned runtime source hashes after reviewed source edits."""
from pathlib import Path
import hashlib,json

root=Path(__file__).resolve().parents[2]/'app/tools/DuneAtlas'
path=root/'manifest.json';manifest=json.loads(path.read_text(encoding='utf-8'))
for name in manifest['files']:
    target=(root/name).resolve()
    if not target.is_relative_to(root.resolve()):raise ValueError('Invalid package path')
    data=target.read_bytes()
    if target.suffix=='.py':compile(data.decode('utf-8'),name,'exec')
    manifest['files'][name]=hashlib.sha256(data).hexdigest()
path.write_bytes((json.dumps(manifest,indent=2)+'\n').encode('utf-8'))
print('Atlas source manifest verified:',len(manifest['files']),'files')
