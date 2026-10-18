"""Base output survives runtime replacement; synthetic bases only."""
from pathlib import Path
import importlib.util,json,tempfile,unittest,sys,shutil,os,threading,urllib.request
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]/'app/tools/DuneAtlas'
sys.path.insert(0,str(ROOT))
spec=importlib.util.spec_from_file_location('base_renderer',ROOT/'base-miniatures.py');renderer=importlib.util.module_from_spec(spec);spec.loader.exec_module(renderer)
class BaseTests(unittest.TestCase):
 def source(self):
  return {'readOnly':'on','observedAt':'2026-10-18T08:00:00Z','totems':[{'id':'101','entity':'owner','name':'Test Base','map':'HaggaBasin','location':{'x':1,'y':2,'z':3},'claimCells':4}], 'pieces':[['building','owner',1,'Foundation',[0,0,0,0,0,0,1]]],'placeables':[]}
 def test_new_runtime_serves_persisted_base_image_and_full_json(self):
  with tempfile.TemporaryDirectory() as f:
   root=Path(f);shared=root/'snapshots';runtime=root/'runtime';runtime.mkdir();renderer.build(self.source(),shared)
   shutil.copyfile(ROOT/'server.py',runtime/'server.py')
   with patch.dict(os.environ,{'DST_ATLAS_APP_ROOT':str(runtime),'DST_ATLAS_SNAPSHOT_ROOT':str(shared),'DST_ATLAS_PREFERENCES_ROOT':str(root/'preferences')}):
    spec=importlib.util.spec_from_file_location('base_service',runtime/'server.py');service=importlib.util.module_from_spec(spec);spec.loader.exec_module(service)
   self.assertEqual(service.state['baseModels']['models']['101']['pieceCount'],1)
   http=service.ThreadingHTTPServer(('127.0.0.1',0),service.Handler);worker=threading.Thread(target=http.serve_forever);worker.start()
   try:
    def get(suffix):return urllib.request.urlopen(f'http://127.0.0.1:{http.server_port}/bases/101.{suffix}?key={service.KEY}',timeout=3)
    with get('svg') as r:self.assertIn(b'<polygon',r.read())
    with get('json') as r:
     data=json.load(r);self.assertEqual(data['pieces'][0][3],'Foundation');self.assertEqual(data['claimCells'],4);self.assertEqual(data['placeables'],[])
   finally:http.shutdown();worker.join(3);http.server_close()
 def test_empty_base_still_has_data(self):
  with tempfile.TemporaryDirectory() as f:
   source=self.source();source['pieces']=[];value=renderer.build(source,f)
   self.assertEqual(value['models']['101']['pieceCount'],0)
   self.assertTrue((Path(f)/'bases/101.json').exists())
 def test_upgrade_recovers_json_and_image_from_prior_runtime_query(self):
  with tempfile.TemporaryDirectory() as f:
   root=Path(f);legacy=root/'runtimes'/'old';legacy.mkdir(parents=True);current=root/'runtimes'/'new';current.mkdir();shared=root/'snapshots'
   (legacy/'base-models-query.json').write_text(json.dumps({'rows':[[json.dumps(self.source())]]}),encoding='utf-8')
   for name in ['server.py','base-miniatures.py']:shutil.copyfile(ROOT/name,current/name)
   with patch.dict(os.environ,{'DST_ATLAS_APP_ROOT':str(current),'DST_ATLAS_SNAPSHOT_ROOT':str(shared),'DST_ATLAS_PREFERENCES_ROOT':str(root/'preferences')}):
    spec=importlib.util.spec_from_file_location('base_upgrade_service',current/'server.py');service=importlib.util.module_from_spec(spec);spec.loader.exec_module(service)
   self.assertEqual(service.state['baseModels']['models']['101']['name'],'Test Base')
   self.assertTrue((shared/'bases/101.svg').exists());self.assertTrue((shared/'bases/101.json').exists())
   self.assertTrue((legacy/'base-models-query.json').exists())
if __name__=='__main__':unittest.main()
