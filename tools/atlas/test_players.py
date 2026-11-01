"""Player lifecycle, bounded batch reads and role isolation."""
import datetime, gzip, importlib.util, json, struct, sys, tempfile, threading, types, unittest, urllib.request
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]/'app/tools/DuneAtlas'
sys.path.insert(0,str(ROOT))
import atlas_players as players
from test_live import service

class Memory:
    def __init__(self):
        self.cache={};self.data={};self.calls=[]
        self.context={'pid':7,'startTime':'11','sha256':'a'*64,'exeBase':100000}
    def read_many(self,requests):
        self.calls.append(list(requests))
        for request in requests:self.cache[request]=self.data[request]
        return [self.cache[r] for r in requests]

def actor(entity=99,root=300000,vtable=200000):
    b=bytearray(576);struct.pack_into('<Q',b,0,vtable);struct.pack_into('<q',b,200,entity);struct.pack_into('<Q',b,568,root);return b

def component(location=(1,2,3),parent=0,rotation=(0,0,0),scale=(1,1,1),absolute=0):
    b=bytearray(560);struct.pack_into('<Q',b,336,parent)
    for off,v in [(456,location),(480,rotation),(504,scale)]:struct.pack_into('<3d',b,off,*v)
    b[552]=absolute;return b

def fixture():
    m=Memory();m.data[(200000,576)]=actor();m.data[(300000,560)]=component()
    cache={**m.context,'players':[{'actor':200000,'root':300000,'entityId':'99','vtable':200000,'chain':[{'address':300000,'parent':0}]}]}
    wanted=[{'entityId':'99','name':'Fixture player'}]
    return m,cache,wanted

