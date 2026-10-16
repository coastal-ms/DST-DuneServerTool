"""Build the experimental stock-SteamOS companion using only Python's stdlib.

Build-time tool; the Windows DST runtime does not need Python. Pairing transport
is still experimental and must be integrated before offering this as a download.
"""
import argparse
import base64
import copy
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'app/resources/steam-deck'


def source_fingerprint():
    paths = ['scripts/build-deck-companion.py', 'app/server/lib/SoloMode.ps1']
    paths += ['app/resources/steam-deck/' + name for name in (
        'deck_helper.py', 'settings_writer.py', 'settings_batch.py',
        'deck_mods.py', 'deck_modlaunch.py', 'deck_ssh.py', 'companion.py')]
    text = ''.join(name + '\0' + (ROOT / name).read_text(encoding='utf-8-sig') + '\0' for name in paths)
    return hashlib.sha256(text.encode()).hexdigest()


def settings_schema():
    source = (ROOT / 'app/server/lib/SoloMode.ps1').read_text(encoding='utf-8-sig')
    key_match = re.search(r'\$script:DuneSoloSettingKeys = @\((.*?)\n\)', source, re.S)
    if not key_match:
        raise ValueError('Solo setting definitions not found')
    console_block = source.split('$script:DuneSoloConsoleSettings = @(', 1)[1].split('\nfunction ', 1)[0]
    schema = {
        'ServerCustomSettings.ini': {
            '/Script/DuneSandbox.UserServerCustomSettings': re.findall(r"'([^']+)'", key_match[1]),
        },
        'Engine.ini': {'ConsoleVariables': re.findall(r"key\s*=\s*'([^']+)'", console_block)},
        'Game.ini': {
            '/Script/DuneSandbox.InventorySystemSettings': ['PlayerInventoryStartingSize'],
            '/Script/DuneSandbox.BuildingSettings': ['m_MaxNumLandclaimSegments', 'm_BuildableBuildAndFillHoldTimes'],
        },
    }
    if any(not keys or len(keys) != len(set(keys)) for sections in schema.values() for keys in sections.values()):
        raise ValueError('Missing or duplicate managed setting definitions')
    return schema


def inject(source, marker, value):
    if source.count(marker) != 1:
        raise ValueError('Companion source marker is missing or ambiguous: ' + marker)
    return source.replace(marker, value)


def build():
    schema = settings_schema()
    writable = copy.deepcopy(schema)
    native = writable['ServerCustomSettings.ini']['/Script/DuneSandbox.UserServerCustomSettings']
    # These are game-controlled fields. All other managed Solo settings use
    # the user's final sync approval, including the worm settings warning.
    native[:] = [key for key in native if key not in {'DifficultyLevel', 'PVPMode'}]
    source = inject((SOURCES / 'deck_helper.py').read_text(encoding='utf-8'),
                    'SETTINGS_SCHEMA = {}  # injected from existing DST setting definitions',
                    'SETTINGS_SCHEMA = json.loads(' + repr(json.dumps(schema, sort_keys=True)) + ')')
    source += '\n' + (SOURCES / 'settings_writer.py').read_text(encoding='utf-8')
    batch = inject((SOURCES / 'settings_batch.py').read_text(encoding='utf-8'),
                   'WRITE_SCHEMA = {}  # injected positive allowlist; no arbitrary settings or paths',
                   'WRITE_SCHEMA = json.loads(' + repr(json.dumps(writable, sort_keys=True)) + ')')
    source += '\n' + batch
    for name in ('deck_mods.py', 'deck_modlaunch.py'):
        source += '\n' + (SOURCES / name).read_text(encoding='utf-8')
    source += '\nif __name__ == "__main__":\n    reader_dispatch()\n'
    compile(source, 'reader.py', 'exec')
    companion = inject((SOURCES / 'companion.py').read_text(encoding='utf-8'),
                       '__READER_B64__', base64.b64encode(source.encode()).decode())
    companion = (SOURCES / 'deck_ssh.py').read_text(encoding='utf-8') + '\n' + companion
    compile(companion, 'companion.py', 'exec')
    # Pass the payload through stdin instead of a command argument: Linux has
    # a per-argument size limit and the managed setting definitions can grow.
    delimiter = 'DST_DECK_COMPANION_PYTHON'
    if delimiter in companion:
        raise ValueError('Unexpected shell heredoc delimiter in source')
    script = '#!/bin/sh\n# Source SHA256: ' + source_fingerprint() + '\n# Experimental DST Deck Companion; pair with your own DST PC.\n'
    script += "exec /usr/bin/python3 - <<'" + delimiter + "'\n" + companion + '\n' + delimiter + '\n'
    return script


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    script = build()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(script, encoding='utf-8', newline='\n')
    args.output.chmod(0o755)
    print('Built unpaired experimental Deck companion (' + str(len(script.encode())) + ' bytes).')
