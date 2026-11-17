"""Compare DST catalogs with a merged CDT_BaseItems export; never modifies game data."""
import argparse
from collections import Counter
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_runtime_cache = {}
# These game actions identify specialist workflows independently of our ledger.
ACTION_WORKFLOWS = {
    "Class'GameItemActionCustomization'": 'customizations',
    "Class'GameActions_Emote'": 'emotes',
    "Class'GameItemActionAddFactionReputation'": 'faction-progression',
}


def runtime_catalogs(data_root):
    """Execute the product loaders against these data files, not a Python imitation.

    A temporary application layout also makes fixture data use the exact same
    relative-path loaders as an installation. No app startup or game access occurs.
    Cache by content, never just pathname: edited fixture/source files invalidate it.
    """
    libraries = [ROOT / 'app/server/lib' / name for name in ('Gameplay.ps1', 'Catalog.ps1')]
    files = [data_root / name for name in ('gameplay-item-data.json', 'item-catalog.json',
             'building-sets.json', 'legitimate-customizations.json', 'cosmetic-grants.json')]
    exporter = Path(__file__).with_name('export-catalog.ps1')
    digest = hashlib.sha256(b''.join(p.read_bytes() for p in libraries + files + [exporter])).hexdigest()
    if digest not in _runtime_cache:
        shell = shutil.which('pwsh')
        if not shell:
            raise RuntimeError('PowerShell 7 is required to audit the actual runtime catalogs')
        with tempfile.TemporaryDirectory(prefix='dst-catalog-audit-') as folder:
            app = Path(folder) / 'app'
            (app / 'server/lib').mkdir(parents=True)
            (app / 'data').mkdir()
            for path in libraries:
                shutil.copyfile(path, app / 'server/lib' / path.name)
            for path in files:
                shutil.copyfile(path, app / 'data' / path.name)
            result = subprocess.run([shell, '-NoProfile', '-NonInteractive', '-File', str(exporter),
                                     '-AppRoot', str(app)], capture_output=True, text=True,
                                    encoding='utf-8-sig', timeout=60, check=True)
            value = json.loads(result.stdout)
            if value.get('schemaVersion') != 1 or not isinstance(value.get('cosmetics'), list) or not isinstance(value.get('items'), list):
                raise ValueError('Invalid runtime catalog export')
            _runtime_cache[digest] = value
    return _runtime_cache[digest]


def faction_surfaces():
    """Inspect the actual selectable values and backend branches; fail closed on drift."""
    shared = (ROOT / 'webui/src/pages/gameplay/players/sections.tsx').read_text(encoding='utf-8')
    solo = (ROOT / 'webui/src/components/solo/SoloFactionProgression.tsx').read_text(encoding='utf-8')
    backend = (ROOT / 'app/server/lib/PlayersAdmin.ps1').read_text(encoding='utf-8-sig')
    api = (ROOT / 'webui/src/api/gameplay.ts').read_text(encoding='utf-8')
    routes = (ROOT / 'app/server/routes/PlayersAdmin.ps1').read_text(encoding='utf-8-sig')
    solo_backend = (ROOT / 'app/server/lib/SoloMode.ps1').read_text(encoding='utf-8-sig')
    form = re.search(r"id: 'give-faction-rep'.*?options:\s*\[(.*?)\].*?run:.*?giveFactionRep", shared, re.S)
    options = set(re.findall(r"value:\s*'([^']+)'", form[1])) if form else set()
    mapping = re.search(r'const FACTION_NAME_TO_ID[^=]*=\s*\{([^}]+)\}', api)
    ids = dict(re.findall(r'(\w+):\s*(\d+)', mapping[1])) if mapping else {}
    function = re.search(r'function Invoke-DunePlayerGiveFactionRep\s*\{(.*?)(?=\nfunction |\Z)', backend, re.S)
    guard = re.search(r'if \(\$FactionId -ne (\d+) -and \$FactionId -ne (\d+)\)', function[1]) if function else None
    allowed_ids = set(guard.groups()) if guard else set()
    branches = {name for name, number in ids.items() if number in allowed_ids}
    if not re.search(r"Register-DuneRoute -Method POST -Path '/api/gameplay/players/give-faction-rep'.*?Invoke-DunePlayerGiveFactionRep", routes, re.S):
        branches = set()
    guard = re.search(r"\$Faction -notin @\(([^)]+)\)", solo_backend)
    allowed = set(re.findall(r"'([^']+)'", guard[1])) if guard else set()
    solo_options = set(re.findall(r'<option value="([^"]+)"', solo))
    return {'self-hosted': options & branches, 'solo': solo_options & allowed}


