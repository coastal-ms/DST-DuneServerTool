"""Compare DST catalogs with a merged CDT_BaseItems export; never modifies game data."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPECIALIZED = {'customizations', 'emotes', 'building-unlocks', 'faction-progression'}


def audit(data_root, export=None, vehicle_export=None):
    data_root = Path(data_root)
    rules = json.loads((data_root / 'gameplay-item-data.json').read_text(encoding='utf-8'))
    picker = json.loads((data_root / 'item-catalog.json').read_text(encoding='utf-8'))
    coverage = json.loads((data_root / 'game-item-coverage.json').read_text(encoding='utf-8'))
    building = json.loads((data_root / 'building-sets.json').read_text(encoding='utf-8'))
    tech = json.loads((data_root / 'dune-tech-catalog.json').read_text(encoding='utf-8'))
    modules = json.loads((data_root / 'vehicle-module-durability.json').read_text(encoding='utf-8'))
    expected = coverage['items']
    if export is not None:
        source = json.loads(Path(export).read_text(encoding='utf-8-sig'))
        master = next(item for item in source if item.get('Name') == 'CDT_BaseItems')
        expected = {key: {'maxDurability': row['StackAndDurability']['MaxDurability']} for key, row in master['Rows'].items()}
    issues = []
    for key, definition in expected.items():
        item = rules['items'].get(key)
        if not item or item.get('durability_known') is not True or item.get('max_durability') != definition['maxDurability']:
            issues.append({'template': key, 'issue': 'missing-or-outdated-game-definition'})
        if not rules['names'].get(key):
            issues.append({'template': key, 'issue': 'missing-display-name'})
        route = coverage['items'].get(key, {}).get('workflow')
        if route == 'item-picker':
            if not picker['items'].get(key, {}).get('name'):
                issues.append({'template': key, 'issue': 'missing-item-picker-entry'})
        elif route == 'building-unlocks':
            if key not in building['ids'] and key not in picker['items']:
                issues.append({'template': key, 'issue': 'missing-building-grant-entry'})
        elif route == 'tech-unlocks':
            if coverage['items'][key].get('techKey') not in tech['item_keys']:
                issues.append({'template': key, 'issue': 'missing-tech-unlock-entry'})
        elif route == 'not-grantable':
            if key not in building['_meta']['flagged_no_item_form']:
                issues.append({'template': key, 'issue': 'unsupported-exclusion'})
        elif route not in SPECIALIZED:
            issues.append({'template': key, 'issue': 'unclassified-item-workflow'})
    if vehicle_export is not None:
        source = json.loads(Path(vehicle_export).read_text(encoding='utf-8-sig'))
        master = next(item for item in source if item.get('Name') == 'CDT_BaseVehicleModules')
        for key, row in master['Rows'].items():
            if modules['defaults'].get(key) != row['m_DurabilityStats']['MaxDurability']:
                issues.append({'template': key, 'issue': 'missing-or-outdated-installed-module-cap'})
    return {'ok': not issues, 'gameItems': len(expected), 'positiveDurabilityCaps': sum(v['maxDurability'] > 0 for v in expected.values()), 'vehicleModules': len(modules['defaults']), 'issues': issues}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--export', type=Path, help='Current merged CDT_BaseItems JSON export')
    parser.add_argument('--data-root', type=Path, default=ROOT / 'app/data')
    parser.add_argument('--vehicle-export', type=Path, help='Current merged CDT_BaseVehicleModules export')
    args = parser.parse_args()
    result = audit(args.data_root, args.export, args.vehicle_export)
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['ok'] else 1)
