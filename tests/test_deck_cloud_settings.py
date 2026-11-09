import sys
import unittest, tempfile
from pathlib import Path
from test_deck_companion import reader_namespace

@unittest.skipUnless(sys.platform == 'linux', 'SteamOS filesystem and fcntl locking')
class CloudSettingsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.reader = reader_namespace()

    def layout(self, root):
        saved = root / 'Saved'
        local = saved / 'Config/Windows'
        profile = saved / 'Cloud/PlayerClientStorage/FLS_retail/123'
        local.mkdir(parents=True)
        (profile / 'SOLO').mkdir(parents=True)
        (profile / 'game.db').write_bytes(b'save')
        return saved, local, profile / 'SOLO/ServerCustomSettings.ini'

    def test_cloud_file_is_authoritative_only_when_present(self):
        with tempfile.TemporaryDirectory() as tmp:
            saved, local, cloud = self.layout(Path(tmp))
            resolve = self.reader['managed_settings_path']
            self.assertEqual(resolve(saved, 'ServerCustomSettings.ini'), local / 'ServerCustomSettings.ini')
            cloud.write_bytes(b'[/Script/DuneSandbox.UserServerCustomSettings]\nGatheringAmount=2.5\n')
            self.assertEqual(resolve(saved, 'ServerCustomSettings.ini'), cloud)
            self.assertEqual(resolve(saved, 'Engine.ini'), local / 'Engine.ini')
            snapshot = self.reader['settings_snapshot'](saved)
            native = next(f for f in snapshot if f['file'] == 'ServerCustomSettings.ini')
            self.assertEqual(native['storage'], 'cloud')
            self.assertEqual(native['values'][0]['value'], '2.5')

    def test_multiple_save_accounts_cannot_select_cloud_settings_implicitly(self):
        with tempfile.TemporaryDirectory() as tmp:
            saved, _, cloud = self.layout(Path(tmp))
            cloud.write_bytes(b'cloud')
            other = cloud.parent.parent.parent / '456'
            other.mkdir()
            (other / 'game.db').write_bytes(b'other')
            with self.assertRaisesRegex(ValueError, 'matching Solo save'):
                self.reader['managed_settings_path'](saved, 'ServerCustomSettings.ini')

    def test_cloud_writer_requires_storage_identity_and_rejects_stale_local_preview(self):
        with tempfile.TemporaryDirectory() as tmp:
            saved, local, cloud = self.layout(Path(tmp))
            (local / 'Engine.ini').write_bytes(b'')
            section = '/Script/DuneSandbox.UserServerCustomSettings'
            raw = ('['+section+']\nGatheringAmount=2.5\n').encode()
            cloud.write_bytes(raw)
            report = {'settings_candidates':[{'saved_root':str(saved)}], 'game_processes':[], 'errors':[]}
            entry = {'file':'ServerCustomSettings.ini','expected_sha256':self.reader['digest'](raw),
                     'values':[{'section':section,'key':'GatheringAmount','value':'3.5'}]}
            request = {'action':'preview-settings','files':[entry]}
            with self.assertRaisesRegex(ValueError, 'storage changed'):
                self.reader['batch_plan'](report, request)
            entry['expected_storage'] = 'cloud'
            plan = self.reader['batch_plan'](report, request)
            self.assertEqual(plan[0][0], cloud)
            self.assertIn(b'GatheringAmount=3.5', plan[0][2])
            cloud.unlink()
            with self.assertRaisesRegex(ValueError, 'storage changed'):
                self.reader['batch_plan'](report, request)

    def test_actual_cloud_apply_preserves_local_copy_and_backs_up_cloud_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            saved, local, cloud = self.layout(Path(tmp))
            (local / 'Engine.ini').write_bytes(b'')
            legacy = local / 'ServerCustomSettings.ini'
            legacy.write_bytes(b'local fallback remains untouched')
            section = '/Script/DuneSandbox.UserServerCustomSettings'
            raw = ('['+section+']\nGatheringAmount=2.5\n').encode()
            cloud.write_bytes(raw)
            report = {'settings_candidates':[{'saved_root':str(saved)}], 'game_processes':[], 'errors':[]}
            request = {'action':'apply-settings','confirmed':True,'cloud_confirmed':True,'files':[
                {'file':'ServerCustomSettings.ini','expected_storage':'cloud','expected_sha256':self.reader['digest'](raw),
                 'values':[{'section':section,'key':'GatheringAmount','value':'3.5'}]}]}
            result = self.reader['handle_batch'](request, lambda: report, Path(tmp) / 'backups')
            self.assertTrue(result['applied'])
            self.assertIn(b'GatheringAmount=3.5', cloud.read_bytes())
            self.assertEqual(legacy.read_bytes(), b'local fallback remains untouched')
            self.assertEqual((Path(result['backup']) / 'ServerCustomSettings.ini').read_bytes(), raw)

if __name__ == '__main__':
    unittest.main()