def audit(data_root, export=None, vehicle_export=None, ui_root=None):
    data_root = Path(data_root)
    rules = json.loads((data_root / 'gameplay-item-data.json').read_text(encoding='utf-8'))
    picker = json.loads((data_root / 'item-catalog.json').read_text(encoding='utf-8'))
    coverage = json.loads((data_root / 'game-item-coverage.json').read_text(encoding='utf-8'))
    building = json.loads((data_root / 'building-sets.json').read_text(encoding='utf-8'))
    tech = json.loads((data_root / 'dune-tech-catalog.json').read_text(encoding='utf-8'))
    modules = json.loads((data_root / 'vehicle-module-durability.json').read_text(encoding='utf-8'))
    ui_root = Path(ui_root) if ui_root else ROOT / 'webui/src'
    emotes = json.loads((ui_root / 'data/emotes.json').read_text(encoding='utf-8'))
    runtime = runtime_catalogs(data_root)
    cosmetics = {entry['template']: entry for entry in runtime['cosmetics']}
    runtime_items = {entry['templateId']: entry for entry in runtime['items']}
    emote_items = {entry['template']: entry for entry in emotes['entries']}
    factions = faction_surfaces()
    expected = coverage['items']
    schematic_ids = set()
    action_workflows = {}
    game_actions = {}
    if export is not None:
        source = json.loads(Path(export).read_text(encoding='utf-8-sig'))
        master = next(item for item in source if item.get('Name') == 'CDT_BaseItems')
        schematic_ids = {key for key, row in master['Rows'].items()
                         if 'Schematic' in (row.get('ActionsClass') or {}).get('ObjectName', '')}
        action_workflows = {key: ACTION_WORKFLOWS[action] for key, row in master['Rows'].items()
                            if (action := (row.get('ActionsClass') or {}).get('ObjectName', '')) in ACTION_WORKFLOWS}
        game_actions = {key: (row.get('ActionsClass') or {}).get('ObjectName', '') for key, row in master['Rows'].items()}
        expected = {key: {'maxDurability': row['StackAndDurability']['MaxDurability']} for key, row in master['Rows'].items()}
    issues = []
    exclusions = []
    workflow_counts = Counter()
    for key, definition in expected.items():
        if key in schematic_ids:
            for name, label in [('picker', picker['items'].get(key, {}).get('name', '')),
                                ('inventory', rules['names'].get(key, ''))]:
                if not re.search(r'\bschematic\b', label, re.IGNORECASE):
                    issues.append({'template': key, 'issue': f'unmarked-{name}-schematic'})
        item = rules['items'].get(key)
        if not item or item.get('durability_known') is not True or item.get('max_durability') != definition['maxDurability']:
            issues.append({'template': key, 'issue': 'missing-or-outdated-game-definition'})
        if not rules['names'].get(key):
            issues.append({'template': key, 'issue': 'missing-display-name'})
        route = coverage['items'].get(key, {}).get('workflow')
        if key in action_workflows and route != action_workflows[key]:
            issues.append({'template': key, 'issue': 'workflow-disagrees-with-game-action',
                           'declared': route, 'expected': action_workflows[key]})
            # Still inspect the real destination; a bad label cannot hide a gap.
            route = action_workflows[key]
        workflow_counts[route or 'unclassified'] += 1
        if route == 'item-picker':
            if not runtime_items.get(key, {}).get('name'):
                issues.append({'template': key, 'issue': 'missing-item-picker-entry'})
        elif route == 'building-unlocks':
            entry = cosmetics.get(key, {})
            if not (entry.get('name') and entry.get('group', '').startswith('Building Sets - ')) and key not in runtime_items:
                issues.append({'template': key, 'issue': 'missing-building-grant-entry'})
        elif route == 'customizations':
            if not cosmetics.get(key, {}).get('name'):
                issues.append({'template': key, 'issue': 'missing-cosmetic-grant-entry'})
        elif route == 'emotes':
            if not emote_items.get(key, {}).get('name'):
                issues.append({'template': key, 'issue': 'missing-emote-grant-entry'})
        elif route == 'faction-progression':
            faction = {'SmugglersReputation': 'smuggler'}.get(key, key.removesuffix('Reputation').lower())
            for mode, supported in factions.items():
                if faction not in supported:
                    issues.append({'template': key, 'issue': 'missing-faction-progression-entry', 'mode': mode})
        elif route == 'tech-unlocks':
            if coverage['items'][key].get('techKey') not in tech['item_keys']:
                issues.append({'template': key, 'issue': 'missing-tech-unlock-entry'})
        elif route == 'not-grantable':
            if key not in building['_meta']['flagged_no_item_form']:
                issues.append({'template': key, 'issue': 'unsupported-exclusion'})
            else:
                exclusions.append({'template': key, 'name': rules['names'].get(key, key),
                                   'basis': 'Explicit building-sets catalog flagged_no_item_form entry'})
        else:
            issues.append({'template': key, 'issue': 'unclassified-item-workflow'})
    if vehicle_export is not None:
        source = json.loads(Path(vehicle_export).read_text(encoding='utf-8-sig'))
        master = next(item for item in source if item.get('Name') == 'CDT_BaseVehicleModules')
        for key, row in master['Rows'].items():
            if modules['defaults'].get(key) != row['m_DurabilityStats']['MaxDurability']:
                issues.append({'template': key, 'issue': 'missing-or-outdated-installed-module-cap'})
    # Known unavailable game tokens stay visible, with exact definitions and
    # reasons. Never waive a new ID, a changed definition or an unrelated issue.
    unsupported = json.loads(Path(__file__).with_name('unsupported-templates.json').read_text(encoding='utf-8'))
    if unsupported.get('schemaVersion') != 1:
        raise ValueError('Unsupported catalog exclusion schema')
    known_unavailable = []
    for entry in unsupported['entries']:
        key = entry['template']
        if key not in expected:
            continue
        matches = [i for i in issues if i['template'] == key and i['issue'] == entry['issue']
                   and i.get('mode') in entry.get('modes', [None])]
        definition_matches = (rules['names'].get(key) == entry['gameName']
                              and coverage['items'].get(key, {}).get('workflow') == entry['workflow']
                              and (export is None or game_actions.get(key) == entry['actionClass']))
        if not definition_matches:
            issues.append({'template': key, 'issue': 'unsupported-exclusion-definition-changed'})
        elif not matches:
            issues.append({'template': key, 'issue': 'stale-unsupported-exclusion'})
        else:
            for issue in matches:
                issues.remove(issue)
                known_unavailable.append({**issue, 'name': entry['gameName'], 'reason': entry['reason'],
                                          'actionClass': entry['actionClass']})
    for issue in issues:
        issue['name'] = rules['names'].get(issue['template'], issue['template'])
    return {'ok': not issues, 'gameItems': len(expected), 'positiveDurabilityCaps': sum(v['maxDurability'] > 0 for v in expected.values()), 'vehicleModules': len(modules['defaults']),
            'reference': 'game-export' if export else 'bundled-coverage-ledger',
            'sourceSha256': hashlib.sha256(Path(export).read_bytes()).hexdigest() if export else None,
            'vehicleSourceSha256': hashlib.sha256(Path(vehicle_export).read_bytes()).hexdigest() if vehicle_export else None,
            'scope': 'Catalog availability and backing definitions; not proof of in-game grant acceptance',
            'workflows': dict(sorted(workflow_counts.items())),
            'runtimeCatalogs': {'items': len(runtime_items), 'cosmetics': len(cosmetics), 'emotes': len(emote_items)},
            'exclusions': exclusions,
            'knownUnavailable': known_unavailable,
            'allGameTemplatesAvailable': not issues and not exclusions and not known_unavailable,
            'issueCounts': dict(sorted(Counter(issue['issue'] for issue in issues).items())), 'issues': issues}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--export', type=Path, help='Current merged CDT_BaseItems JSON export')
    parser.add_argument('--data-root', type=Path, default=ROOT / 'app/data')
    parser.add_argument('--vehicle-export', type=Path, help='Current merged CDT_BaseVehicleModules export')
    args = parser.parse_args()
    result = audit(args.data_root, args.export, args.vehicle_export)
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['ok'] else 1)
