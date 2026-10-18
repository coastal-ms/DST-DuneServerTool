"""Use real observer subprocesses to verify stop and timeout cleanup."""
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import importlib.util
import json
import os
import shutil
import urllib.request
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'app/tools/DuneAtlas'))
import atlas_process as observer


class ProcessTests(unittest.TestCase):
    def setUp(self):
        observer.reset()

    def test_capture_and_nonzero_exit(self):
        result = observer.run([sys.executable, '-c', 'print("read");raise SystemExit(7)'],
                              capture_output=True, text=True, timeout=5)
        self.assertEqual((result.returncode, result.stdout.strip()), (7, 'read'))

    def test_cancel_stops_descendant_and_prevents_further_launches(self):
        with tempfile.TemporaryDirectory() as folder:
            marker = Path(folder) / 'descendant-survived'
            ready = Path(folder) / 'ready'
            child = f'import time;from pathlib import Path;time.sleep(1.5);Path({str(marker)!r}).write_text("bad")'
            parent = ('import subprocess,sys,time;from pathlib import Path;'
                      f'subprocess.Popen([sys.executable,"-c",{child!r}]);'
                      f'Path({str(ready)!r}).write_text("ready");time.sleep(60)')
            errors = []
            def collect():
                try:
                    observer.run([sys.executable, '-c', parent], capture_output=True, timeout=60)
                except observer.Cancelled as error:
                    errors.append(error)
            thread = threading.Thread(target=collect)
            thread.start()
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue(ready.exists())
            observer.cancel()
            thread.join(6)
            self.assertFalse(thread.is_alive())
            self.assertEqual(len(errors), 1)
            with self.assertRaises(observer.Cancelled):
                observer.run([sys.executable, '-c', 'raise SystemExit(99)'], timeout=5)
            time.sleep(1.6)
            self.assertFalse(marker.exists())
            observer.reset()
            self.assertEqual(observer.run([sys.executable, '-c', 'pass'], timeout=5).returncode, 0)

    def test_timeout_is_bounded(self):
        started = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            observer.run([sys.executable, '-c', 'import time;time.sleep(60)'],
                         capture_output=True, timeout=.3)
        self.assertLess(time.monotonic() - started, 6)

    def test_http_stop_cancels_active_scan_and_can_start_again(self):
        root = Path(__file__).resolve().parents[2] / 'app/tools/DuneAtlas'
        with tempfile.TemporaryDirectory() as folder:
            shutil.copyfile(root / 'server.py', Path(folder) / 'server.py')
            with patch.dict(os.environ, {'DST_ATLAS_APP_ROOT': folder,
                                       'DST_ATLAS_SNAPSHOT_ROOT': folder,
                                       'DST_ATLAS_PREFERENCES_ROOT': folder}):
                spec = importlib.util.spec_from_file_location('stop_fixture', Path(folder) / 'server.py')
                service = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(service)
            http = service.ThreadingHTTPServer(('127.0.0.1', 0), service.Handler)
            http_thread = threading.Thread(target=http.serve_forever)
            http_thread.start()
            began = threading.Event()
            def scan():
                began.set()
                observer.run([sys.executable, '-c', 'import time;time.sleep(60)'], timeout=65)
            worker = threading.Thread(target=service.collection_worker, args=('gathering', scan))
            worker.start()
            def request(path):
                url = f'http://127.0.0.1:{http.server_port}/{path}?key={service.KEY}'
                with urllib.request.urlopen(urllib.request.Request(url, data=b'{}',
                        headers={'Content-Type': 'application/json'}), timeout=3) as response:
                    return json.load(response)
            try:
                self.assertTrue(request('live/start')['live'])
                self.assertTrue(began.wait(3))
                started = time.monotonic()
                self.assertFalse(request('live/stop')['live'])
                deadline = time.monotonic() + 6
                while service.state['stopping'] and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertFalse(service.state['stopping'])
                self.assertFalse(service.state['refreshing'])
                self.assertEqual(service.state['activity'], [])
                self.assertLess(time.monotonic() - started, 6)
                began.clear()
                service.job_period = lambda name: .05
                self.assertTrue(request('live/start')['live'])
                self.assertTrue(began.wait(3))
                request('live/stop')
            finally:
                service.stop.set()
                observer.cancel()
                with service.control:
                    service.control.notify_all()
                worker.join(6)
                http.shutdown()
                http_thread.join(3)
                http.server_close()


    def test_live_restart_requests_fresh_positions_without_old_cooldown(self):
        root = Path(__file__).resolve().parents[2] / 'app/tools/DuneAtlas'
        with tempfile.TemporaryDirectory() as folder:
            shutil.copyfile(root / 'server.py', Path(folder) / 'server.py')
            with patch.dict(os.environ, {'DST_ATLAS_APP_ROOT': folder, 'DST_ATLAS_SNAPSHOT_ROOT': folder, 'DST_ATLAS_PREFERENCES_ROOT': folder}):
                spec = importlib.util.spec_from_file_location('resume_fixture', Path(folder) / 'server.py')
                service = importlib.util.module_from_spec(spec); spec.loader.exec_module(service)
            service.job_period = lambda name: 60
            service.capture_static_files = lambda: None
            http = service.ThreadingHTTPServer(('127.0.0.1', 0), service.Handler)
            thread = threading.Thread(target=http.serve_forever); thread.start()
            read = threading.Event()
            worker = threading.Thread(target=service.collection_worker, args=('positions', read.set)); worker.start()
            def request(path):
                req = urllib.request.Request(f'http://127.0.0.1:{http.server_port}/{path}?key={service.KEY}', data=b'{}', headers={'Content-Type': 'application/json'})
                with urllib.request.urlopen(req, timeout=3) as response: return json.load(response)
            try:
                request('live/start'); self.assertTrue(read.wait(2))
                first_started = service.state['liveStartedAt']
                request('live/start'); self.assertEqual(service.state['liveStartedAt'], first_started)
                request('live/stop')
                deadline = time.monotonic() + 2
                while service.state['stopping'] and time.monotonic() < deadline: time.sleep(.01)
                read.clear(); request('live/start')
                self.assertTrue(read.wait(2), 'Resume waited for the previous 60-second period')
                self.assertNotEqual(service.state['liveStartedAt'], first_started)
            finally:
                service.stop.set()
                with service.control: service.control.notify_all()
                worker.join(3); http.shutdown(); thread.join(3); http.server_close()

    def test_snapshot_deadline_cancels_stalled_discovery_and_allows_retry(self):
        root = Path(__file__).resolve().parents[2] / 'app/tools/DuneAtlas'
        with tempfile.TemporaryDirectory() as folder:
            shutil.copyfile(root / 'server.py', Path(folder) / 'server.py')
            with patch.dict(os.environ, {'DST_ATLAS_APP_ROOT': folder,
                                       'DST_ATLAS_SNAPSHOT_ROOT': folder,
                                       'DST_ATLAS_PREFERENCES_ROOT': folder}):
                spec = importlib.util.spec_from_file_location('refresh_fixture', Path(folder) / 'server.py')
                service = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(service)
            service.SNAPSHOT_TIMEOUT = .6
            http = service.ThreadingHTTPServer(('127.0.0.1', 0), service.Handler)
            http_thread = threading.Thread(target=http.serve_forever)
            http_thread.start()
            began = threading.Event()
            stall = [True]
            def scan():
                if stall[0]:
                    began.set()
                    observer.run([sys.executable, '-c', 'import time;time.sleep(60)'], timeout=65)
            workers = []
            for name in service.JOB_PERIODS:
                worker = threading.Thread(target=service.collection_worker,
                    args=(name, scan if name == 'native' else lambda: None))
                worker.start(); workers.append(worker)
            def request():
                url = f'http://127.0.0.1:{http.server_port}/refresh?key={service.KEY}'
                with urllib.request.urlopen(urllib.request.Request(url, data=b'{"gathering":true}',
                        headers={'Content-Type': 'application/json'}), timeout=3) as response:
                    return json.load(response)
            try:
                service.state['snapshot'] = {'preserved': True}
                self.assertTrue(request()['refreshing'])
                self.assertTrue(began.wait(3))
                deadline = time.monotonic() + 6
                while (service.state['refreshing'] or service.state['stopping']) and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertFalse(service.state['refreshing'])
                self.assertFalse(service.state['stopping'])
                self.assertIn('timed out', service.state['refreshError'])
                self.assertEqual(service.state['snapshot'], {'preserved': True})
                self.assertEqual(service.state['activity'], [])
                stall[0] = False
                request()
                deadline = time.monotonic() + 3
                while service.state['refreshing'] and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertFalse(service.state['refreshing'])
                self.assertIsNone(service.state['refreshError'])
                # An old deadline cannot cancel a newer/completed refresh.
                service.expire_snapshot(service.refresh_generation - 1)
                self.assertIsNone(service.state['refreshError'])
            finally:
                service.stop.set(); observer.cancel()
                with service.control: service.control.notify_all()
                for worker in workers: worker.join(6)
                http.shutdown(); http_thread.join(3); http.server_close()

    def test_optional_discovery_does_not_hold_snapshot_and_remote_cannot_change_timing(self):
        root = Path(__file__).resolve().parents[2] / 'app/tools/DuneAtlas'
        with tempfile.TemporaryDirectory() as folder:
            shutil.copyfile(root / 'server.py', Path(folder) / 'server.py')
            with patch.dict(os.environ, {'DST_ATLAS_APP_ROOT': folder,
                    'DST_ATLAS_SNAPSHOT_ROOT': folder, 'DST_ATLAS_PREFERENCES_ROOT': folder}):
                spec = importlib.util.spec_from_file_location('optional_fixture', Path(folder) / 'server.py')
                service = importlib.util.module_from_spec(spec); spec.loader.exec_module(service)
            http = service.ThreadingHTTPServer(('127.0.0.1', 0), service.Handler)
            thread = threading.Thread(target=http.serve_forever); thread.start()
            began = threading.Event(); release = threading.Event(); workers = []
            def discovery():
                began.set(); release.wait(5)
            def request(path, payload=None, access='local'):
                data = json.dumps(payload).encode() if payload is not None else None
                req = urllib.request.Request(f'http://127.0.0.1:{http.server_port}/{path}?key={service.KEY}',
                    data=data, headers={'Content-Type':'application/json','X-DST-Atlas-Timing':access})
                with urllib.request.urlopen(req, timeout=3) as response: return json.load(response)
            try:
                for name in service.JOB_PERIODS:
                    worker = threading.Thread(target=service.collection_worker,
                        args=(name, discovery if name == 'gathering' else lambda: None))
                    worker.start(); workers.append(worker)
                request('refresh', {'gathering':True})
                self.assertTrue(began.wait(2))
                deadline = time.monotonic()+2
                while service.state['refreshing'] and time.monotonic()<deadline: time.sleep(.01)
                self.assertFalse(service.state['refreshing'])
                self.assertIn('gathering', service.state['activity'])
                self.assertIsNone(service.state['refreshError'])
                with service.lock:
                    self.assertTrue((Path(folder)/'static-state-seed.json').exists())
                self.assertFalse(request('state', access='remote')['canControlTiming'])
                prefs = {'region':'HaggaBasin','layers':['worms'],'refreshSeconds':1}
                self.assertEqual(request('preferences', prefs, 'remote')['refreshSeconds'], 3)
                self.assertEqual(service.state['refreshSeconds'],3)
                self.assertEqual(request('preferences', prefs)['refreshSeconds'],1)
                self.assertEqual(request('preferences', {**prefs,'refreshSeconds':60}, 'remote')['refreshSeconds'],1)
                request('live/start', {})
                self.assertTrue(service.state['live'])
                request('live/stop', {})
            finally:
                release.set(); service.stop.set(); observer.cancel()
                with service.control: service.control.notify_all()
                for worker in workers: worker.join(6)
                http.shutdown(); thread.join(3); http.server_close()

    def test_live_workers_bound_concurrency_and_rest_after_slow_reads(self):
        root=Path(__file__).resolve().parents[2]/'app/tools/DuneAtlas'
        with tempfile.TemporaryDirectory() as folder:
            shutil.copyfile(root/'server.py',Path(folder)/'server.py')
            with patch.dict(os.environ,{'DST_ATLAS_APP_ROOT':folder,'DST_ATLAS_SNAPSHOT_ROOT':folder,
                    'DST_ATLAS_PREFERENCES_ROOT':folder}):
                spec=importlib.util.spec_from_file_location('budget_fixture',Path(folder)/'server.py')
                service=importlib.util.module_from_spec(spec);spec.loader.exec_module(service)
            service.live_enabled=True;service.job_period=lambda name:.01
            counts={'active':0,'peak':0};starts={};ends={};guard=threading.Lock();workers=[]
            def observe(name):
                with guard:
                    counts['active']+=1;counts['peak']=max(counts['peak'],counts['active'])
                    starts.setdefault(name,[]).append(time.monotonic())
                time.sleep(.08 if name == "positions" else .45)
                with guard:
                    ends.setdefault(name,[]).append(time.monotonic());counts['active']-=1
            try:
                for name in ['positions','one','two','three']:
                    worker=threading.Thread(target=service.collection_worker,args=(name,lambda n=name:observe(n)))
                    worker.start();workers.append(worker)
                time.sleep(1.1)
            finally:
                service.stop.set()
                with service.control:service.control.notify_all()
                for worker in workers:worker.join(2)
            self.assertEqual(counts['peak'],2)
            self.assertGreaterEqual(len(starts.get('positions',[])),3)
            repeats=0
            for name,values in starts.items():
                for i in range(1,len(values)):
                    repeats+=1
                    self.assertGreaterEqual(values[i]-ends[name][i-1],.075)
            self.assertGreater(repeats,0)


if __name__ == '__main__':
    unittest.main()
