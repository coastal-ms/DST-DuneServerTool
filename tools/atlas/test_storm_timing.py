from pathlib import Path
import datetime,sys,unittest,tempfile,types
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'app/tools/DuneAtlas'))
import atlas_storm_timing as timing
UTC=datetime.timezone.utc

def line(stamp,region='DeepDesert',prefix=''):
 text=stamp.strftime('%Y.%m.%d-%H.%M.%S:%f')[:-3]
 return f'[{text}][543][939][8]{prefix}LogSandStormManager: Log: Requested a Sandstorm auto-spawn on [{region}] Server 8 Dimension 0'

class StormTimingTests(unittest.TestCase):
 def test_selects_latest_automatic_spawn_for_this_world(self):
  now=datetime.datetime(2026,10,18,10,tzinfo=UTC);start=now.timestamp()-7200
  older=now-datetime.timedelta(minutes=50);latest=now-datetime.timedelta(minutes=10)
  text='PROCESSSTART '+str(start)+'\n'+line(latest)+'\n'+line(now,'HaggaBasin')+'\n'+line(older)
  self.assertEqual(timing.parse_anchor(text,'DeepDesert',now),latest.isoformat())
 def test_ignores_old_process_future_and_chat_injected_events(self):
  now=datetime.datetime(2026,10,18,10,tzinfo=UTC)
  text='PROCESSSTART '+str(now.timestamp()-3600)+'\n'+line(now-datetime.timedelta(hours=2))+'\n'+line(now+datetime.timedelta(minutes=1))+'\n'+line(now,prefix='LogChat: Player says ')
  self.assertIsNone(timing.parse_anchor(text,'DeepDesert',now))
  self.assertIsNone(timing.parse_anchor(line(now),'DeepDesert',now))
 def test_cycle_anchor_is_cached_and_rechecked_when_the_route_changes(self):
  with tempfile.TemporaryDirectory() as folder:
   root=Path(folder);memory=types.SimpleNamespace(ROOT=root,context={'pid':123,'startTime':'456'})
   now=datetime.datetime.now(UTC);stamp=now-datetime.timedelta(minutes=5);calls=[]
   def run(args,**kwargs):
    calls.append(args);output=Path(args[args.index('-OutputFile')+1]);output.write_text('PROCESSSTART '+str(now.timestamp()-3600)+'\n'+line(stamp));return types.SimpleNamespace(returncode=0)
   managers=[{'routeId':'10'}];first=timing.read_anchor(memory,managers,'DeepDesert',run)
   self.assertIn('lastSpawnAt',first);self.assertEqual(timing.read_anchor(memory,managers,'DeepDesert',run),first);self.assertEqual(len(calls),1)
   managers[0]['routeId']='11';timing.read_anchor(memory,managers,'DeepDesert',run);self.assertEqual(len(calls),2)
   self.assertFalse((root/'storm-cycle-log.cmd').exists());self.assertFalse((root/'storm-cycle-log.txt').exists())
 def test_missing_log_does_not_supply_a_fake_anchor(self):
  with tempfile.TemporaryDirectory() as folder:
   memory=types.SimpleNamespace(ROOT=Path(folder),context={'pid':123,'startTime':'456'})
   def run(args,**kwargs):return types.SimpleNamespace(returncode=1)
   self.assertEqual(timing.read_anchor(memory,[{'routeId':'10'}],'DeepDesert',run),{})

if __name__=='__main__':unittest.main()
