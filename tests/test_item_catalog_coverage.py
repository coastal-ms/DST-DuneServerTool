import importlib.util
import json
import tempfile
import shutil
import unittest
from unittest.mock import patch
import copy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('item_audit', ROOT / 'tools/catalog/audit-items.py')
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


class ItemCoverageTests(unittest.TestCase):
    def test_schematic_names_follow_game_action_class_instead_of_a_template_prefix(self):
        with tempfile.TemporaryDirectory() as folder:
            data = Path(folder) / 'data'
            shutil.copytree(ROOT / 'app/data', data)
            export = Path(folder) / 'current.json'
            export.write_text(json.dumps([{'Name': 'CDT_BaseItems', 'Rows': {
                'D_AmmoBlueprint': {'StackAndDurability': {'MaxDurability': -1},
                                    'ActionsClass': {'ObjectName': "BlueprintGeneratedClass'BP_Schematic_ConsumeSchematic_C'"}},
            }}]), encoding='utf-8')
            names = json.loads((data / 'gameplay-item-data.json').read_text())
            picker = json.loads((data / 'item-catalog.json').read_text())
            names['names']['D_AmmoBlueprint'] = 'Light Darts'
            picker['items']['D_AmmoBlueprint']['name'] = 'Light Darts'
            (data / 'gameplay-item-data.json').write_text(json.dumps(names), encoding='utf-8')
            (data / 'item-catalog.json').write_text(json.dumps(picker), encoding='utf-8')
            issues = [i['issue'] for i in tool.audit(data, export)['issues']]
            self.assertIn('unmarked-picker-schematic', issues)
            self.assertIn('unmarked-inventory-schematic', issues)
    def test_every_current_game_item_has_a_definition_and_is_checked_at_its_workflow(self):
        result = tool.audit(ROOT / 'app/data')
        definition_errors = {'missing-or-outdated-game-definition', 'missing-display-name', 'unclassified-item-workflow'}
        self.assertFalse([i for i in result['issues'] if i['issue'] in definition_errors])
        # This scan is deliberately NOT a green completeness assertion: known
        # product omissions must remain findings until their real workflows change.
        self.assertEqual(sum(result['workflows'].values()), result['gameItems'])
        self.assertEqual(result['gameItems'], 4227)
        self.assertEqual(result['positiveDurabilityCaps'], 1476)
        self.assertEqual(len(result['exclusions']), result['workflows']['not-grantable'])

    def test_current_halloween_omissions_cannot_be_hidden_by_a_specialized_label(self):
        value = copy.deepcopy(tool.runtime_catalogs(ROOT / 'app/data'))
        value['cosmetics'] = [e for e in value['cosmetics'] if e['template'] not in
                              ('Halloween2026_PlagueDoctorMask_Hood', 'Halloween2026_PlagueDoctorMask_NoHood')]
        with patch.object(tool, 'runtime_catalogs', return_value=value):
            result = tool.audit(ROOT / 'app/data')
        self.assertFalse(result['ok'])
        missing = {i['template'] for i in result['issues'] if i['issue'] == 'missing-cosmetic-grant-entry'}
        self.assertTrue({'Halloween2026_PlagueDoctorMask_Hood', 'Halloween2026_PlagueDoctorMask_NoHood'} <= missing)

    def test_a_cosmetic_regression_in_the_runtime_loader_is_caught_with_unchanged_data(self):
        value = copy.deepcopy(tool.runtime_catalogs(ROOT / 'app/data'))
        key = 'AdvancedTrainer_Mentat_SetVariant'
        self.assertIn(key, [e['template'] for e in value['cosmetics']])
        value['cosmetics'] = [e for e in value['cosmetics'] if e['template'] != key]
        with patch.object(tool, 'runtime_catalogs', return_value=value):
            issues = tool.audit(ROOT / 'app/data')['issues']
        self.assertIn(key, [i['template'] for i in issues if i['issue'] == 'missing-cosmetic-grant-entry'])

    def test_new_customization_is_checked_against_real_generated_catalog(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / 'data'
            shutil.copytree(ROOT / 'app/data', root)
            path = root / 'game-item-coverage.json'
            value = json.loads(path.read_text(encoding='utf-8'))
            value['items']['FutureCosmetic_NoRecognizedSuffix'] = {'maxDurability': 0, 'workflow': 'customizations'}
            path.write_text(json.dumps(value), encoding='utf-8')
            for name in ('gameplay-item-data.json',):
                path = root / name
                data = json.loads(path.read_text(encoding='utf-8'))
                data['names']['FutureCosmetic_NoRecognizedSuffix'] = 'Future cosmetic'
                data['items']['FutureCosmetic_NoRecognizedSuffix'] = {'name': 'Future cosmetic', 'durability_known': True, 'max_durability': 0}
                path.write_text(json.dumps(data), encoding='utf-8')
            issues = tool.audit(root)['issues']
            self.assertIn('FutureCosmetic_NoRecognizedSuffix', [i['template'] for i in issues if i['issue'] == 'missing-cosmetic-grant-entry'])

    def test_emote_coverage_uses_the_actual_form_catalog(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'data').mkdir()
            value = json.loads((ROOT / 'webui/src/data/emotes.json').read_text(encoding='utf-8'))
            value['entries'] = [e for e in value['entries'] if e['template'] != 'Emote_Wave_01']
            (root / 'data/emotes.json').write_text(json.dumps(value), encoding='utf-8')
            issues = tool.audit(ROOT / 'app/data', ui_root=root)['issues']
            self.assertIn('Emote_Wave_01', [i['template'] for i in issues if i['issue'] == 'missing-emote-grant-entry'])

    def test_reputation_token_without_a_selectable_backend_workflow_is_reported_per_mode(self):
        supported = {mode: values - {'atreides'} for mode, values in tool.faction_surfaces().items()}
        with patch.object(tool, 'faction_surfaces', return_value=supported):
            result = tool.audit(ROOT / 'app/data')
        missing = [i for i in result['issues'] if i['issue'] == 'missing-faction-progression-entry'
                   and i['template'] == 'AtreidesReputation']
        self.assertEqual({(i['template'], i['mode']) for i in missing},
                         {('AtreidesReputation', 'solo'), ('AtreidesReputation', 'self-hosted')})

    def test_runtime_export_failure_cannot_be_reported_as_a_successful_audit(self):
        with patch.object(tool, 'runtime_catalogs', side_effect=RuntimeError('loader failed')):
            with self.assertRaisesRegex(RuntimeError, 'loader failed'):
                tool.audit(ROOT / 'app/data')

    def test_known_unavailable_tokens_remain_visible_and_do_not_claim_complete_availability(self):
        result = tool.audit(ROOT / 'app/data')
        self.assertTrue(result['ok'], result['issues'])
        self.assertFalse(result['allGameTemplatesAvailable'])
        self.assertEqual(len(result['knownUnavailable']), 6)
        self.assertTrue(all(entry['reason'] and entry['actionClass'] for entry in result['knownUnavailable']))

    def test_a_changed_game_definition_cannot_keep_using_an_old_exclusion(self):
        with tempfile.TemporaryDirectory() as folder:
            export = Path(folder) / 'current.json'
            export.write_text(json.dumps([{'Name': 'CDT_BaseItems', 'Rows': {
                'D_TestEmote': {'StackAndDurability': {'MaxDurability': 0},
                                'ActionsClass': {'ObjectName': "Class'GameItemActionCustomization'"}}
            }}]), encoding='utf-8')
            result = tool.audit(ROOT / 'app/data', export)
            self.assertFalse(result['ok'])
            self.assertIn('unsupported-exclusion-definition-changed', [i['issue'] for i in result['issues']])

    def test_exclusions_do_not_hide_a_removed_supported_emote(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'data').mkdir()
            value = json.loads((ROOT / 'webui/src/data/emotes.json').read_text(encoding='utf-8'))
            value['entries'] = [e for e in value['entries'] if e['template'] != 'Emote_Wave_01']
            (root / 'data/emotes.json').write_text(json.dumps(value), encoding='utf-8')
            result = tool.audit(ROOT / 'app/data', ui_root=root)
            self.assertFalse(result['ok'])
            self.assertIn('Emote_Wave_01', [i['template'] for i in result['issues']])

    def test_current_game_action_cannot_be_overridden_by_a_wrong_ledger_label(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / 'data'
            shutil.copytree(ROOT / 'app/data', root)
            path = root / 'game-item-coverage.json'
            value = json.loads(path.read_text(encoding='utf-8'))
            template = 'Halloween2026_PlagueDoctorMask_Hood'
            value['items'][template]['workflow'] = 'item-picker'
            path.write_text(json.dumps(value), encoding='utf-8')
            export = Path(folder) / 'game.json'
            export.write_text(json.dumps([{'Name': 'CDT_BaseItems', 'Rows': {template: {
                'ActionsClass': {'ObjectName': "Class'GameItemActionCustomization'"},
                'StackAndDurability': {'MaxDurability': 0}}}}]), encoding='utf-8')
            snapshot = copy.deepcopy(tool.runtime_catalogs(root))
            snapshot['cosmetics'] = [e for e in snapshot['cosmetics'] if e['template'] != template]
            with patch.object(tool, 'runtime_catalogs', return_value=snapshot):
                issues = tool.audit(root, export)['issues']
            self.assertIn('workflow-disagrees-with-game-action', [i['issue'] for i in issues])
            self.assertIn('missing-cosmetic-grant-entry', [i['issue'] for i in issues])

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
