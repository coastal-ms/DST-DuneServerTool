from pathlib import Path
import datetime,importlib.util,json,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]/'app/tools/DuneAtlas'
spec=importlib.util.spec_from_file_location('history',ROOT/'atlas_history.py');history=importlib.util.module_from_spec(spec);spec.loader.exec_module(history)
class HistoryTests(unittest.TestCase):
 def test_version_change_retains_observed_trail_and_profile(self):
  with tempfile.TemporaryDirectory() as folder:
   legacy=Path(folder)/'old-runtime';legacy.mkdir();shared=Path(folder)/'snapshots'
   frame={'pid':17,'startTime':29,'capturedAt':'2026-10-17T12:00:00+00:00','storms':[{'id':'storm1','location':[1,2,3]}]}
   (legacy/'storm-position-observations.jsonl').write_text(json.dumps(frame)+'\n',encoding='utf-8')
   (legacy/'storm-zone-profiles.json').write_text(json.dumps({'17:29:storm1':{'zones':[]}}),encoding='utf-8')
   frames,profiles=history.load(shared,[legacy]);history.save(shared,frames,profiles)
   self.assertEqual(history.load(shared),([frame],profiles));self.assertIn('17:29:storm1',profiles)
 def test_history_is_bounded_deduplicated_and_rejects_invalid_coordinates(self):
  with tempfile.TemporaryDirectory() as folder:
   base=datetime.datetime(2026,10,17,tzinfo=datetime.timezone.utc)
   frames=[{'pid':1,'startTime':2,'capturedAt':(base+datetime.timedelta(seconds=n)).isoformat(),'storms':[{'id':'s','location':[1,2,3]}]} for n in range(510)]
   frames.append({'pid':1,'startTime':2,'capturedAt':base.isoformat(),'storms':[{'id':'s','location':[float('nan'),2,3]}]})
   history.save(folder,frames,{});loaded,_=history.load(folder,[folder]);self.assertLessEqual(len(loaded),125)
   self.assertTrue(loaded);self.assertTrue(all(f['storms'][0]['location']==[1,2,3] for f in loaded))
 def test_dense_current_pass_keeps_previous_pass_for_each_map(self):
  base=datetime.datetime(2026,10,17,tzinfo=datetime.timezone.utc)
  frames=[]
  for region in ('DeepDesert','HaggaBasin'):
   for storm in range(3):
    for n in range(200):
     frames.append({'map':region,'pid':1,'startTime':2,'capturedAt':(base+datetime.timedelta(seconds=storm*4000+n)).isoformat(),'storms':[{'id':str(storm),'location':[1,2,3]}]})
  retained=history.compact(frames)
  self.assertEqual(len(retained),500)
  for region in ('DeepDesert','HaggaBasin'):
   self.assertEqual({s['id'] for f in retained if f['map']==region for s in f['storms']},{'1','2'})
if __name__=='__main__':unittest.main()
