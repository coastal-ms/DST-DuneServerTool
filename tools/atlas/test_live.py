"""Live intent survives service/bundle recovery; only explicit controls change it."""
import importlib.util
import io
import os
import shutil
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2] / 'app/tools/DuneAtlas'
sys.path.insert(0, str(ROOT))
import atlas_live
import atlas_preferences


def service(root, settings):
    root.mkdir(exist_ok=True)
    shutil.copyfile(ROOT / 'server.py', root / 'server.py')
    with patch.dict(os.environ, {'DST_ATLAS_APP_ROOT': str(root), 'DST_ATLAS_SNAPSHOT_ROOT': str(root), 'DST_ATLAS_PREFERENCES_ROOT': str(settings)}):
        spec = importlib.util.spec_from_file_location('live_fixture', root / 'server.py')
        value = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(value)
    return value


def action(value, path):
    statuses = []
    request = types.SimpleNamespace(path=path+'?key='+value.KEY, server=types.SimpleNamespace(server_port=1234),
        headers={'Host':'127.0.0.1:1234','Content-Type':'application/json','Content-Length':'2'},
        rfile=io.BytesIO(b'{}'), wfile=io.BytesIO(), send_error=lambda code,*args: statuses.append(code),
        send_response=lambda code: statuses.append(code), send_header=lambda *args: None, end_headers=lambda: None)
    with patch.object(value.atlas_process, 'reset'), patch.object(value.atlas_process, 'cancel'), patch.object(value, 'capture_static_files'):
        value.Handler.do_POST(request)
    return statuses[0]


class LiveIntentTests(unittest.TestCase):
    def test_live_defaults_on_without_changing_other_preferences(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertTrue(atlas_live.load(folder))
            prefs={'region':'HaggaBasin','layers':['worms'],'refreshSeconds':10}
            atlas_preferences.save(folder,prefs)
            atlas_live.save(folder,False)
            self.assertEqual(atlas_preferences.load(folder),prefs)
            atlas_preferences.save(folder,{**prefs,'region':'DeepDesert'})
            self.assertFalse(atlas_live.load(folder))

    def test_start_and_stop_survive_process_and_installer_bundle_changes(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); settings=root/'shared-settings'
            first=service(root/'bundle-one',settings)
            self.assertTrue(first.live_enabled)
            self.assertEqual(action(first,'/live/stop'),200)
            second=service(root/'bundle-two',settings)
            self.assertFalse(second.live_enabled)
            self.assertFalse(second.state['live'])
            self.assertEqual(action(second,'/live/start'),200)
            second.live_enabled=False  # shutdown/recovery memory state must not clear intent
            third=service(root/'bundle-three',settings)
            self.assertTrue(third.live_enabled)
            self.assertTrue(third.state['live'])

    def test_failed_world_read_retries_without_disabling_live(self):
        with tempfile.TemporaryDirectory() as folder:
            value=service(Path(folder)/'bundle',Path(folder)/'settings')
            value.job_period=lambda name:.01
            attempts=[]; recovered=threading.Event()
            def observe():
                attempts.append(1)
                if len(attempts)==1: raise ValueError('World restarting')
                recovered.set()
            worker=threading.Thread(target=value.collection_worker,args=('db',observe))
            worker.start()
            try:
                self.assertTrue(recovered.wait(3))
                self.assertTrue(value.live_enabled)
                self.assertTrue(atlas_live.load(Path(folder)/'settings'))
            finally:
                value.stop.set()
                with value.control:value.control.notify_all()
                worker.join(3)

    def test_saved_stop_prevents_worker_reads_after_restart(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); settings=root/'settings'
            atlas_live.save(settings,False)
            value=service(root/'bundle',settings)
            observed=threading.Event()
            worker=threading.Thread(target=value.collection_worker,args=('db',observed.set))
            worker.start()
            try:self.assertFalse(observed.wait(.4))
            finally:
                value.stop.set()
                with value.control:value.control.notify_all()
                worker.join(3)

    def test_unsaved_stop_is_reported_instead_of_claiming_it_will_survive_restart(self):
        with tempfile.TemporaryDirectory() as folder:
            value=service(Path(folder)/'bundle',Path(folder)/'settings')
            with patch.object(atlas_live,'save',side_effect=OSError('disk full')):
                self.assertEqual(action(value,'/live/stop'),500)
            self.assertTrue(value.live_enabled)

    def test_invalid_saved_values_cannot_disable_live(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'live-v1.json'
            for raw in ('invalid','null','{"enabled":0}','{"enabled":"false"}'):
                path.write_text(raw)
                self.assertTrue(atlas_live.load(folder))
