from pathlib import Path
import datetime,json,sys,tempfile,unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'app/tools/DuneAtlas'))
import atlas_runtime
class CacheRestoreTests(unittest.TestCase):
 def fixture(self,folder):
  parent=Path(folder)/'runtimes';old=parent/'old';new=parent/'new'
  files={n:'same' for n in ('inspect-reflection.py','worm-fast.py','snapshot-native.py','resource-field-id.py')}
  stamp=datetime.datetime.now(datetime.timezone.utc).isoformat()
  for root in (old,new):
   root.mkdir(parents=True)
   for name in files:(root/name).write_text('same')
   for region in ('','hagga'):
    p=root/region;p.mkdir(exist_ok=True)
    (p/'runtime-context.json').write_text(json.dumps({'pid':0,'sha256':'build'}))
    if root==old:
     (p/'runtime-context.json').write_text(json.dumps({'pid':12,'startTime':'34','sha256':'build','needles':{'worm':123}}))
     (p/'native-hits-new.json').write_text('[]')
     (p/'native-snapshot-current.json').write_text(json.dumps({'pid':12,'startTime':'34','capturedAt':stamp,'systems':[]}))
  return old,new,stamp
 def test_reuses_both_worlds_without_refreshing_snapshot_timestamps(self):
  with tempfile.TemporaryDirectory() as folder:
   old,new,stamp=self.fixture(folder);result=atlas_runtime.restore_cached_runtime(new)
   self.assertEqual(set(result),{'native','haggaNative'})
   self.assertEqual(result['native']['capturedAt'],stamp)
   self.assertEqual((new/'runtime-context.json').read_bytes(),(old/'runtime-context.json').read_bytes())
 def test_rejects_incompatible_reader_build_and_mismatched_process(self):
  for kind in ('reader','build','process'):
   with self.subTest(kind=kind),tempfile.TemporaryDirectory() as folder:
    old,new,_=self.fixture(folder)
    if kind=='reader':(old/'worm-fast.py').write_text('changed')
    elif kind=='build':
     for region in ('','hagga'):
      p=old/region/'runtime-context.json';v=json.loads(p.read_text());v['sha256']='different';p.write_text(json.dumps(v))
    else:
     for region in ('','hagga'):
      p=old/region/'native-snapshot-current.json';v=json.loads(p.read_text());v['startTime']='changed';p.write_text(json.dumps(v))
    self.assertEqual(atlas_runtime.restore_cached_runtime(new),{})
 def test_does_not_overwrite_an_existing_discovered_context(self):
  with tempfile.TemporaryDirectory() as folder:
   old,new,_=self.fixture(folder)
   for region in ('','hagga'):(new/region/'runtime-context.json').write_text(json.dumps({'pid':99,'sha256':'build'}))
   self.assertEqual(atlas_runtime.restore_cached_runtime(new),{})
