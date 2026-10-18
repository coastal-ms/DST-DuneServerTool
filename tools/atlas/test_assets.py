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
    def test_existing_local_game_image_wins(self):
        with tempfile.TemporaryDirectory() as folder:
            image = Path(folder) / 'game-lab.png'
            image.write_bytes(b'local image')
            self.assertEqual(assets.icon_path(image.name, folder, ROOT / 'icons'), image)

    def test_no_local_art_still_has_worm_vehicle_flour_and_poi_icons(self):
        with tempfile.TemporaryDirectory() as folder:
            for name in ('live-worm.png', 'vehicle-scout.png', 'game-lab.png', 'flour-sand-v1.png'):
                with self.subTest(name=name):
                    path = assets.icon_path(name, folder, ROOT / 'icons')
                    self.assertTrue(path.is_file())
                    self.assertEqual(path.suffix, '.svg')

    def test_does_not_invent_terrain_or_accept_paths_outside_icon_roots(self):
        with tempfile.TemporaryDirectory() as folder:
            for name in ('dd-layout-10.png', '../server.py', '..\\server.py', '/server.py', 'unknown.png'):
                with self.subTest(name=name):
                    self.assertIsNone(assets.icon_path(name, folder, ROOT / 'icons'))


if __name__ == '__main__':
    unittest.main()
