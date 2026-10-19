"""Exact executable identities for read-only Atlas discovery."""
from pathlib import Path
import json

LEGACY_BUILDS = {
    'c04524c353ec9657759e95235ae93fb76f1ccde8838f6c5a59bc1ef4e1305522',
    '240b4bb378a93b70134fa685fc467bc2ae94fd40d81da2feea0f987758bc9126',
}
CURRENT_BUILD = 'e62fa7fd8697d8fd2108be97dee6b16ab8c30d07dd0d80d5765c095264e6a114'
BUILDS = LEGACY_BUILDS | {CURRENT_BUILD}


def profile(root, digest):
    root = Path(root)
    shared = root.parent if root.name == 'hagga' else root
    if digest == CURRENT_BUILD:
        value = json.loads((shared / 'build-2156652.json').read_text())
        if value['sha256'] != digest:
            raise ValueError('Atlas build profile identity mismatch')
        return value
    if digest not in LEGACY_BUILDS:
        raise ValueError('Unrecognized server build; native collector remains unavailable')
    return {
        'sha256': digest,
        'namePoolTableOffset': 390184232,
        'symbols': {s['name']: s['value'] for s in json.loads((root / 'native-symbols.json').read_text())},
    }


def symbol_rows(root, digest, legacy_table):
    if digest == CURRENT_BUILD:
        return [{'name': name, 'value': value} for name, value in profile(root, digest)['symbols'].items()]
    if digest not in LEGACY_BUILDS:
        raise ValueError('Unrecognized server build; native collector remains unavailable')
    if legacy_table not in ('all-native-vtables.json', 'all-component-pools.json'):
        raise ValueError('Unknown Atlas symbol table')
    return json.loads((Path(root) / legacy_table).read_text())
