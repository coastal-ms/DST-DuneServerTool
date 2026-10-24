"""Build a private prototype bundle; runtime data and secrets never enter Git."""
import argparse
import datetime
import ipaddress
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile
import time

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from access import issue


def main():
    p = argparse.ArgumentParser()
    for name in ('source', 'active-runtime', 'assets', 'settings', 'accounts', 'output', 'vm-ip', 'namespace', 'db-pod', 'profiles'):
        p.add_argument('--' + name, required=True)
    a = p.parse_args()
    out = Path(a.output)
    stage = out / 'bundle'
    if stage.exists():
        raise RuntimeError('Use a fresh private output directory')
    atlas = stage / 'atlas'
    atlas.mkdir(parents=True)
    source = Path(a.source)
    manifest = json.loads((source / 'manifest.json').read_text())
    for relative, digest in manifest['files'].items():
        if Path(relative).is_absolute() or '..' in Path(relative).parts:
            raise ValueError('Invalid map manifest path')
        if hashlib.sha256((source / relative).read_bytes()).hexdigest() != digest:
            raise ValueError('Map manifest mismatch: ' + relative)
        target = atlas / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / relative, target)
    for relative in ('', 'hagga'):
        active = Path(a.active_runtime) / relative
        for file in active.glob('*.json'):
            if file.name in ('runtime-context.json', 'native-hits-new.json', 'native-snapshot-current.json',
                             'native-pois-current.json', 'native-static-marker-sites.json',
                             'storm-cycle-anchor.json', 'storm-route-observations.json') \
                    or file.name.endswith('-cache.json') or file.name.startswith(('gathering-', 'native-gathering', 'poi-discovery-')):
                shutil.copy2(file, atlas / relative / file.name)
        context = json.loads((atlas / relative / 'runtime-context.json').read_text())
        profile = Path(a.profiles) / ('server-profile-' + context['sha256'] + '.json')
        if profile.is_file():
            shutil.copy2(profile, atlas / profile.name)
    assets = stage / 'assets'
    assets.mkdir()
    for file in Path(a.assets).iterdir():
        if file.is_file() and not file.name.startswith(('dd-layout-', 'hagga-background-')):
            shutil.copy2(file, assets / file.name)
    settings = stage / 'settings'
    settings.mkdir()
    for file in Path(a.settings).glob('*.json'):
        shutil.copy2(file, settings / file.name)
    # Prototype starts idle even when the current map is Live. Benchmark starts it independently.
    (settings / 'live-v1.json').write_text('{"enabled":false}')
    prototype = stage / 'prototype'
    prototype.mkdir()
    here = Path(__file__).parent
    for name in ('local_pwsh.py', 'gateway.py', 'access.py', 'entrypoint.py'):
        shutil.copy2(here / name, prototype / name)
    bin_dir = stage / 'bin'
    bin_dir.mkdir()
    (bin_dir / 'pwsh').write_text('#!/bin/sh\nexec python /prototype/local_pwsh.py "$@"\n', newline='\n')
    (bin_dir / 'sudo').write_text('#!/bin/sh\nexec "$@"\n', newline='\n')
    art = source.parents[2] / 'webui' / 'public' / 'wickmaps'
    if art.is_dir():
        shutil.copytree(art, stage / 'webui' / 'dist' / 'wickmaps')
    secrets = stage / 'secrets'
    secrets.mkdir()
    accounts = json.loads(Path(a.accounts).read_text(encoding='utf-8-sig'))
    safe = [{key: row.get(key) for key in ('id', 'role', 'enabled', 'mustChangePassword')}
            for row in accounts.get('accounts', [])]
    owner = next(row for row in safe if row['role'] == 'owner' and row['enabled'] and not row['mustChangePassword'])
    (secrets / 'acl.json').write_text(json.dumps({'validUntil': time.time() + 3600, 'accounts': safe}))
    grant_key = os.urandom(32)
    (secrets / 'grant.key').write_bytes(grant_key)
    # Two grants for the authenticated local owner vs normal remote viewing controls.
    (out / 'owner-grant.private').write_text(issue(grant_key, owner, local_owner=True))
    (out / 'viewer-grant.private').write_text(issue(grant_key, owner))
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'DST map prototype')])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(private_key.public_key()) \
        .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(minutes=1)) \
        .not_valid_after(now + datetime.timedelta(days=1)) \
        .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address(a.vm_ip))]), critical=False) \
        .sign(private_key, hashes.SHA256())
    (secrets / 'cert.pem').write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    (out / 'cert.pem').write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    (secrets / 'key.pem').write_bytes(private_key.private_bytes(serialization.Encoding.PEM,
                                  serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    ns = 'dst-map-prototype'
    env = {'DST_MAP_ROOT': '/work/atlas', 'DST_MAP_SECRETS': '/secrets', 'DST_MAP_BIND': a.vm_ip,
           'DST_MAP_PORT': '18443', 'DST_MAP_NAMESPACE': a.namespace, 'DST_ATLAS_PORT': '18444',
           'DST_MAP_KUBECTL': '/kube-bin/kubectl',
           'DST_ATLAS_APP_ROOT': '/work', 'DST_ATLAS_SNAPSHOT_ROOT': '/work/snapshots',
           'DST_ATLAS_PREFERENCES_ROOT': '/work/settings', 'DST_ATLAS_ASSET_ROOT': '/work/assets',
           'PATH': '/prototype-bin:/usr/local/bin:/usr/bin:/bin', 'PYTHONUNBUFFERED': '1'}
    base = '/var/lib/dst-map-prototype'
    mounts = [('work', base, '/work', False), ('prototype', base + '/prototype', '/prototype', True),
              ('bin', base + '/bin', '/prototype-bin', True), ('secrets', base + '/secrets', '/secrets', True),
              ('readers', '/var/lib/dst-atlas/readers', '/var/lib/dst-atlas/readers', True),
              ('kube-bin', '/var/lib/rancher/k3s/data/current/bin', '/kube-bin', True)]
    resources = [dict(apiVersion='v1', kind='Namespace', metadata=dict(name=ns)),
                 dict(apiVersion='v1', kind='ServiceAccount', metadata=dict(name='map-helper', namespace=ns)),
                 dict(apiVersion='rbac.authorization.k8s.io/v1', kind='Role',
                      metadata=dict(name='map-prototype-reader', namespace=a.namespace), rules=[
                          dict(apiGroups=[''], resources=['pods'], verbs=['get', 'list']),
                          dict(apiGroups=[''], resources=['pods/exec'], verbs=['create'],
                               resourceNames=[a.db_pod])]),
                 dict(apiVersion='rbac.authorization.k8s.io/v1', kind='RoleBinding',
                      metadata=dict(name='map-prototype-reader', namespace=a.namespace),
                      roleRef=dict(apiGroup='rbac.authorization.k8s.io', kind='Role', name='map-prototype-reader'),
                      subjects=[dict(kind='ServiceAccount', name='map-helper', namespace=ns)]),
                 dict(apiVersion='v1', kind='Pod', metadata=dict(name='map-helper', namespace=ns), spec=dict(
                     hostPID=True, hostNetwork=True, dnsPolicy='ClusterFirstWithHostNet', restartPolicy='Never',
                     activeDeadlineSeconds=3600, terminationGracePeriodSeconds=10, serviceAccountName='map-helper',
                     containers=[dict(name='map', image='docker.io/library/python:3.12-alpine', imagePullPolicy='Never',
                         command=['python', '/prototype/entrypoint.py'],
                         env=[dict(name=k, value=v) for k, v in env.items()],
                         resources=dict(requests=dict(cpu='50m', memory='64Mi'), limits=dict(cpu='1000m', memory='512Mi')),
                         securityContext=dict(runAsUser=0, capabilities=dict(add=['SYS_PTRACE']),
                                              seccompProfile=dict(type='RuntimeDefault')),
                         volumeMounts=[dict(name=n, mountPath=t, readOnly=ro) for n, _, t, ro in mounts])],
                     volumes=[dict(name=n, hostPath=dict(path=h, type='Directory'))
                              for n, h, _, _ in mounts]))]
    (out / 'deploy.private.json').write_text(json.dumps(dict(apiVersion='v1', kind='List', items=resources)))
    with tarfile.open(out / 'prototype.private.tar.gz', 'w:gz') as tar:
        for file in stage.rglob('*'):
            if not file.is_file():
                continue
            info = tar.gettarinfo(str(file), arcname=file.relative_to(stage).as_posix())
            info.mode = 0o700 if file.parent == bin_dir else 0o600 if 'secrets' in file.parts else 0o644
            info.uid = info.gid = 0
            with file.open('rb') as f:
                tar.addfile(info, f)
    print(json.dumps({'files': len(list(stage.rglob('*'))),
                      'bundleBytes': (out / 'prototype.private.tar.gz').stat().st_size,
                      'containsPrivateRuntimeData': True, 'existingMapChanged': False}))


if __name__ == '__main__':
    main()
