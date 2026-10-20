import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys

ROOT = Path(__file__).resolve().parents[1] / 'app/tools/DuneAtlas'
spec = importlib.util.spec_from_file_location('atlas_builds', ROOT / 'atlas_builds.py')
builds = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builds)


class AtlasBuildProfiles(unittest.TestCase):
    def test_unlisted_executable_is_discovered_and_reused_without_a_release_entry(self):
        sys.path.insert(0, str(ROOT))
        import atlas_elf
        digest = 'a' * 64
        discovered = {'sha256': digest, 'symbols': {'_ZTV13ASandwormPawn': 123},
                      'namePoolTableOffset': 456, 'discoveredFrom': 'running-elf-and-name-pool'}
        with tempfile.TemporaryDirectory() as folder, patch.object(atlas_elf, 'inspect', return_value=discovered) as inspect:
            self.assertEqual(builds.profile(folder, digest, runtime={}), discovered)
            inspect.assert_called_once_with(digest, cache_dir=Path(folder))
            self.assertEqual(builds.profile(folder, digest), discovered)
            self.assertEqual(builds.symbol_rows(folder, digest, 'all-native-vtables.json'),
                             [{'name': '_ZTV13ASandwormPawn', 'value': 123}])
            self.assertEqual(inspect.call_count, 1)

    def test_tank_build_keeps_exact_identity_and_uses_current_symbol_layout(self):
        recipe = json.loads((ROOT.parents[1] / 'resources/regis-tanks/2156652.json').read_text())
        self.assertIn(builds.TANK_BUILD, json.dumps(recipe))
        for folder in (ROOT, ROOT / 'hagga'):
            stock = builds.profile(folder, builds.CURRENT_BUILD)
            tank = builds.profile(folder, builds.TANK_BUILD)
            self.assertEqual(tank['sha256'], builds.TANK_BUILD)
            self.assertEqual(tank['symbols'], stock['symbols'])
            self.assertEqual(tank['namePoolTableOffset'], stock['namePoolTableOffset'])
            self.assertEqual(builds.symbol_rows(folder, builds.TANK_BUILD, 'all-native-vtables.json'),
                             builds.symbol_rows(folder, builds.CURRENT_BUILD, 'all-native-vtables.json'))

    def test_current_build_uses_its_own_name_pool_and_symbols_on_both_maps(self):
        for folder in (ROOT, ROOT / 'hagga'):
            with self.subTest(folder=folder):
                value = builds.profile(folder, builds.CURRENT_BUILD)
                self.assertEqual(value['namePoolTableOffset'], 0x16CE9A28)
                self.assertEqual(value['symbols']['_ZTV13ASandwormPawn'], 0x15F2F240)
                self.assertEqual(value['symbols']['_ZTV14ASandStormBase'], 0x15F0A2F0)
                self.assertNotEqual(value['namePoolTableOffset'], 390184232)

    def test_unknown_build_cannot_reuse_an_old_process_profile(self):
        with self.assertRaisesRegex(ValueError, 'has not been discovered'):
            builds.profile(ROOT, '0' * 64)
        with self.assertRaisesRegex(ValueError, 'has not been discovered'):
            builds.symbol_rows(ROOT, '0' * 64, 'all-native-vtables.json')

    def test_gathering_vehicles_and_encounters_use_current_symbol_addresses(self):
        for folder in (ROOT, ROOT / 'hagga'):
            current = {s['name']: s['value'] for s in builds.symbol_rows(folder, builds.CURRENT_BUILD, 'all-native-vtables.json')}
            for name in ('_ZTV30AHarvestableInstancedMeshActor', '_ZTV20AResourceNodeSpawner',
                         '_ZTV16ADuneOrnithopter', '_ZTV22ADuneStaticMarkerActor',
                         '_ZTV14TComponentPoolI26FDynamicEncounterComponentE'):
                self.assertIn(name, current)
                self.assertGreater(current[name], 0)
            old = {s['name']: s['value'] for s in json.loads((folder / 'all-native-vtables.json').read_text())}
            self.assertNotEqual(current['_ZTV20AResourceNodeSpawner'], old['_ZTV20AResourceNodeSpawner'])

    def test_profile_file_must_match_the_verified_executable(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, 'build-2156652.json').write_text(json.dumps({'sha256': '0' * 64}))
            with self.assertRaisesRegex(ValueError, 'identity mismatch'):
                builds.profile(tmp, builds.CURRENT_BUILD)

    def test_previous_builds_keep_their_previous_profiles(self):
        for folder in (ROOT, ROOT / 'hagga'):
            digest = json.loads((folder / 'bootstrap-context.json').read_text())['sha256']
            value = builds.profile(folder, digest)
            self.assertEqual(value['namePoolTableOffset'], 390184232)
            original = json.loads((folder / 'native-symbols.json').read_text())
            expected = next(s['value'] for s in original if s['name'] == '_ZTV13ASandwormPawn')
            self.assertEqual(value['symbols']['_ZTV13ASandwormPawn'], expected)

    def test_new_profile_is_in_the_verified_runtime_package(self):
        import hashlib
        manifest = json.loads((ROOT / 'manifest.json').read_text())
        for name in ('atlas_builds.py', 'build-2156652.json', 'discover-runtime.py',
                     'hagga/discover-runtime.py', 'find-event-actors.py', 'ensure-poi-discovery.py'):
            self.assertEqual(manifest['files'][name], hashlib.sha256((ROOT / name).read_bytes()).hexdigest())


if __name__ == '__main__':
    unittest.main()
