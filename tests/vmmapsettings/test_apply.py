"""Exercise the real jq/shell transaction with a simulated Kubernetes API/operator."""
import copy, hashlib, json, os, pathlib, subprocess, tempfile, unittest
SOURCE = pathlib.Path(__file__).resolve().parents[2] / 'app/tools/VmMapSettings/apply.sh'
def digest(text): return hashlib.sha256(text.encode()).hexdigest()
MOUNT = '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer'
FAKE = '''#!/usr/bin/python3
import json, os, pathlib, sys
p=pathlib.Path(os.environ['KUBE_STATE']); s=json.loads(p.read_text()); a=sys.argv[1:]
if a[:2]==['get','battlegroups']: print(json.dumps({'items':[s['bg']]}))
elif a[:2]==['get','configmap']:
 s['reads']=s.get('reads',0)+1
 if s.get('changeStore') and s['reads']>1: s['store']['metadata']['resourceVersion']='99'
 print(json.dumps(s['store']))
elif a[:2]==['get','pods']: print(json.dumps({'items':s.get('pods',[])}))
elif a[:2]==['patch','battlegroup']:
 patch=json.loads(pathlib.Path(next(x.split('=',1)[1] for x in a if x.startswith('--patch-file='))).read_text())
 assert patch[0]['value']==s['bg']['metadata']['uid']
 assert patch[1]['value']==s['bg']['spec']
 s['bg']['spec']['serverGroup']['template']['spec']['sets']=patch[2]['value']
 s['patches']=s.get('patches',0)+1
else: raise SystemExit('Unexpected kubectl: '+str(a))
p.write_text(json.dumps(s))
'''
class ApplyTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(); self.root=pathlib.Path(self.temp.name)
  # Substitute only executable discovery to put the fake Kubernetes API on PATH.
  self.script=self.root/'apply.sh'; self.script.write_text(SOURCE.read_text().replace('export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin','export PATH="'+str(self.root)+':/usr/sbin:/usr/bin:/sbin:/bin"'))
  k=self.root/'kubectl';k.write_text(FAKE);k.chmod(0o755)
  sets=[{'map':'Survival_1','arguments':['preserve']},{'map':'DeepDesert_1','podSpecs':[{'index':8,'arguments':['dd'],'userIniConfig':{'mountPath':MOUNT,'files':{'Engine.ini':'manual'}}}]}]
  self.state={'bg':{'metadata':{'uid':'world-uid','namespace':'test','name':'world'},'spec':{'stop':True,'serverGroup':{'template':{'spec':{'global':{'manual':'keep'},'sets':sets}}},'database':{'template':{'spec':{'deployment':{'spec':{'worldPartitions':[{'map':'Survival_1','partitions':[{'id':1},{'id':17}]},{'map':'DeepDesert_1','partitions':[{'id':8},{'id':21}]}]}}}}}}},'store':{'metadata':{'resourceVersion':'1'},'data':{'worldUid':'world-uid','enabled':'true'}},'pods':[]}
  self.file=self.root/'state.json'
 def tearDown(self): self.temp.cleanup()
 def entry(self,part=8,map='DeepDesert_1',raw='[Custom]\nCraftingCost=0.8\n',inherit=False,base=None):
  self.state['store']['data'][f'partition-{part}.json']=json.dumps({'schema':1,'worldUid':'world-uid','map':map,'partition':part,'inherit':inherit,'raw':raw,'baseAppliedHash':base or digest('inherit')})
 def run_apply(self,mode='--stopped',ok=True):
  self.file.write_text(json.dumps(self.state)); env=dict(os.environ,KUBE_STATE=str(self.file))
  result=subprocess.run(['sh',str(self.script)]+([mode] if mode else []),env=env,text=True,capture_output=True)
  self.state=json.loads(self.file.read_text())
  self.assertEqual(result.returncode==0,ok,result.stdout+result.stderr)
  return result
 def test_save_store_is_independent_and_apply_preserves_other_files(self):
  before=copy.deepcopy(self.state['bg']);self.entry();self.assertEqual(before,self.state['bg'])
  self.run_apply();self.assertEqual(self.state['patches'],1)
  pod=self.state['bg']['spec']['serverGroup']['template']['spec']['sets'][1]['podSpecs'][0]
  self.assertEqual(pod['userIniConfig']['files']['Engine.ini'],'manual');self.assertEqual(pod['arguments'],['dd'])
  self.assertEqual(before['spec']['serverGroup']['template']['spec']['sets'][0],self.state['bg']['spec']['serverGroup']['template']['spec']['sets'][0])
  self.run_apply();self.assertEqual(self.state['patches'],1)
 def test_requires_explicit_context(self): self.entry();self.run_apply(None,False);self.assertNotIn('patches',self.state)
 def test_running_bg_rejected_by_start_guard(self): self.entry();self.state['bg']['spec']['stop']=False;self.run_apply(ok=False);self.assertNotIn('patches',self.state)
 def test_remaining_pods_block_start(self): self.entry();self.state['pods']=[{'metadata':{'uid':'unchanged'}}];self.run_apply(ok=False);self.assertNotIn('patches',self.state)
 def test_requested_maintenance_applies_while_running(self): self.entry();self.state['bg']['spec']['stop']=False;self.run_apply('--maintenance');self.assertEqual(self.state['patches'],1)
 def test_all_entries_validate_before_single_atomic_write(self):
  self.entry();self.entry(17,'Survival_1',base=digest('manual-conflict'));self.run_apply(ok=False);self.assertNotIn('patches',self.state)
 def test_store_concurrency_blocks_write(self): self.entry();self.state['changeStore']=True;self.run_apply(ok=False);self.assertNotIn('patches',self.state)
 def test_disabled_management_does_not_apply(self): self.entry();self.state['store']['data']['enabled']='false';self.run_apply();self.assertNotIn('patches',self.state)
 def test_removed_partition_not_applied(self): self.entry(99);self.run_apply();self.assertNotIn('patches',self.state)
 def test_multiple_maps_and_partitions_one_atomic_patch(self):
  for part,map in [(1,'Survival_1'),(17,'Survival_1'),(8,'DeepDesert_1'),(21,'DeepDesert_1')]: self.entry(part,map)
  self.run_apply();self.assertEqual(self.state['patches'],1)
  sets=self.state['bg']['spec']['serverGroup']['template']['spec']['sets'];self.assertEqual([len(s['podSpecs']) for s in sets],[2,2])
 def test_wrong_world_rejected(self): self.entry();self.state['store']['data']['worldUid']='other';self.run_apply(ok=False);self.assertNotIn('patches',self.state)
 def test_ambiguous_set_rejected(self): self.entry();self.state['bg']['spec']['serverGroup']['template']['spec']['sets'].append({'map':'DeepDesert_1'});self.run_apply(ok=False);self.assertNotIn('patches',self.state)
 def test_inheritance_keeps_other_ini_and_arguments(self):
  pod=self.state['bg']['spec']['serverGroup']['template']['spec']['sets'][1]['podSpecs'][0];pod['userIniConfig']['files']['ServerCustomSettings.ini']='old\n'
  self.entry(inherit=True,base=digest('override:old\n'));self.run_apply()
  pod=self.state['bg']['spec']['serverGroup']['template']['spec']['sets'][1]['podSpecs'][0];self.assertEqual(pod['userIniConfig']['files'],{'Engine.ini':'manual'});self.assertEqual(pod['arguments'],['dd'])
if __name__=='__main__': unittest.main()