class PlayerTests(unittest.TestCase):
    def test_roster_change_queues_existing_discovery_without_polling_unchanged_players(self):
        with tempfile.TemporaryDirectory() as folder:
            value=service(Path(folder)/'bundle',Path(folder)/'settings')
            value.active_player_regions={'HaggaBasin'}
            snapshot={'readOnly':'on','observedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      'players':[{'entityId':'99','name':'Player','map':'HaggaBasin','dimension':0}]}
            (value.ROOT/'latest-query.json').write_text(json.dumps({'rows':[[json.dumps(snapshot)]],'durationMs':1}))
            with patch.object(value.atlas_process,'run',return_value=types.SimpleNamespace(returncode=0)):
                value.collect_once()
                self.assertIn('haggaNative',value.urgent_jobs)
                value.urgent_jobs.clear();value.waiting_jobs.clear()
                value.collect_once()
                self.assertNotIn('haggaNative',value.urgent_jobs)
                value.state['snapshot']=None;value.active_jobs.add('haggaNative')
                value.collect_once()
                self.assertNotIn('haggaNative',value.urgent_jobs)
                value.active_jobs.clear();value.active_player_regions.clear()
                value.state['snapshot']=None;value.collect_once()
                self.assertFalse(value.urgent_jobs)

    def test_joined_read_and_online_identity(self):
        m,c,w=fixture();m.read_many(players.requests(c,w));items,invalid=players.decode(m,c,w)
        self.assertFalse(invalid);self.assertEqual(items[0]['location'],(1,2,3));self.assertEqual(len(m.calls),1)
        self.assertEqual(players.decode(m,c,[]),([],False));self.assertEqual(players.requests(c,[]),[])
        self.assertEqual(players.decode(m,c,[{'entityId':'100','name':'Recreated'}]),([],True))
    def test_respawn_reparent_and_destroyed_pawns_never_reuse_old_coordinates(self):
        for change in ['root','entity','destroyed','vtable']:
            m,c,w=fixture()
            if change=='root':struct.pack_into('<Q',m.data[(200000,576)],568,400000)
            if change=='entity':struct.pack_into('<q',m.data[(200000,576)],200,100)
            if change=='destroyed':struct.pack_into('<I',m.data[(200000,576)],8,32)
            if change=='vtable':struct.pack_into('<Q',m.data[(200000,576)],0,200008)
            if change=='parent':struct.pack_into('<Q',m.data[(300000,560)],336,400000)
            m.read_many(players.requests(c,w));self.assertEqual(players.decode(m,c,w),([],True),change)
    def test_vehicle_entry_hides_dot_and_exit_updates_in_next_normal_batch(self):
        m,c,w=fixture()
        m.read_many(players.requests(c,w));self.assertEqual(len(players.decode(m,c,w)[0]),1)
        m.data[(300000,560)]=component((10,20,30),400000)
        c['players'][0]['chain'].append({'address':400000,'parent':0})
        m.cache.clear();m.read_many(players.requests(c,w))
        self.assertEqual(players.decode(m,c,w),([],False))
        self.assertNotIn((400000,560),m.calls[-1])
        m.data[(300000,560)]=component((100,200,300))
        m.cache.clear();m.read_many(players.requests(c,w))
        items,rediscover=players.decode(m,c,w)
        self.assertFalse(rediscover);self.assertEqual(items[0]['location'],(100,200,300))
        self.assertEqual(len(m.calls),3)
    def test_invalid_coordinate_is_not_drawn(self):
        m,c,w=fixture();m.data[(300000,560)]=component((float('nan'),0,0));m.read_many(players.requests(c,w));self.assertEqual(players.decode(m,c,w),([],True))
    def test_stale_unknown_duplicate_and_other_world_rosters(self):
        now=datetime.datetime.now(datetime.timezone.utc)
        row={'entityId':'99','name':'One','map':'HaggaBasin','dimension':0}
        snapshot={'observedAt':now.isoformat(),'players':[row]}
        self.assertEqual(players.roster(snapshot,'DeepDesert',now),[])
        self.assertEqual(players.roster(snapshot,'HaggaBasin',now)[0]['entityId'],'99')
        self.assertIsNone(players.roster(snapshot,'HaggaBasin',now+datetime.timedelta(seconds=31)))
        self.assertIsNone(players.roster({'observedAt':now.isoformat()},'HaggaBasin',now))
        snapshot['players'].append(row);self.assertIsNone(players.roster(snapshot,'HaggaBasin',now))
        snapshot['players']=[{**row,'dimension':1}];self.assertEqual(players.roster(snapshot,'HaggaBasin',now),[])
    def test_previous_process_and_oversized_cache_are_rejected(self):
        m,c,w=fixture()
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'player-actors.json';path.write_text(json.dumps(c))
            self.assertTrue(players.load_cache(folder,m.context))
            self.assertEqual(players.load_cache(folder,{**m.context,'startTime':'12'}),{})
            path.write_text(' '*1048577);self.assertEqual(players.load_cache(folder,m.context),{})
    def test_empty_roster_does_not_discover_or_read_memory(self):
        m=Memory()
        with patch.object(players.atlas_process,'run') as run:
            self.assertEqual(players.discover(m,{},[],Path('.'))['players'],[])
            run.assert_not_called();self.assertEqual(m.calls,[])
    def test_existing_same_entity_cache_avoids_actor_enumeration(self):
        m,c,w=fixture()
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder)/'player-actors.json').write_text(json.dumps(c))
            profile={'symbols':{players.PLAYER:99984}}
            with patch.object(players.atlas_builds,'profile',return_value=profile),patch.object(players.atlas_process,'run') as run:
                value=players.discover(m,{},w,folder)
                self.assertEqual(value['players'][0]['actor'],200000);run.assert_not_called()
    def test_fast_reader_shares_one_batch_and_disabled_layer_adds_no_reads(self):
        spec=importlib.util.spec_from_file_location('player_fast_test',ROOT/'worm-fast.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        for enabled,failed in ((True,False),(False,False),(True,True)):
            m,c,w=fixture();system=bytearray(64);struct.pack_into('<Q',system,0,500000);m.data[(400000,64)]=system
            context={**m.context,'needles':{'_ZTV18USandwormSubsystem':500000}}
            if failed:
                read=m.read_many
                def safe(requests):
                    if (200000,576) in requests:
                        m.calls.append(list(requests));raise RuntimeError('Player page unmapped')
                    return read(requests)
                m.read_many=safe
            native={'pid':7,'startTime':'11','systems':[{'name':'SandwormSubsystem','address':400000,'territories':{'count':0},'worms':[]}],'players':c['players']}
            with tempfile.TemporaryDirectory() as folder:
                (Path(folder)/'runtime-context.json').write_text(json.dumps(context));reader=module.WormReader(folder);reader.identity=(7,'11');reader.module=m
                result=reader.read(native,player_roster=w,player_enabled=enabled)
                self.assertEqual(len(m.calls),2 if failed else 1);self.assertEqual(len(result['players']),1 if enabled and not failed else 0)
                self.assertEqual(len(m.calls[0]),3 if enabled else 1)
                if failed:self.assertTrue(result['playerUnavailable']);self.assertEqual(result['pid'],7)
    def test_private_json_and_preferences_never_create_player_demand(self):
        source={'snapshot':{'players':[{'name':'Private','location':[1,2,3]}],'servers':[{'players':3}]},'native':{'players':[{'entityId':'99'}]},'wormFeed':{'players':[{'name':'Private'}]}}
        denied=players.public_state(source,False)
        self.assertNotIn('Private',json.dumps(denied));self.assertEqual(denied['snapshot']['servers'][0]['players'],3)
        prefs={'region':'HaggaBasin','layers':['players','worms']}
        self.assertEqual(players.requested_regions([players.viewer_preferences(prefs,False)]),set())
        self.assertEqual(players.requested_regions([prefs]),{'HaggaBasin'})
        self.assertEqual(players.public_state(source,True),source)
        self.assertEqual(players.viewer_preferences({'layers':None},False),{'layers':None})
    def test_http_role_filter_etags_gzip_and_forged_preferences(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);value=service(root/'bundle',root/'settings')
            value.state.update(snapshot={'players':[{'name':'Private','location':[1,2,3]}],'servers':[{'players':1}]},wormFeed={'players':[{'name':'Private','location':[1,2,3]}]},padding='x'*2000)
            server=value.ThreadingHTTPServer(('127.0.0.1',0),value.Handler);thread=threading.Thread(target=server.serve_forever);thread.start()
            def get(allowed,etag=None):
                headers={'X-DST-Atlas-Players':'allowed' if allowed else 'denied','Accept-Encoding':'gzip','X-DST-Atlas-Viewer':'fixture-browser-001'}
                if etag:headers['If-None-Match']=etag
                with urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{server.server_port}/state?key={value.KEY}',headers=headers),timeout=3) as response:
                    body=response.read();body=gzip.decompress(body) if response.headers.get('Content-Encoding')=='gzip' else body
                    return json.loads(body),response.headers['ETag']
            try:
                admin,etag=get(True);self.assertIn('Private',json.dumps(admin));self.assertTrue(admin['canSeePlayers'])
                denied,other=get(False,etag);self.assertNotIn('Private',json.dumps(denied));self.assertFalse(denied['canSeePlayers']);self.assertNotEqual(etag,other)
                prefs={'region':'HaggaBasin','layers':['players'],'refreshSeconds':3}
                headers={'X-DST-Atlas-Players':'allowed','X-DST-Atlas-Viewer':'fixture-browser-001','Content-Type':'application/json'}
                url=f'http://127.0.0.1:{server.server_port}/preferences?key={value.KEY}'
                with urllib.request.urlopen(urllib.request.Request(url,data=json.dumps(prefs).encode(),headers=headers)) as response:json.load(response)
                self.assertEqual(value.active_player_regions,{'HaggaBasin'})
                get(False)
                self.assertEqual(value.active_player_regions,set())
                headers['X-DST-Atlas-Players']='denied'
                with urllib.request.urlopen(urllib.request.Request(url,data=json.dumps(prefs).encode(),headers=headers)) as response:
                    self.assertNotIn('players',json.load(response)['layers'])
                self.assertEqual(value.active_player_regions,set())
            finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':unittest.main()
