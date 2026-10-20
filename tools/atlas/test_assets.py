"""Asset fallback checks; no collector or game connection is started."""
from pathlib import Path
import importlib.util
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2] / 'app/tools/DuneAtlas'
spec = importlib.util.spec_from_file_location('atlas_assets', ROOT / 'atlas_assets.py')
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


class AssetTests(unittest.TestCase):
    def test_clean_install_uses_packaged_terrain_for_every_layout(self):
        with tempfile.TemporaryDirectory() as folder:
            for name in [f'dd-layout-{seed}.webp' for seed in range(12)] + ['hagga-background-v1.webp']:
                path = assets.icon_path(name, folder, ROOT / 'icons')
                self.assertEqual(path, ROOT / 'icons' / name)
                self.assertEqual(path.read_bytes()[8:12], b'WEBP')

    def test_legacy_download_cache_does_not_override_game_terrain(self):
        with tempfile.TemporaryDirectory() as folder:
            old = Path(folder) / 'dd-layout-10.webp'
            old.write_bytes(b'legacy external terrain')
            self.assertEqual(assets.icon_path(old.name, folder, ROOT / 'icons'), ROOT / 'icons' / old.name)

    def test_terrain_provenance_and_both_adapters_match(self):
        import json
        import hashlib
        record = json.loads((ROOT / 'TERRAIN-SOURCES.json').read_text())
        companion = ROOT.parents[1] / 'resources/solo-mods/dst-solo-live-map/Companion'
        self.assertEqual(len(record['files']), 13)
        for row in record['files']:
            for parent in (ROOT, companion):
                self.assertEqual(hashlib.sha256((parent / 'icons' / row['file']).read_bytes()).hexdigest(), row['sha256'])

    def test_existing_local_game_image_wins(self):
        with tempfile.TemporaryDirectory() as folder:
            image = Path(folder) / 'game-lab.png'
            image.write_bytes(b'local image')
            self.assertEqual(assets.icon_path(image.name, folder, ROOT / 'icons'), image)

    def test_clean_install_has_full_worm_vehicle_and_poi_art(self):
        with tempfile.TemporaryDirectory() as folder:
            for name in ('live-worm.png', 'vehicle-scout.png', 'game-lab.png', 'flour-sand-v1.png'):
                with self.subTest(name=name):
                    path = assets.icon_path(name, folder, ROOT / 'icons')
                    self.assertTrue(path.is_file())
                    self.assertEqual(path.suffix, '.svg' if name == 'flour-sand-v1.png' else '.png')

    def test_every_production_icon_is_packaged_for_both_map_adapters(self):
        import json
        import hashlib
        record = json.loads((ROOT / 'ART-SOURCES.json').read_text(encoding='utf-8'))
        companion = ROOT.parents[1] / 'resources/solo-mods/dst-solo-live-map/Companion'
        self.assertEqual(len(record['files']), 42)
        for item in record['files']:
            for parent in (ROOT, companion):
                path = parent / 'icons' / item['file']
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), item['sha256'])
                self.assertEqual(path.read_bytes()[:8], b'\x89PNG\r\n\x1a\n')

    def test_does_not_invent_terrain_or_accept_paths_outside_icon_roots(self):
        with tempfile.TemporaryDirectory() as folder:
            for name in ('dd-layout-10.png', '../server.py', '..\\server.py', '/server.py', 'unknown.png'):
                with self.subTest(name=name):
                    self.assertIsNone(assets.icon_path(name, folder, ROOT / 'icons'))


if __name__ == '__main__':
    unittest.main()
