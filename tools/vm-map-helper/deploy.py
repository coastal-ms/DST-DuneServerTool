"""Deploy an explicitly prepared private bundle to the isolated test namespace."""
import argparse
import ipaddress
import json
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--vm-ip', required=True)
    parser.add_argument('--ssh-key', required=True, type=Path)
    parser.add_argument('--ssh-user', default='dune')
    args = parser.parse_args()
    ipaddress.ip_address(args.vm_ip)
    if not re.fullmatch(r'[a-z_][a-z0-9_-]*', args.ssh_user):
        parser.error('Invalid SSH user')
    manifest = (args.bundle / 'deploy.private.json').read_bytes()
    resources = json.loads(manifest)['items']
    pod = next(r for r in resources if r['kind'] == 'Pod')
    if pod['metadata'] != {'name': 'map-helper', 'namespace': 'dst-map-prototype'}:
        raise ValueError('Expected the isolated prototype pod')
    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
           '-o', 'ConnectTimeout=5', '-i', str(args.ssh_key),
           args.ssh_user + '@' + args.vm_ip]
    # Refuse overwriting a previous installation, its data or its access keys.
    command = ('set -eu; sudo mkdir -p /var/lib/dst-map-prototype; '
               'test -z "$(sudo ls -A /var/lib/dst-map-prototype)"; '
               'sudo tar -xzf - -C /var/lib/dst-map-prototype; '
               'sudo chmod 700 /var/lib/dst-map-prototype/secrets')
    with (args.bundle / 'prototype.private.tar.gz').open('rb') as stream:
        subprocess.run(ssh + [command], stdin=stream, check=True)
    subprocess.run(ssh + ['sudo k3s kubectl apply -f -'], input=manifest, check=True)
    subprocess.run(ssh + ['sudo k3s kubectl wait --for=condition=Ready '
                         'pod/map-helper -n dst-map-prototype --timeout=90s'], check=True)
    print('Isolated prototype deployed. Existing live-map routing is unchanged.')


if __name__ == '__main__':
    main()
