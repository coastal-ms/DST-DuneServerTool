"""Create a per-installation private helper package from verified local assets."""
import base64
import hashlib
import json
from pathlib import Path
import shutil
import tarfile

IMAGE = 'docker.io/library/python@sha256:b658b05ce9c4eb97ec6fc19424818a1f31993659c2b505a532f470e83807815d'
BASE = '/var/lib/dst-map-helper'
NAMESPACE = 'dst-map-helper'


def prepare(config):
    helper = Path(__file__).parent
    definition = json.loads((helper / 'manifest.json').read_text(encoding='utf-8'))
    for name, expected in definition['files'].items():
        if Path(name).name != name or hashlib.sha256((helper / name).read_bytes()).hexdigest() != expected:
            raise ValueError('VM map helper package verification failed')
    out = Path(config['output'])
    stage = out / 'bundle'
    stage.mkdir(parents=True, exist_ok=False)
    atlas = stage / 'atlas'
    source = Path(config['source'])
    manifest = json.loads((source / 'manifest.json').read_text())
    for relative, expected in manifest['files'].items():
        if not relative or relative.startswith(('/', '\\')) or ':' in relative or '..' in Path(relative).parts:
            raise ValueError('Invalid packaged map path')
        data = (source / relative).read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError('Map package verification failed: ' + relative)
        target = atlas / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    for region in ('', 'hagga'):
        active = Path(config['activeRuntime']) / region
        for file in active.glob('*.json'):
            if (file.name in ('runtime-context.json', 'native-hits-new.json', 'native-snapshot-current.json',
                              'native-pois-current.json', 'native-static-marker-sites.json',
                              'storm-cycle-anchor.json', 'storm-route-observations.json') or
                    file.name.endswith('-cache.json') or file.name.startswith(('gathering-', 'native-gathering', 'poi-discovery-'))):
                shutil.copy2(file, atlas / region / file.name)
        context = atlas / region / 'runtime-context.json'
        if not context.exists():
            shutil.copy2(atlas / region / 'bootstrap-context.json', context)
        identity = json.loads(context.read_text())
        profile = Path(config['profiles']) / ('server-profile-' + identity['sha256'] + '.json')
        if profile.is_file():
            shutil.copy2(profile, atlas / profile.name)
    for directory in ('assets', 'settings', 'code', 'bin', 'readers', 'secrets', 'sessions'):
        (stage / directory).mkdir()
    for file in Path(config['assets']).glob('*'):
        if file.is_file() and not file.name.startswith(('dd-layout-', 'hagga-background-')):
            shutil.copy2(file, stage / 'assets' / file.name)
    for file in Path(config['settings']).glob('*.json'):
        shutil.copy2(file, stage / 'settings' / file.name)
    (stage / 'settings' / 'live-v1.json').write_text(json.dumps({'enabled': True}))
    art = Path(config['appRoot']) / 'webui' / 'dist' / 'wickmaps'
    if not art.exists():
        art = Path(config['appRoot']).parent / 'webui' / 'public' / 'wickmaps'
    if art.is_dir():
        shutil.copytree(art, stage / 'webui' / 'dist' / 'wickmaps')
    for name in ('collector.py', 'local_pwsh.py'):
        shutil.copy2(Path(__file__).parent / name, stage / 'code' / name)
    (stage / 'bin' / 'pwsh').write_text('#!/bin/sh\nexec python /code/local_pwsh.py "$@"\n', newline='\n')
    (stage / 'bin' / 'sudo').write_text('#!/bin/sh\nexec "$@"\n', newline='\n')
    readers = {'scan': '2355520cd9849832d8d3e4339afbf92d354ebae6daea030512625298accc7735',
               'bulk': 'ddadfb2d11d148c1fe3fcc72aeb8a2a5245fa125875170cec2024eecbc866e40'}
    for name, expected in readers.items():
        data = base64.b64decode((atlas / ('reader-' + name + '.b64')).read_text().strip(), validate=True)
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError('Invalid bundled read-only observer')
        (stage / 'readers' / name).write_bytes(data)
    for name, key in [('cert.pem', 'tlsCert'), ('key.pem', 'tlsKey')]:
        if config.get(key):
            shutil.copy2(config[key], stage / 'secrets' / name)
    spec = deployment(config)
    (out / 'deploy.private.json').write_text(json.dumps(spec))
    with tarfile.open(out / 'helper.private.tar.gz', 'w:gz') as tar:
        for file in sorted(stage.rglob('*')):
            info = tar.gettarinfo(str(file), arcname=file.relative_to(stage).as_posix())
            info.uid = 65532 if info.name == 'sessions' else 0
            info.gid = 65532 if info.name.startswith(('sessions', 'secrets')) else 0
            info.mode = (0o700 if info.name == 'sessions' else 0o750 if info.name == 'secrets' else 0o755) if file.is_dir() else (0o440 if info.name.startswith('secrets/') else 0o755 if info.name.startswith(('bin/', 'readers/')) else 0o644)
            if file.is_file():
                with file.open('rb') as stream:
                    tar.addfile(info, stream)
            else:
                tar.addfile(info)
    return {'package': str(out / 'helper.private.tar.gz'), 'manifest': str(out / 'deploy.private.json')}


