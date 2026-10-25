"""Multiple authenticated viewers retain independent choices and shared demand."""
import json
import tempfile
import threading
import unittest
import urllib.request
from pathlib import Path
from test_live import service


class ViewerPreferenceTests(unittest.TestCase):
    def test_accounts_local_host_tabs_and_expiry_are_isolated(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            value=service(root/'bundle',root/'settings')
            clock=[100.0];value.viewers.clock=lambda:clock[0]
            http=value.ThreadingHTTPServer(('127.0.0.1',0),value.Handler)
            thread=threading.Thread(target=http.serve_forever);thread.start()
            def request(user,path,payload=None,viewer='browser-viewer-0001',local=False):
                headers={'Content-Type':'application/json','X-DST-Atlas-User':user,
                         'X-DST-Atlas-Viewer':viewer,'X-DST-Atlas-Timing':'local' if local else 'remote'}
                req=urllib.request.Request(f'http://127.0.0.1:{http.server_port}/{path}?key={value.KEY}',
                    data=None if payload is None else json.dumps(payload).encode(),headers=headers)
                with urllib.request.urlopen(req,timeout=3) as response:return json.load(response)
            a={'region':'HaggaBasin','layers':['poi:resource:TitaniumOre','poi:lab'],'refreshSeconds':60}
            b={'region':'DeepDesert','layers':['poi:resource:StravidiumOre'],'refreshSeconds':1}
            try:
                request('account-a','preferences',a)
                request('account-b','preferences',b)
                self.assertEqual(request('account-a','preferences')['layers'],sorted(a['layers']))
                self.assertEqual(request('account-b','preferences')['layers'],b['layers'])
                self.assertEqual(value.state['refreshSeconds'],3)
                union={('HaggaBasin','TitaniumOre'),('DeepDesert','StravidiumOre')}
                self.assertEqual(value.gathering_queue.selected,union)
                # Same viewer token from another account cannot release A.
                request('account-b','viewer',{'active':False})
                self.assertEqual(value.gathering_queue.selected,{('HaggaBasin','TitaniumOre')})
                request('account-b','state')
                request('local-host','preferences',{'region':'HaggaBasin','layers':['poi:resource:AzuriteOre'],'refreshSeconds':5},local=True)
                self.assertEqual(value.gathering_queue.selected,union|{('HaggaBasin','AzuriteOre')})
                self.assertEqual(request('account-a','preferences')['refreshSeconds'],5)
                # A second device restores A's choices; one closed tab does not remove its peer.
                request('account-a','state',viewer='another-device-0002')
                request('account-a','viewer',{'active':False})
                self.assertIn(('HaggaBasin','TitaniumOre'),value.gathering_queue.selected)
                clock[0]+=20;request('account-b','state')
                clock[0]+=11
                with value.control:value.sync_viewer_demand()
                self.assertEqual(value.gathering_queue.selected,{('DeepDesert','StravidiumOre')})
                self.assertEqual(request('account-a','preferences')['layers'],sorted(a['layers']))
                # Reading saved choices alone does not create a viewer lease.
                self.assertEqual(value.gathering_queue.selected,{('DeepDesert','StravidiumOre')})
                request('account-b','viewer',{'active':False})
                self.assertEqual(value.gathering_queue.selected,set())
                recovered=service(root/'restarted',root/'settings')
                self.assertEqual(recovered.atlas_preferences.load_user(root/'settings','account-a')['layers'],sorted(a['layers']))
                self.assertEqual(recovered.gathering_queue.selected,set())
            finally:
                http.shutdown();thread.join(3);http.server_close()

    def test_shared_legacy_choices_only_migrate_to_local_dst(self):
        import atlas_preferences
        with tempfile.TemporaryDirectory() as folder:
            old={'region':'HaggaBasin','layers':['poi:resource:TitaniumOre'],'refreshSeconds':3}
            atlas_preferences.save(folder,old)
            self.assertEqual(atlas_preferences.load_user(folder,'local-host'),old)
            self.assertIsNone(atlas_preferences.load_user(folder,'account-new'))
            with self.assertRaises(ValueError):atlas_preferences.load_user(folder,'../../other-user')


if __name__=='__main__':unittest.main()
