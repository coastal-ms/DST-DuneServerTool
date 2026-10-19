import importlib.util
import json
import tempfile
import shutil
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('item_audit', ROOT / 'tools/catalog/audit-items.py')
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


class ItemCoverageTests(unittest.TestCase):
    def test_every_current_game_item_has_a_definition_and_an_explicit_workflow(self):
        result = tool.audit(ROOT / 'app/data')
        self.assertTrue(result['ok'], result['issues'][:10])
        self.assertEqual(result['gameItems'], 4227)
        self.assertEqual(result['positiveDurabilityCaps'], 1476)

    def test_future_funcom_item_is_reported_without_silently_guessing_its_cap(self):
        with tempfile.TemporaryDirectory() as folder:
            export = Path(folder) / 'current.json'
            export.write_text(json.dumps([{'Name':'CDT_BaseItems','Rows':{'FutureFuncomItem':{'StackAndDurability':{'MaxDurability':75}}}}]), encoding='utf-8')
            result = tool.audit(ROOT / 'app/data', export)
            self.assertFalse(result['ok'])
            self.assertIn('unclassified-item-workflow', [issue['issue'] for issue in result['issues']])

    def test_belt_light_and_repair_tool_caps_come_from_current_game_definitions(self):
        value = json.loads((ROOT / 'app/data/gameplay-item-data.json').read_text(encoding='utf-8'))
        for key in ('FullStabilizationBelt', 'PortableLight', 'RepairTool5'):
            with self.subTest(key=key):
                self.assertTrue(value['items'][key]['durability_known'])
                self.assertEqual(value['items'][key]['max_durability'], 100)
        self.assertEqual(value['items']['HealthPack_Channeled_2']['max_durability'], 0)

    def test_a_declared_building_workflow_requires_an_actual_catalog_entry(self):
        with tempfile.TemporaryDirectory() as folder:
            shutil.copytree(ROOT / 'app/data', Path(folder) / 'data')
            root = Path(folder) / 'data'
            path = root / 'game-item-coverage.json'
            coverage = json.loads(path.read_text(encoding='utf-8'))
            coverage['items']['D_ChoamSet']['workflow'] = 'building-unlocks'
            path.write_text(json.dumps(coverage), encoding='utf-8')
            picker = json.loads((root / 'item-catalog.json').read_text(encoding='utf-8'))
            del picker['items']['D_ChoamSet']
            (root / 'item-catalog.json').write_text(json.dumps(picker), encoding='utf-8')
            self.assertIn('missing-building-grant-entry', [i['issue'] for i in tool.audit(root)['issues']])

    def test_installed_module_caps_are_a_separate_authoritative_table(self):
        modules = json.loads((ROOT / 'app/data/vehicle-module-durability.json').read_text(encoding='utf-8'))
        self.assertEqual(modules['sourceTable'], 'CDT_BaseVehicleModules')
        self.assertEqual(len(modules['defaults']), 674)
        self.assertEqual(modules['defaults']['SandbikeEngine_6'], 1000)
        with tempfile.TemporaryDirectory() as folder:
            export = Path(folder) / 'modules.json'
            export.write_text(json.dumps([{'Name':'CDT_BaseVehicleModules','Rows':{'FutureModule':{'m_DurabilityStats':{'MaxDurability':1250}}}}]), encoding='utf-8')
            issues = tool.audit(ROOT / 'app/data', vehicle_export=export)['issues']
            self.assertIn('missing-or-outdated-installed-module-cap', [i['issue'] for i in issues])