def deployment(config):
    import re
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]*',config['namespace']) or not re.fullmatch(r'[a-z0-9][a-z0-9.-]*',config['dbPod']):
        raise ValueError('Invalid game identity')
    env={'DST_MAP_ROOT':'/work/atlas','DST_MAP_NAMESPACE':config['namespace'],'DST_MAP_DB_PORT':str(config.get('dbPort',15432)),
         'DST_MAP_KUBECTL':'/kube-bin/kubectl','DST_ATLAS_PORT':'18446','DST_ATLAS_APP_ROOT':'/work',
         'DST_ATLAS_SNAPSHOT_ROOT':'/work/snapshots','DST_ATLAS_PREFERENCES_ROOT':'/work/settings','DST_ATLAS_ASSET_ROOT':'/work/assets',
         'PATH':'/helper-bin:/usr/local/bin:/usr/bin:/bin','PYTHONUNBUFFERED':'1','HOME':'/tmp'}
    volumes=[('work',BASE+'/current','/work'),('code',BASE+'/current/code','/code'),('bin',BASE+'/current/bin','/helper-bin'),
             ('snapshots',BASE+'/snapshots','/work/snapshots'),('readers',BASE+'/current/readers','/var/lib/dst-atlas/readers'),('kube-bin','/var/lib/rancher/k3s/data/current/bin','/kube-bin')]
    check="import socket;s=socket.create_connection(('127.0.0.1',18446),2);s.close()"
    collector=dict(name='collector',image=IMAGE,imagePullPolicy='IfNotPresent',command=['python','/code/collector.py'],
        env=[dict(name=k,value=v) for k,v in env.items()],resources=dict(requests=dict(cpu='50m',memory='64Mi'),limits=dict(cpu='1000m',memory='250M')),
        securityContext=dict(runAsUser=0,readOnlyRootFilesystem=True,allowPrivilegeEscalation=False,capabilities=dict(drop=['ALL'],add=['SYS_PTRACE','DAC_READ_SEARCH']),seccompProfile=dict(type='RuntimeDefault')),
        volumeMounts=[dict(name=n,mountPath=target,readOnly=n not in ('work','snapshots')) for n,_,target in volumes]+[
            dict(name='reader-api',mountPath='/var/run/secrets/kubernetes.io/serviceaccount',readOnly=True),dict(name='tmp',mountPath='/tmp')],
        readinessProbe=dict(exec={'command':['python','-c',check]},initialDelaySeconds=3,periodSeconds=5,timeoutSeconds=3),
        livenessProbe=dict(exec={'command':['python','-c',check]},initialDelaySeconds=30,periodSeconds=20,timeoutSeconds=3,failureThreshold=5))
    items=[dict(apiVersion='v1',kind='Namespace',metadata=dict(name=NAMESPACE)),
        dict(apiVersion='v1',kind='ServiceAccount',metadata=dict(name='map-helper',namespace=NAMESPACE)),
        dict(apiVersion='rbac.authorization.k8s.io/v1',kind='Role',metadata=dict(name='dst-map-reader',namespace=config['namespace']),rules=[
            dict(apiGroups=[''],resources=['pods'],verbs=['get','list']),dict(apiGroups=[''],resources=['pods/exec'],verbs=['create'],resourceNames=[config['dbPod']])]),
        dict(apiVersion='rbac.authorization.k8s.io/v1',kind='RoleBinding',metadata=dict(name='dst-map-reader',namespace=config['namespace']),
            roleRef=dict(apiGroup='rbac.authorization.k8s.io',kind='Role',name='dst-map-reader'),subjects=[dict(kind='ServiceAccount',name='map-helper',namespace=NAMESPACE)]),
        dict(apiVersion='apps/v1',kind='Deployment',metadata=dict(name='map-helper',namespace=NAMESPACE),spec=dict(replicas=1,strategy=dict(type='Recreate'),
            selector=dict(matchLabels={'app':'dst-map-helper'}),template=dict(metadata=dict(labels={'app':'dst-map-helper'}),spec=dict(
                hostPID=True,hostNetwork=True,dnsPolicy='ClusterFirstWithHostNet',serviceAccountName='map-helper',automountServiceAccountToken=False,
                terminationGracePeriodSeconds=20,containers=[collector],volumes=[dict(name=n,hostPath=dict(path=host,type='Directory')) for n,host,_ in volumes]+[
                    dict(name='tmp',emptyDir=dict(sizeLimit='16Mi')),dict(name='reader-api',projected=dict(sources=[dict(serviceAccountToken=dict(path='token',expirationSeconds=3600)),
                    dict(configMap=dict(name='kube-root-ca.crt',items=[dict(key='ca.crt',path='ca.crt')])),dict(downwardAPI=dict(items=[dict(path='namespace',fieldRef=dict(apiVersion='v1',fieldPath='metadata.namespace'))]))]))]))))]
    return dict(apiVersion='v1',kind='List',items=items)
