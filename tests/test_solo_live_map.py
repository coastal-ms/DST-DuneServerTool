"""Companion acceptance checks with isolated local feeds and copied saves."""
import http.client
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import time
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1] / 'app/resources/solo-mods/dst-solo-live-map/Companion'
sys.path.insert(0, str(ROOT))
spec = importlib.util.spec_from_file_location('solo_map_server', ROOT / 'server.py')
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class SoloMapTests(unittest.TestCase):
    def test_clean_solo_terrain_uses_permanent_layout_and_preserves_override(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            preferred = root / 'terrain.webp'
            cached = root / 'dd-layout-11.webp'
            with patch.object(server.atlas_assets, 'icon_path', return_value=cached) as fetch:
                self.assertEqual(server.terrain_path(preferred, root), cached)
                fetch.assert_called_once_with('dd-layout-11.webp', root, server.ROOT / 'icons')
            preferred.write_bytes(b'operator background')
            with patch.object(server.atlas_assets, 'icon_path', side_effect=AssertionError('No replacement')):
                self.assertEqual(server.terrain_path(preferred, root), preferred)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.state = server.MapState(self.root, 'launch-one')
        self.now = time.time()

    def tearDown(self):
        self.temp.cleanup()

    def frame(self, items, **extra):
        server.atomic_json(self.root / 'runtime.json', {
            'launchId': 'launch-one', 'world': 'DeepDesert_1', 'capturedAt': self.now,
            'items': items, **extra})

    def item(self, kind, identity='one', x=10, **extra):
        return {'id': identity, 'kind': kind, 'location': {'x': x, 'y': 20, 'z': 30}, **extra}

    def observed(self, result):
        return [i for i in result['items'] if i.get('source') not in ('solo-reference', 'seed-reference')]

    def test_completed_storm_pass_survives_travel_expiry_restart_and_is_replaced(self):
        self.frame([self.item('storm', 'first', zones=[{'warning': True}])])
        self.state.snapshot()
        self.now += .1
        self.frame([self.item('storm', 'first', x=1000, zones=[{'warning': True}])])
        self.state.snapshot()
        self.now += .1
        self.frame([])
        done = self.state.snapshot()['stormPasses']
        self.assertEqual(len(done), 1)
        self.assertIn('completedAt', done[0])
        self.assertEqual(done[0]['points'][-1]['x'], 1000)
        self.assertTrue(done[0]['profile']['zones'])
        with patch.object(server.time, 'time', return_value=self.now + 3600):
            self.assertEqual(len(server.visible_state(self.state.saved, 'Capture paused')['stormPasses']), 1)
            self.assertEqual(server.visible_state(self.state.saved, 'Capture paused')['tracks'], [])
        restarted = server.MapState(self.root, 'launch-two')
        self.now += .1
        self.frame([self.item('storm', 'second')], launchId='launch-two')
        self.assertEqual(len(restarted.snapshot()['stormPasses']), 2)
        self.now += .1
        self.frame([], launchId='launch-two')
        latest = restarted.snapshot()['stormPasses']
        self.assertEqual(len(latest), 1)
        self.assertTrue(latest[0]['key'].endswith(':second'))

    def test_filters_packed_vehicles_inactive_spice_and_spawner_origins(self):
        self.frame([
            self.item('vehicle', worldPlaced=False),
            self.item('vehicle', 'placed', worldPlaced=True),
            self.item('spice', fields={'m_bIsActiveOnServer': False}),
            self.item('spice', 'active', fields={'m_bIsActiveOnServer': True}),
            self.item('ore', source='spawner'), self.item('base'),
            self.item('ore', 'node', source='instance', oreType='titanium'),
            self.item('ore', 'invalid', x=float('nan'), source='instance')])
        result = self.state.snapshot()
        self.assertEqual({p['id'] for p in self.observed(result)}, {'placed', 'active', 'node'})

    def test_ore_stays_fixed_when_unloaded_and_survives_future_launches(self):
        self.frame([self.item('ore', source='instance', oreType='titanium')])
        self.state.snapshot()
        self.now += .1
        self.frame([self.item('vehicle', x=50000, worldPlaced=True)])
        result = self.state.snapshot()
        ore = next(i for i in result['items'] if i['kind'] == 'ore')
        self.assertEqual(ore['location']['x'], 10)
        self.assertFalse(ore['currentlyObserved'])
        new = server.MapState(self.root, 'launch-two')
        self.assertEqual(new.snapshot()['status'], 'Capture paused')
        self.frame([], launchId='launch-two', capturedAt=self.now + .1)
        restored = self.observed(new.snapshot())
        self.assertEqual(len(restored), 1)
        self.assertEqual(restored[0]['location']['x'], 10)
        self.assertFalse(restored[0]['currentlyObserved'])
        with tempfile.TemporaryDirectory() as other:
            self.assertEqual(self.observed(server.MapState(Path(other), 'launch-two').snapshot()), [])

    def test_logout_truncated_feed_and_old_frames_hold_snapshot(self):
        self.frame([self.item('worm')])
        self.state.snapshot()
        for frame in ({'world': 'HaggaBasin'}, {'launchId': 'wrong'}, {'capturedAt': 1}):
            self.frame([], **frame)
            result = self.state.snapshot()
            self.assertEqual(result['status'], 'Capture paused')
            self.assertEqual(result['items'][0]['kind'], 'worm')
        (self.root / 'runtime.json').write_text('{')
        self.assertEqual(self.state.snapshot()['items'][0]['kind'], 'worm')
        restored = server.MapState(self.root, 'launch-one')
        self.assertEqual(restored.snapshot()['items'][0]['kind'], 'worm')

    def test_tracks_follow_observed_storm_and_vehicle_positions(self):
        self.frame([self.item('storm'), self.item('vehicle', worldPlaced=True)])
        self.state.snapshot()
        self.now += .1
        self.frame([self.item('storm', x=3000), self.item('vehicle', x=5000, worldPlaced=True)])
        result = self.state.snapshot()
        self.assertEqual(len(result['tracks']), 2)
        self.assertTrue(all(len(t['points']) == 2 for t in result['tracks']))

    def test_observed_empty_or_packed_component_removes_previous_ore(self):
        for status in ('complete', 'excluded'):
            self.now += .1
            self.frame([self.item('ore', source='instance', oreSource='mesh-one', oreType='titanium')])
            self.state.snapshot()
            self.now += .1
            self.frame([], oreSources={'mesh-one': status})
            self.assertEqual(self.observed(self.state.snapshot()), [])

    def test_static_shipwrecks_and_dynamic_crashed_ship_events_are_separate(self):
        self.frame([self.item('wreck', 'obsolete-live-site'), self.item('crash', 'live-event')])
        result = self.state.snapshot()
        self.assertEqual({i['kind'] for i in self.observed(result)}, {'crash'})
        self.assertEqual(sum(i['kind'] == 'wreck' for i in result['items']), 14)
        self.now += .1
        self.frame([])
        result = self.state.snapshot()
        self.assertEqual(self.observed(result), [])
        self.assertEqual(sum(i['kind'] == 'wreck' for i in result['items']), 14)

    def test_all_static_reference_sites_exist_without_a_save_or_live_capture(self):
        result = self.state.snapshot()
        self.assertEqual(result['status'], 'Waiting for Deep Desert')
        self.assertEqual(len(result['items']), 40)
        self.assertEqual(sum(i['source'] == 'solo-reference' for i in result['items']), 36)
        self.assertEqual(sum(i['kind'] == 'ore-area' for i in result['items']), 4)

    def test_deposit_reference_is_replaced_by_scanned_nodes_and_remains_replaced(self):
        area = server.ore_reference_areas()[0]
        nodes = [self.item('ore', str(i), source='instance', oreSource='deposit', oreType=area['oreType'],
                           location={**area['location'], 'x': area['location']['x'] + i * 100}) for i in range(25)]
        self.frame(nodes)
        result = self.state.snapshot()
        self.assertNotIn(area['id'], [i['id'] for i in result['items']])
        self.assertEqual(sum(i['kind'] == 'ore-area' for i in result['items']), 3)
        self.assertTrue((self.root / 'ore-survey.json').is_file())
        self.now += .1
        self.frame([], oreSources={'deposit': 'complete'})
        result = self.state.snapshot()
        self.assertEqual(self.observed(result), [])
        self.assertNotIn(area['id'], [i['id'] for i in result['items']])
        restored = server.MapState(self.root, 'new-launch').snapshot()
        self.assertNotIn(area['id'], [i['id'] for i in restored['items']])

    def test_reference_sites_match_permanent_solo_sites_and_never_add_spice(self):
        source = json.loads((ROOT.parents[4] / 'webui/src/data/wickmaps.json').read_text())
        seed = next(s for s in source['seeds'] if s['seed'] == 11)
        reference = server.reference_sites()
        self.assertEqual(sum(i['kind'] == 'wreck' for i in reference), 14)
        self.assertFalse(any(i['kind'] == 'spice' for i in reference))
        self.assertEqual(len(reference), len([p for p in seed['pois'] if p['type'] not in ('large-spice-field', 'titanium', 'stravidium')]))
        self.frame([self.item('spice', 'large-active', size='large', fields={'m_bIsActiveOnServer': True}),
                    self.item('spice', 'large-inactive', size='large', fields={'m_bIsActiveOnServer': False})])
        result = self.state.snapshot()
        self.assertEqual([i['id'] for i in result['items'] if i['kind'] == 'spice'], ['large-active'])

    def test_trails_expire_even_when_capture_is_paused(self):
        state = {'items': [], 'tracks': [{'id': 'v', 'kind': 'vehicle', 'points': [
            {'x': 1, 'y': 1, 'at': self.now}, {'x': 2, 'y': 2, 'at': self.now + 3}]}]}
        with patch.object(server.time, 'time', return_value=self.now + 604):
            self.assertEqual(server.visible_state(state, 'Capture paused')['tracks'], [])

    def test_movement_after_an_expired_trail_starts_from_the_current_position(self):
        self.frame([self.item('vehicle', worldPlaced=True)])
        self.state.snapshot()
        self.now += server.TRAIL_SECONDS + 10
        with patch.object(server.time, 'time', side_effect=lambda: self.now):
            self.frame([self.item('vehicle', worldPlaced=True)])
            self.state.snapshot()
            self.now += 3
            self.frame([self.item('vehicle', x=5000, worldPlaced=True)])
            result = self.state.snapshot()
            self.assertEqual(len(result['tracks']), 1)
            self.assertEqual([p['x'] for p in result['tracks'][0]['points']], [10, 5000])


class SoloMapPreferencesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.preferences = server.MapPreferences(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def test_missing_or_malformed_preferences_keep_first_open_defaults(self):
        self.assertIsNone(self.preferences.load())
        for value in ('{broken', '[]', '{"schema":1,"layers":null}',
                      '{"schema":2,"layers":[]}', '{"schema":1,"layers":[false]}'):
            self.preferences.path.write_text(value, encoding='utf-8')
            self.assertIsNone(self.preferences.load())

    def test_selected_layers_and_all_off_survive_new_companion_instances(self):
        for layers in (['storm', 'vehicle'], []):
            self.preferences.save({'schema': 1, 'layers': layers})
            self.assertEqual(server.MapPreferences(self.root).load(), {'schema': 1, 'layers': layers})
        other = self.root / 'other-save'
        other.mkdir()
        self.assertIsNone(server.MapPreferences(other).load())

    def test_only_known_unique_layers_are_saved_and_invalid_writes_preserve_choices(self):
        expected = {'schema': 1, 'layers': ['vehicle']}
        self.assertEqual(self.preferences.save({'schema': 1, 'layers': ['vehicle', 'unknown', 'vehicle']}), expected)
        with self.assertRaises(ValueError):
            self.preferences.save({'schema': 1, 'layers': 'storm'})
        self.assertEqual(self.preferences.load(), expected)
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ['preferences.json'])

    def test_authenticated_http_preferences_are_durable_and_reject_foreign_requests(self):
        args = SimpleNamespace(data=self.root, launch='fixture', assets=self.root, terrain=self.root / 'terrain.webp')
        with patch.object(server.atlas_assets, 'marker_icons', return_value={}):
            httpd, key = server.create_server(args)
        thread = threading.Thread(target=httpd.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
        thread.start()
        port = httpd.server_port

        def request(method, path, value=None, **headers):
            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
            try:
                body = json.dumps(value) if value is not None else None
                connection.request(method, path, body, {'Content-Type': 'application/json', **headers})
                response = connection.getresponse()
                return response.status, response.read()
            finally:
                connection.close()

        try:
            path = '/preferences?key=' + key
            self.assertEqual(request('GET', path), (200, b'null'))
            value = {'schema': 1, 'layers': []}
            status, body = request('POST', path, value, Origin=f'http://127.0.0.1:{port}')
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body), value)
            self.assertEqual(json.loads(request('GET', path)[1]), value)
            self.assertEqual(request('POST', '/preferences?key=wrong', value)[0], 403)
            self.assertEqual(request('POST', path, value, Origin='https://foreign.example')[0], 403)
            self.assertEqual(request('POST', path, value, Host='foreign.example')[0], 403)
            self.assertEqual(request('GET', '/preferences?key=wrong')[0], 403)
            self.assertEqual(request('POST', path, {'schema': 1, 'layers': None})[0], 400)
            self.assertEqual(request('POST', path, {'schema': 1, 'layers': ['x' * 5000]})[0], 400)
            self.assertEqual(self.preferences.load(), value)
        finally:
            httpd.shutdown()
            thread.join(timeout=5)
            httpd.server_close()


if __name__ == '__main__':
    unittest.main()
