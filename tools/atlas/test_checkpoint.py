from pathlib import Path
import datetime,json,sys,tempfile,unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'app/tools/DuneAtlas'))
import atlas_checkpoint as cp

class CheckpointTests(unittest.TestCase):
 def fixture(self,folder):
  root=Path(folder)/'runtime';root.mkdir();(root/'hagga').mkdir();snap=Path(folder)/'snapshots';snap.mkdir()
  for name in (*cp.READERS,'remote.ps1'):(root/name).write_text('fixture')
  context={'pid':10,'startTime':'20','sha256':'build','needles':{'worm':123}}
  for world in (root,root/'hagga'):
   (world/'runtime-context.json').write_text(json.dumps(context));(world/'native-hits-new.json').write_text('[]')
  frame={**context,'capturedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'systems':[]}
  return root,snap,frame
 def test_success_survives_restart_with_original_timestamps_for_both_maps(self):
  with tempfile.TemporaryDirectory() as folder:
   root,snap,frame=self.fixture(folder)
   for region in ('DeepDesert','HaggaBasin'):
    cp.save(snap,root,region,frame,native=True);cp.save(snap,root,region,{**frame,'items':[{'id':20}]})
   restored=cp.restore(snap,root)
   for key in ('native','haggaNative','wormFeed','haggaWormFeed'):self.assertEqual(restored[key]['capturedAt'],frame['capturedAt'])
 def test_incompatible_readers_server_or_build_cannot_restore_addresses(self):
  for change in ('reader','server','build'):
   with self.subTest(change=change),tempfile.TemporaryDirectory() as folder:
    root,snap,frame=self.fixture(folder);cp.save(snap,root,'DeepDesert',frame,native=True)
    if change=='reader':(root/cp.READERS[0]).write_text('changed')
    elif change=='server':(root/'remote.ps1').write_text('another server')
    else:(root/'runtime-context.json').write_text(json.dumps({'sha256':'new-build'}))
    self.assertEqual(cp.restore(snap,root),{})
 def test_mismatched_process_feed_cannot_restore(self):
  with tempfile.TemporaryDirectory() as folder:
   root,snap,frame=self.fixture(folder);cp.save(snap,root,'DeepDesert',frame,native=True)
   cp.save(snap,root,'DeepDesert',{**frame,'startTime':'another process'})
   self.assertNotIn('wormFeed',cp.restore(snap,root))
 def test_corrupt_and_future_checkpoint_do_not_replace_success(self):
  with tempfile.TemporaryDirectory() as folder:
   root,snap,frame=self.fixture(folder);cp.save(snap,root,'DeepDesert',frame,native=True)
   path=snap/'last-native-DeepDesert.json';before=path.read_bytes()
   cp.save(snap,root,'DeepDesert',{**frame,'capturedAt':'2099-01-01T00:00:00+00:00'},native=True)
   self.assertEqual(path.read_bytes(),before)
   path.write_text('{broken');self.assertEqual(cp.restore(snap,root),{})
 def test_position_writes_are_throttled_and_failed_reads_cannot_replace_file(self):
  with tempfile.TemporaryDirectory() as folder:
   root,snap,frame=self.fixture(folder)
   with patch.object(cp.time,'monotonic',return_value=100):cp.save(snap,root,'DeepDesert',frame)
   path=snap/'last-positions-DeepDesert.json';before=path.read_bytes()
   with patch.object(cp.time,'monotonic',return_value=101):cp.save(snap,root,'DeepDesert',{**frame,'items':['new']})
   self.assertEqual(path.read_bytes(),before)
 def test_warm_native_candidates_are_available_for_fast_process_revalidation(self):
  with tempfile.TemporaryDirectory() as folder:
   root,snap,frame=self.fixture(folder)
   (root/'hagga/native-snapshot-current.json').write_text(json.dumps(frame))
   self.assertEqual(cp.restore(snap,root)['haggaNative']['capturedAt'],frame['capturedAt'])
 def test_newer_native_discovery_does_not_hide_last_successful_positions(self):
  with tempfile.TemporaryDirectory() as folder:
   root,snap,frame=self.fixture(folder)
   cp.save(snap,root,'DeepDesert',frame,native=True);cp.save(snap,root,'DeepDesert',{**frame,'items':[{'id':20}]})
   newer={**frame,'capturedAt':datetime.datetime.now(datetime.timezone.utc).isoformat()}
   (root/'native-snapshot-current.json').write_text(json.dumps(newer))
   restored=cp.restore(snap,root)
   self.assertEqual(restored['native']['capturedAt'],newer['capturedAt'])
   self.assertEqual(restored['wormFeed']['capturedAt'],frame['capturedAt'])

if __name__=='__main__':unittest.main()
