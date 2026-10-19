from pathlib import Path
import ast,importlib.util,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]/'app/tools/DuneAtlas'
def module(name):
 spec=importlib.util.spec_from_file_location(name,ROOT/(name+'.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
prefs=module('atlas_preferences');assets=module('atlas_assets')
class RefreshTests(unittest.TestCase):
 def test_remote_collection_actions_are_denied_before_shared_state_changes(self):
  import io,json,types,urllib.parse
  tree=ast.parse((ROOT/'server.py').read_text(encoding='utf-8'))
  handler=next(n for n in tree.body if isinstance(n,ast.ClassDef) and n.name=='Handler')
  method=next(n for n in handler.body if isinstance(n,ast.FunctionDef) and n.name=='do_POST')
  scope={'urllib':types.SimpleNamespace(parse=urllib.parse),'KEY':'fixture','json':json,'live_enabled':True,'refresh_generation':7,'refresh_required':{'db'},'refresh_background':{'bases'}}
  exec(compile(ast.Module(body=[method],type_ignores=[]),'remote-control','exec'),scope)
  for path in ['/live/stop','/refresh']:
   errors=[]
   request=types.SimpleNamespace(path=path+'?key=fixture',server=types.SimpleNamespace(server_port=1234),headers={'Host':'127.0.0.1:1234','Content-Type':'application/json','Content-Length':'2','X-DST-Atlas-Timing':'remote'},rfile=io.BytesIO(b'{}'),send_error=lambda *args:errors.append(args))
   scope['do_POST'](request)
   self.assertEqual(errors[0][0],403)
   self.assertTrue(scope['live_enabled'])
   self.assertEqual(scope['refresh_generation'],7)
   self.assertEqual(scope['refresh_required'],{'db'})
   self.assertEqual(scope['refresh_background'],{'bases'})

 def test_spice_sizes_round_trip_and_migrate_combined_layer(self):
  with tempfile.TemporaryDirectory() as folder:
   value={'region':'DeepDesert','layers':['worms','spice-medium','spice-small'],'refreshSeconds':3}
   self.assertEqual(prefs.save(folder,value),prefs.load(folder))
   self.assertEqual(prefs.load(folder)['layers'],['spice-medium','spice-small','worms'])
   self.assertEqual(prefs.validate({**value,'layers':['resources','worms']})['layers'],['spice-large','worms'])
   self.assertEqual(prefs.validate({**value,'layers':['worms']})['layers'],['worms'])
   self.assertEqual(prefs.validate({**value,'layers':['resources','spice-small']})['layers'],['spice-small'])

 def test_existing_selections_keep_current_timing(self):
  self.assertEqual(prefs.validate({'region':'DeepDesert','layers':['worms']})['refreshSeconds'],3)
 def test_speed_survives_new_session(self):
  with tempfile.TemporaryDirectory() as folder:
   prefs.save(folder,{'region':'DeepDesert','layers':['worms'],'refreshSeconds':60})
   self.assertEqual(prefs.load(folder)['refreshSeconds'],60)
 def test_only_bounded_refresh_values_are_allowed(self):
  for value in [0,-1,True,'1',2,3600,None]:
   with self.subTest(value=value),self.assertRaises(ValueError):prefs.validate({'region':'DeepDesert','layers':[],'refreshSeconds':value})
 def test_default_periods_and_minimum_discovery_periods(self):
  tree=ast.parse((ROOT/'server.py').read_text(encoding='utf-8'))
  chosen=[n for n in tree.body if (isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='JOB_PERIODS' for t in n.targets)) or (isinstance(n,ast.FunctionDef) and n.name=='job_period')]
  scope={'state':{'refreshSeconds':3}}
  exec(compile(ast.Module(body=chosen,type_ignores=[]),'periods','exec'),scope)
  for name,seconds in scope['JOB_PERIODS'].items():self.assertEqual(scope['job_period'](name),1 if name=='gathering' else seconds)
  scope['state']['refreshSeconds']=1
  self.assertEqual(scope['job_period']('positions'),1);self.assertEqual(scope['job_period']('gathering'),1)
  scope['state']['refreshSeconds']=60
  self.assertEqual(scope['job_period']('positions'),60);self.assertEqual(scope['job_period']('db'),60)
 def test_marker_bundle_contains_fallbacks_without_terrain(self):
  with tempfile.TemporaryDirectory() as folder:
   icons=assets.marker_icons(folder,ROOT/'icons')
   self.assertIn('game-lab.png',icons);self.assertTrue(icons['game-lab.png'].startswith('data:image/svg+xml;base64,'))
   self.assertTrue(all('layout' not in name and '..' not in name for name in icons))

 def test_transient_read_errors_keep_last_timestamped_observations(self):
  import threading,time,types
  tree=ast.parse((ROOT/'server.py').read_text(encoding='utf-8'))
  nodes=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in ('collect_native_once','collect_worms_once')]
  class Cancelled(Exception):pass
  def failed(*args):raise ValueError('temporary read failure')
  native={'pid':123,'capturedAt':'2026-10-18T00:00:00Z'}
  feed={'pid':123,'capturedAt':'2026-10-18T00:00:01Z'}
  scope={'ROOT':ROOT,'time':time,'lock':threading.RLock(),'state':{'native':native,'wormFeed':feed},'atlas_runtime':types.SimpleNamespace(collect_native=failed),'atlas_process':types.SimpleNamespace(Cancelled=Cancelled),'worm_readers':{'DeepDesert':types.SimpleNamespace(read=failed)}}
  exec(compile(ast.Module(body=nodes,type_ignores=[]),'observers','exec'),scope)
  scope['collect_native_once']();scope['collect_worms_once']()
  self.assertIs(scope['state']['native'],native);self.assertIs(scope['state']['wormFeed'],feed)
  self.assertIn('temporary read failure',scope['state']['nativeError'])
  self.assertIn('temporary read failure',scope['state']['wormError'])

if __name__=='__main__':unittest.main()
