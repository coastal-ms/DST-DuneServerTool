"""Exact executable identities for read-only Atlas discovery."""
from pathlib import Path
import json
import re
import os

LEGACY_BUILDS = {
    'c04524c353ec9657759e95235ae93fb76f1ccde8838f6c5a59bc1ef4e1305522',
    '240b4bb378a93b70134fa685fc467bc2ae94fd40d81da2feea0f987758bc9126',
}
CURRENT_BUILD = 'e62fa7fd8697d8fd2108be97dee6b16ab8c30d07dd0d80d5765c095264e6a114'
TANK_BUILD = '3e8966850e911826f4e5339dea5b3830a71e037acc9b0ed400bc9f0e21e6e318'
CURRENT_BUILDS = {CURRENT_BUILD, TANK_BUILD}
UPDATE_BUILD = 'c7c935767b169c0e9a3ebceb3b8af26e43254d5104a77edea88b76d5fe1840d2'
UPDATE_TANK_BUILD = 'e10c49bd69e3ae8e3eccce3049326d04c4c0e750f767587749429a95ae7f574b'
BUNDLED_PROFILES = {CURRENT_BUILD: ('build-2156652.json', CURRENT_BUILD),
                    TANK_BUILD: ('build-2156652.json', CURRENT_BUILD),
                    UPDATE_BUILD: ('build-2160922.json', UPDATE_BUILD),
                    UPDATE_TANK_BUILD: ('build-2160922.json', UPDATE_BUILD)}
BUILDS = LEGACY_BUILDS | set(BUNDLED_PROFILES)


def profile_cache(root, digest):
    root = Path(root)
    shared = root.parent if root.name == 'hagga' else root
    folder = Path(os.environ.get('DST_ATLAS_PROFILE_ROOT', str(shared)))
    folder.mkdir(parents=True, exist_ok=True)
    return folder / ('server-profile-' + digest + '.json')


def profile(root, digest, runtime=None):
    root = Path(root)
    shared = root.parent if root.name == 'hagga' else root
    if not re.fullmatch('[0-9a-f]{64}', digest):
        raise ValueError('Missing server executable identity')
    if digest in BUNDLED_PROFILES:
        filename, expected = BUNDLED_PROFILES[digest]
        value = json.loads((shared / filename).read_text())
        if value['sha256'] != expected:
            raise ValueError('Atlas build profile identity mismatch')
        # Exact executable hashes select verified addresses. Snapshot readers
        # still validate the current process, class names and object identities.
        value['sha256'] = digest
        return value
    cache = profile_cache(root, digest)
    if cache.is_file():
        value = json.loads(cache.read_text())
        if value.get('sha256') == digest and value.get('discoveredFrom') == 'running-elf-and-name-pool':
            return value
    if runtime is not None:
        import atlas_elf
        value = atlas_elf.inspect(digest, cache_dir=cache.parent, **runtime)
        temp = cache.with_name(cache.name + '.' + str(os.getpid()) + '.tmp')
        temp.write_text(json.dumps(value))
        temp.replace(cache)
        return value
    if digest not in LEGACY_BUILDS:
        raise ValueError('Server layout has not been discovered yet')
    return {
        'sha256': digest,
        'namePoolTableOffset': 390184232,
        'symbols': {s['name']: s['value'] for s in json.loads((root / 'native-symbols.json').read_text())},
    }


def symbol_rows(root, digest, legacy_table):
    if digest in BUNDLED_PROFILES or profile_cache(root, digest).is_file():
        return [{'name': name, 'value': value} for name, value in profile(root, digest)['symbols'].items()]
    if digest not in LEGACY_BUILDS:
        raise ValueError('Server layout has not been discovered yet')
    if legacy_table not in ('all-native-vtables.json', 'all-component-pools.json'):
        raise ValueError('Unknown Atlas symbol table')
    return json.loads((Path(root) / legacy_table).read_text())
