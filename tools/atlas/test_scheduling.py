"""Priority and starvation regressions for selected resource collection."""
import importlib.util,json,os,shutil,sys,tempfile,threading,time,unittest,subprocess
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]/'app/tools/DuneAtlas'
sys.path.insert(0,str(ROOT))
import atlas_gathering,atlas_process

class SchedulingTests(unittest.TestCase):
 def test_pickups_and_brittlebush_are_not_collected_even_from_old_preferences(self):
  for name in ('BP_Titanium_Pickup_C','BP_Stravidium_Pickup_C','BP_BurroBush_C','BP_ScrapMetal_Pickup_C','BP_ImpureFuel_Pickup_C','BP_SietchStone_C'):
   self.assertIsNone(atlas_gathering.classify(name),name)
  self.assertEqual(atlas_gathering.classify('BP_TitaniumOre_C'),'TitaniumOre')
  self.assertEqual(atlas_gathering.classify('BP_Primrose_C'),'PrimroseField')
  self.assertEqual(atlas_gathering.classify('BP_Cistanche_C'),'CistanchePlant')
  q=atlas_gathering.Queue({'region':'DeepDesert','layers':['poi:resource:TitaniumPickup','poi:resource:BrittleBush','poi:resource:SietchStone']})
  self.assertEqual(q.selected,set())
  seen=set()
  while (key:=q.next()) is not None:seen.add(key[1]);q.finish(key)
  self.assertFalse(any('Pickup' in kind or kind in ('BrittleBush','ScrapMetalPart','FuelCellPart','SietchStone') for kind in seen))

 def test_saved_selection_first_then_new_selection_is_p0(self):
  now=[1000];q=atlas_gathering.Queue({'region':'HaggaBasin','layers':['poi:resource:StravidiumOre']},clock=lambda:now[0])
  self.assertEqual(q.next(),('HaggaBasin','StravidiumOre'))
  q.finish(q.next());q.update({'region':'HaggaBasin','layers':['poi:resource:StravidiumOre','poi:resource:TitaniumOre']})
  self.assertEqual(q.next(),('HaggaBasin','TitaniumOre'))
  q.finish(q.next());seen=set()
  for _ in range(len(atlas_gathering.KINDS)*2-2):
   key=q.next();self.assertNotIn(key,seen);seen.add(key);q.finish(key)
  self.assertIsNone(q.next())
  now[0]+=901;self.assertIn(q.next(),q.selected)
 def test_world_restart_requeues_selected_categories_without_touching_other_world(self):
  q=atlas_gathering.Queue({'region':'HaggaBasin','layers':['poi:resource:TitaniumOre']})
  q.finish(('HaggaBasin','TitaniumOre'));q.finish(('DeepDesert','TitaniumOre'));q.finish(('HaggaBasin','AzuriteOre'),False)
  q.reset_world('HaggaBasin')
  self.assertEqual(q.next(),('HaggaBasin','TitaniumOre'));self.assertIn(('DeepDesert','TitaniumOre'),q.finished);self.assertEqual(q.retry,{})
 def test_failed_category_does_not_block_other_selected_categories(self):
  q=atlas_gathering.Queue({'region':'DeepDesert','layers':['poi:resource:TitaniumOre','poi:resource:StravidiumOre']})
  first=q.next();q.finish(first,False);self.assertNotEqual(q.next(),first);self.assertIn(q.next(),q.selected)
 def test_stalled_optional_job_does_not_starve_database_or_either_position_feed(self):
  with tempfile.TemporaryDirectory() as folder:
   shutil.copyfile(ROOT/'server.py',Path(folder)/'server.py')
   with patch.dict(os.environ,{'DST_ATLAS_APP_ROOT':folder,'DST_ATLAS_SNAPSHOT_ROOT':folder,'DST_ATLAS_PREFERENCES_ROOT':folder}):
    spec=importlib.util.spec_from_file_location('scheduler_fixture',Path(folder)/'server.py');service=importlib.util.module_from_spec(spec);spec.loader.exec_module(service)
   service.live_enabled=True;service.job_period=lambda name:.02
   began=threading.Event();release=threading.Event();counts={};workers=[]
   def scan():began.set();release.wait(3)
   def observe(name):counts[name]=counts.get(name,0)+1;time.sleep(.01)
   try:
    for name in ('gathering','db','native','haggaNative','positions','haggaPositions'):
     worker=threading.Thread(target=service.collection_worker,args=(name,scan if name=='gathering' else lambda n=name:observe(n)));worker.start();workers.append(worker)
    self.assertTrue(began.wait(1));time.sleep(1.2)
    self.assertIn('gathering',service.active_jobs)
    for name in ('db','native','haggaNative','positions','haggaPositions'):self.assertGreaterEqual(counts.get(name,0),2,name)
   finally:
    release.set();service.stop.set()
    with service.control:service.control.notify_all()
    for worker in workers:worker.join(3)
 def test_resource_publish_preserves_other_categories_and_survives_upgrade(self):
  with tempfile.TemporaryDirectory() as folder:
   root=Path(folder)/'runtime';root.mkdir();shared=Path(folder)/'shared'
   shutil.copyfile(ROOT/'saved-pois.py',root/'saved-pois.py');shutil.copyfile(ROOT/'publish-gathering.py',root/'publish-gathering.py')
   (root/'runtime-context.json').write_text(json.dumps({'pid':123,'startTime':'45'}))
   def publish(kind,stamp,x):
    value={'kind':kind,'pid':123,'startTime':'45','capturedAt':stamp,'completedAt':stamp,'items':[{'id':kind,'actorName':'BP_'+kind,'location':{'x':x,'y':0,'z':0}}],'checks':[]}
    (root/'native-gathering-instances.json').write_text(json.dumps(value))
    result=subprocess.run([sys.executable,str(root/'publish-gathering.py')],env={**os.environ,'DST_ATLAS_SNAPSHOT_ROOT':str(shared)},capture_output=True,text=True)
    self.assertEqual(result.returncode,0,result.stderr)
   publish('TitaniumOre','2026-10-18T01:00:00+00:00',10);publish('StravidiumOre','2026-10-18T01:00:01+00:00',20)
   manifest=json.loads((shared/'gathering/DeepDesert/gathering-manifest.json').read_text())
   self.assertEqual(manifest['counts'],{'StravidiumOre':1,'TitaniumOre':1})
   self.assertEqual(manifest['categoryTimes']['TitaniumOre'],'2026-10-18T01:00:00+00:00')
   self.assertTrue((shared/'gathering/DeepDesert/gathering-data'/manifest['version']/'TitaniumOre.json').is_file())
   publish('AzuriteOre','2026-10-18T01:00:02+00:00',30)
   self.assertEqual(len(list((shared/'gathering/DeepDesert/gathering-data').iterdir())),2)
   self.assertEqual(len(list((root/'gathering-data').iterdir())),2)
 def test_bootstrap_identity_wait_does_not_penalize_selected_category(self):
  import ast,types
  with tempfile.TemporaryDirectory() as folder:
   root=Path(folder);(root/'runtime-context.json').write_text(json.dumps({'pid':0,'startTime':'0'}))
   q=atlas_gathering.Queue({'region':'DeepDesert','layers':['poi:resource:TitaniumOre']})
   tree=ast.parse((ROOT/'server.py').read_text(encoding='utf-8'));nodes=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='collect_gathering_once']
   scope={'gathering_queue':q,'ROOT':root,'json':json,'atlas_process':atlas_process,'atlas_runtime':types.SimpleNamespace(atlas_readers=types.SimpleNamespace(ensure=lambda r:self.fail('Must wait before helper reads')))}
   exec(compile(ast.Module(body=nodes,type_ignores=[]),'bootstrap','exec'),scope);scope['collect_gathering_once']()
   self.assertEqual(q.retry,{});self.assertEqual(q.next(),('DeepDesert','TitaniumOre'))
 def test_optional_io_yields_to_waiting_core_read(self):
  atlas_process.reset()
  with tempfile.TemporaryDirectory() as folder:
   entered=threading.Event();release=threading.Event();order=[];errors=[]
   def run(mode,label):
    try:
     with atlas_process.io_slot(['pwsh'],{'DST_ATLAS_IO_ROOT':folder,'DST_ATLAS_IO_PRIORITY':mode}):
      order.append(label)
      if label=='first':entered.set();release.wait(3)
    except Exception as e:errors.append(e)
   first=threading.Thread(target=run,args=('optional','first'));first.start();self.assertTrue(entered.wait(1))
   core=threading.Thread(target=run,args=('core','core'));core.start()
   deadline=time.monotonic()+1
   while not list(Path(folder).glob('core-wait-*')) and time.monotonic()<deadline:time.sleep(.01)
   other=threading.Thread(target=run,args=('optional','other'));other.start();time.sleep(.1);release.set()
   for worker in (first,core,other):worker.join(3);self.assertFalse(worker.is_alive())
   self.assertEqual(errors,[]);self.assertEqual(order,['first','core','other'])
 def test_promoting_resource_cancels_only_resource_observer(self):
  atlas_process.reset();started=threading.Event();errors=[]
  with tempfile.TemporaryDirectory() as folder:
   def observe():
    try:
     with atlas_process.priority('optional',folder,'gathering'):
      started.set();atlas_process.run([sys.executable,'-c','import time;time.sleep(60)'],timeout=65)
    except atlas_process.Cancelled:errors.append(True)
   worker=threading.Thread(target=observe);worker.start();self.assertTrue(started.wait(2));time.sleep(.1);atlas_process.cancel_job('gathering');worker.join(4)
   self.assertFalse(worker.is_alive());self.assertEqual(errors,[True])
   self.assertEqual(atlas_process.run([sys.executable,'-c','pass'],timeout=3).returncode,0)

if __name__=='__main__':unittest.main()
