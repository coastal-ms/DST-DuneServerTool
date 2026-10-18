"""Restore our two bounded O_RDONLY Linux readers; never modify the game."""
import atlas_process
from pathlib import Path
import base64
import hashlib
import subprocess
import threading
import time
import uuid

REMOTE_ROOT = '/var/lib/dst-atlas/readers'
EXPECTED = {
    'scan': '2355520cd9849832d8d3e4339afbf92d354ebae6daea030512625298accc7735',
    'bulk': 'ddadfb2d11d148c1fe3fcc72aeb8a2a5245fa125875170cec2024eecbc866e40',
}
_lock = threading.Lock()
_checked = 0


def payloads(root):
    result = {}
    for name, expected in EXPECTED.items():
        encoded = (Path(root) / ('reader-' + name + '.b64')).read_text(encoding='ascii').strip()
        data = base64.b64decode(encoded, validate=True)
        if hashlib.sha256(data).hexdigest() != expected or data[:6] != b'\x7fELF\x02\x01':
            raise ValueError('Invalid bundled Atlas reader: ' + name)
        result[name] = encoded
    return result


def probe_script():
    lines = ['set -eu', 'test "$(uname -m)" = x86_64']
    for directory in ['/var', '/var/lib', '/var/lib/dst-atlas', REMOTE_ROOT]:
        lines += [f'test ! -L {directory}', f'test "$(stat -c %u {directory})" = 0',
                  f'test -z "$(find {directory} -maxdepth 0 -perm /022 -print)"']
    for name, expected in EXPECTED.items():
        path = REMOTE_ROOT + '/' + name
        lines += [f'test ! -L {path}', f'test -x {path}',
                  f'test "$(stat -c %u {path})" = 0',
                  f'test -z "$(find {path} -maxdepth 0 -perm /022 -print)"',
                  f'echo "{expected}  {path}" | sha256sum -c - >/dev/null']
    return '\n'.join(lines) + '\necho ready\n'


def install_script(root):
    bundles = payloads(root)
    lines = ['set -eu', 'test "$(uname -m)" = x86_64']
    # Refuse symlinks or writable parent directories before any privileged write.
    for directory in ['/var', '/var/lib', '/var/lib/dst-atlas', REMOTE_ROOT]:
        lines += [f'test ! -L {directory}',
                  f'if test ! -d {directory}; then mkdir -m 755 {directory}; fi',
                  f'test "$(stat -c %u {directory})" = 0',
                  f'test -z "$(find {directory} -maxdepth 0 -perm /022 -print)"']
    lines += [f'work=$(mktemp -d {REMOTE_ROOT}/.install.XXXXXXXX)',
              'trap \'rm -f "$work/scan" "$work/bulk"; rmdir "$work"\' EXIT HUP INT TERM']
    for name, expected in EXPECTED.items():
        lines += [f"base64 -d > \"$work/{name}\" <<'ATLAS_READER_PAYLOAD'",
                  bundles[name], 'ATLAS_READER_PAYLOAD',
                  f'echo "{expected}  $work/{name}" | sha256sum -c - >/dev/null',
                  f'chmod 755 "$work/{name}"',
                  f'mv -f "$work/{name}" {REMOTE_ROOT}/{name}']
    return '\n'.join(lines) + '\necho installed\n'


def remote(root, script):
    root = Path(root)
    suffix = uuid.uuid4().hex
    command = root / ('reader-setup-' + suffix + '.sh')
    source = root / ('reader-setup-' + suffix + '.input')
    output = root / ('reader-setup-' + suffix + '.txt')
    try:
        # Stream owned source over stdin; large SSH command lines are rejected.
        command.write_text('sudo sh -s', encoding='utf-8', newline='\n')
        source.write_text(script, encoding='utf-8', newline='\n')
        result = atlas_process.run(['pwsh', '-NoProfile', '-File', str(root / 'remote.ps1'),
                                 '-CommandFile', str(command), '-InputFile', str(source),
                                 '-OutputFile', str(output), '-Timeout', '25'],
                                capture_output=True, text=True, timeout=35,
                                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        return result.returncode == 0
    finally:
        command.unlink(missing_ok=True)
        source.unlink(missing_ok=True)
        output.unlink(missing_ok=True)


def ensure(root, run=remote):
    global _checked
    root = Path(root)
    if root.name == 'hagga':
        root = root.parent
    with _lock:
        if time.monotonic() - _checked < 5:
            return
        if not run(root, probe_script()):
            if not run(root, install_script(root)) or not run(root, probe_script()):
                raise RuntimeError('Atlas read-only helper setup failed; live observation is unavailable')
        _checked = time.monotonic()
