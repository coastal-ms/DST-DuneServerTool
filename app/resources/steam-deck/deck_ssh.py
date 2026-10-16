"""Private key-only SSH owned by the logged-in Deck user; no system changes."""
import base64
import getpass
import ipaddress
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import time

PRIVATE_SSH_UNIT = 'dst-deck-companion-ssh.service'
PRIVATE_SSH_MARKER = '# Managed by DST Deck Companion\n'


def private_write(path, data, mode=0o600):
    for item in (path, *path.parents):
        if item.is_symlink():
            raise ValueError('A companion setup path is a symbolic link; setup stopped')
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name('.dst-' + os.urandom(12).hex())
    try:
        with temporary.open('xb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(mode)
        temporary.replace(path)
    finally:
        if temporary.exists():
            temporary.unlink()


def private_quote(value, systemd=False):
    if any(char in str(value) for char in '\r\n\0'):
        raise ValueError('Unsupported connection setup path')
    value = str(value).replace('\\', '\\\\').replace('"', '\\"')
    if systemd:
        value = value.replace('%', '%%').replace('$', '$$')
    return '"' + value + '"'


def private_tools():
    server = shutil.which('sshd')
    if not server:
        server = next((str(path) for path in (Path('/usr/bin/sshd'), Path('/usr/sbin/sshd')) if path.is_file()), None)
    keygen = shutil.which('ssh-keygen')
    if not server or not keygen or not shutil.which('systemctl'):
        raise RuntimeError('The stock SteamOS connection tools are unavailable. No packages or system services were changed.')
    return str(Path(server).resolve()), str(Path(keygen).resolve())


def private_run(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise RuntimeError('Private Deck connection setup failed: ' + (result.stderr.strip() or result.stdout.strip())[:1000])
    return result


def wait_private_connection(port):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.5) as stream:
                if stream.recv(4) == b'SSH-':
                    return
        except OSError:
            pass
        time.sleep(.1)
    raise RuntimeError('The private Deck connection did not start. No account password or system service was changed.')


def install_private_connection(home, public_key, source, pc):
    address = ipaddress.IPv4Address(pc)
    if not address.is_private or address.is_loopback:
        raise ValueError('Use the paired PC local-network address')
    fields = public_key.strip().split()
    if len(public_key) > 1024 or not re.fullmatch(r'ssh-ed25519 [A-Za-z0-9+/=]+(?: [^\r\n]*)?', public_key.strip()):
        raise ValueError('Unsupported pairing key')
    blob = base64.b64decode(fields[1], validate=True)
    if len(blob) != 51 or not blob.startswith(b'\0\0\0\x0bssh-ed25519\0\0\0\x20'):
        raise ValueError('Invalid pairing public key')
    username = getpass.getuser()
    if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', username):
        raise ValueError('Unsupported SteamOS user name')
    server, keygen = private_tools()
    folder = home / '.local/share/dst-deck-companion'
    private = folder / 'private-ssh'
    unit = home / '.config/systemd/user' / PRIVATE_SSH_UNIT
    for item in (folder, private, unit, *unit.parents, *private.parents):
        if item.is_symlink():
            raise ValueError('A companion setup path is a symbolic link; setup stopped')
    if unit.exists() and not unit.read_text().startswith(PRIVATE_SSH_MARKER):
        raise ValueError('An unrelated service uses the companion name; it was preserved')
    private.mkdir(mode=0o700, parents=True, exist_ok=True)
    folder.chmod(0o700)
    private.chmod(0o700)
    reader = folder / 'reader.py'
    private_write(reader, source)
    host = private / 'host_ed25519'
    for path in (host, host.with_suffix('.pub')):
        if path.is_symlink():
            raise ValueError('Private host key is a symbolic link')
    if not host.exists():
        private_run([keygen, '-q', '-t', 'ed25519', '-N', '', '-f', str(host)])
    host.chmod(0o600)
    host_key = private_run([keygen, '-y', '-f', str(host)]).stdout.strip()
    if not re.fullmatch(r'ssh-ed25519 [A-Za-z0-9+/=]+(?: [^\r\n]*)?', host_key):
        raise ValueError('Private connection host key could not be verified')
    authorized = private / 'authorized_keys'
    private_write(authorized, ('from="' + str(address) + '",restrict ' + ' '.join(fields[:2]) + '\n').encode())
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as available:
        available.bind(('0.0.0.0', 0))
        port = available.getsockname()[1]
    config = private / 'sshd_config'
    contents = '\n'.join([
        PRIVATE_SSH_MARKER.rstrip(), 'Port ' + str(port), 'AddressFamily inet', 'ListenAddress 0.0.0.0',
        'HostKey ' + private_quote(host), 'PidFile ' + private_quote(private / 'sshd.pid'),
        'AuthorizedKeysFile ' + private_quote(authorized), 'UsePAM no',
        'PasswordAuthentication no', 'KbdInteractiveAuthentication no', 'AuthenticationMethods publickey',
        'PubkeyAuthentication yes', 'StrictModes yes', 'PermitRootLogin no', 'AllowUsers ' + username,
        'DisableForwarding yes', 'PermitTTY no', 'PermitUserRC no', 'PermitUserEnvironment no',
        'ForceCommand /usr/bin/python3 ' + shlex.quote(str(reader)) + ' --diagnose',
        'LoginGraceTime 10', 'MaxAuthTries 2', 'MaxStartups 3:50:6', 'LogLevel ERROR', ''])
    private_write(config, contents.encode())
    private_run([server, '-t', '-f', str(config)])
    service = PRIVATE_SSH_MARKER + '\n'.join([
        '[Unit]', 'Description=DST Deck private connection', 'After=network.target', '', '[Service]',
        'Type=simple', 'ExecStart=' + private_quote(server, True) + ' -D -e -f ' + private_quote(config, True),
        'Restart=on-failure', 'RestartSec=2', 'UMask=0077', 'NoNewPrivileges=yes',
        'KillMode=control-group', 'TimeoutStopSec=5', '', '[Install]', 'WantedBy=default.target', ''])
    private_write(unit, service.encode())
    private_run(['systemctl', '--user', 'daemon-reload'])
    private_run(['systemctl', '--user', 'enable', PRIVATE_SSH_UNIT])
    private_run(['systemctl', '--user', 'restart', PRIVATE_SSH_UNIT])
    private_run(['systemctl', '--user', 'is-active', '--quiet', PRIVATE_SSH_UNIT])
    wait_private_connection(port)
    return folder, {'host_key': host_key, 'ssh_user': username, 'ssh_port': port}


def stop_private_connection(home):
    unit = home / '.config/systemd/user' / PRIVATE_SSH_UNIT
    if unit.is_symlink() or not unit.is_file() or not unit.read_text().startswith(PRIVATE_SSH_MARKER):
        raise ValueError('No owned DST connection service was found; nothing changed')
    private_run(['systemctl', '--user', 'disable', '--now', PRIVATE_SSH_UNIT])
