"""Installer/backend entry point. Private configuration is passed only on stdin."""
import hashlib
import ipaddress
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time

# Embedded Windows Python uses an isolated ._pth, which omits the script's
# directory. Keep this entry point usable with DST's bundled runtime as well.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from package import BASE, IMAGE, NAMESPACE, prepare


def ssh(config, command, data=None, timeout=120):
    ipaddress.ip_address(config['vmIp'])
    result = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                             '-o', 'ConnectTimeout=5', '-i', config['sshKey'], 'dune@' + config['vmIp'], command],
                            input=data, capture_output=True, timeout=timeout)
    if result.returncode:
        # Do not echo SSH payloads, account exports or private URLs.
        raise RuntimeError('VM map operation failed: ' + result.stderr.decode(errors='replace')[-800:])
    return result.stdout.decode(errors='replace')


def install(config):
    paths = prepare(config)
    archive = Path(paths['package'])
    revision = hashlib.sha256(archive.read_bytes()).hexdigest()[:20]
    release = BASE + '/releases/' + revision
    # All privileged paths are fixed or a hexadecimal digest. Preserve the old
    # release and shared sessions/accounts for rollback and updates.
    script = f'''set -eu
test "$(uname -m)" = x86_64
for p in /var /var/lib {BASE}; do
  test ! -L "$p"
  if test ! -d "$p"; then sudo mkdir -m 755 "$p"; fi
  test "$(stat -c %u "$p")" = 0
  test -z "$(find "$p" -maxdepth 0 -perm /022 -print)"
done
sudo mkdir -p {BASE}/releases
test ! -e {release}
sudo mkdir -m 755 {release}
sudo tar -xzf - -C {release}
'''
    ssh(config, script, archive.read_bytes())
    old = ssh(config, 'readlink ' + BASE + '/current || true').strip()
    previous_manifest = ssh(config, 'sudo cat ' + BASE + '/installed.json 2>/dev/null || true')
    if old and not re.fullmatch(re.escape(BASE) + r'/releases/[0-9a-f]{20}', old):
        raise ValueError('Unexpected existing helper release')
    activate = f'''set -eu
sudo mkdir -p {BASE}/auth {BASE}/state {BASE}/snapshots
if test ! -f {BASE}/snapshots/storm-history-v1.json && test -f {BASE}/current/snapshots/storm-history-v1.json; then
  sudo cp {BASE}/current/snapshots/storm-history-v1.json {BASE}/snapshots/storm-history-v1.json
fi
sudo chown 0:65532 {BASE}/auth
sudo chmod 750 {BASE}/auth
sudo chown 65532:65532 {BASE}/state
sudo chmod 700 {BASE}/state
sudo cp -a {release}/secrets/. {BASE}/auth/
sudo chown -R 0:65532 {BASE}/auth
sudo find {BASE}/auth -type f -exec chmod 440 {{}} +
if test -d {BASE}/current/settings; then sudo cp -a {BASE}/current/settings/. {release}/settings/; fi
for region in atlas atlas/hagga; do
  if test -d {BASE}/current/$region; then
    for file in {BASE}/current/$region/*.json; do
      name=$(basename "$file")
      case "$name" in
        runtime-context.json|*-cache.json|native-*-current.json|native-static-marker-sites.json|gathering-*.json|native-gathering*.json|poi-discovery*.json|server-profile-*.json|storm-cycle-anchor.json|storm-route-observations.json)
          if test -f "$file"; then sudo cp "$file" {release}/$region/; fi ;;
      esac
    done
  fi
done
sudo ln -sfn {release} {BASE}/current.next
sudo mv -Tf {BASE}/current.next {BASE}/current
'''
    ssh(config, 'sudo k3s crictl pull ' + IMAGE + ' >/dev/null', timeout=180)
    manifest = Path(paths['manifest']).read_bytes()
    try:
        ssh(config, activate)
        ssh(config, 'sudo k3s kubectl apply -f -', manifest)
        ssh(config, 'sudo k3s kubectl rollout restart deployment/map-helper -n ' + NAMESPACE)
        ssh(config, 'sudo k3s kubectl rollout status deployment/map-helper -n ' + NAMESPACE + ' --timeout=90s', timeout=100)
        ssh(config, "sudo sh -c 'umask 077; cat > " + BASE + "/installed.json'", manifest)
    except Exception:
        if old:
            ssh(config, 'sudo ln -sfn ' + old + ' ' + BASE + '/current.next; sudo mv -Tf ' + BASE + '/current.next ' + BASE + '/current; sudo k3s kubectl rollout restart deployment/map-helper -n ' + NAMESPACE)
            if previous_manifest:
                ssh(config, 'sudo k3s kubectl apply -f -', previous_manifest.encode())
        raise
    return {'ok': True, 'revision': revision, 'url': '/api/v1/maps/atlas/view'}


def relay(config):
    return json.loads(ssh(config, 'sudo cat ' + BASE + '/current/atlas/ready.json'))


def retire_public(config):
    status = json.loads(ssh(config, 'if command -v tailscale >/dev/null && sudo rc-service tailscale status >/dev/null 2>&1; then sudo tailscale funnel status --json; else echo "{}"; fi'))
    own = any(site.get('Handlers') == {'/': {'Proxy': 'http://127.0.0.1:18445'}} for site in status.get('Web', {}).values())
    if own:
        ssh(config, 'sudo tailscale funnel --https=443 off >/dev/null')
        remaining = json.loads(ssh(config, 'sudo tailscale funnel status --json'))
        if not remaining.get('Web') and not remaining.get('TCP'):
            ssh(config, 'sudo rc-service tailscale stop >/dev/null; sudo rc-update del tailscale default >/dev/null')
    return {'ok': True}


def control(config):
    # Host-only management keeps local collection controls out of the public
    # browser login, including when that browser belongs to an owner.
    value = config['control']
    if value.get('action') not in ('start', 'stop', 'refresh', 'preferences', 'status'):
        raise ValueError('Invalid collection control')
    code = """import json,sys,urllib.request,urllib.error
from pathlib import Path
v=json.load(sys.stdin)
ready=json.loads(Path('/work/atlas/ready.json').read_text())
def status():
 with urllib.request.urlopen(ready['url'].replace('/?key=','/collection-status?key='),timeout=5) as r:current=json.load(r)
 return {'ok':True,**current}
if v['action']=='status':
 print(json.dumps(status()));sys.exit(0)
paths={'start':'/live/start','stop':'/live/stop','refresh':'/refresh','preferences':'/preferences'}
p=paths[v['action']]
url=ready['url'].replace('/?key=',p+'?key=')
payload=v.get('preferences',{}) if v['action']=='preferences' else {}
if v['action']=='preferences':
 with urllib.request.urlopen(ready['url'].replace('/?key=','/preferences?key='),timeout=5) as r:existing=json.load(r)
 if not existing:raise ValueError('Open the map before changing its refresh interval')
 payload={**existing,**payload}
request=urllib.request.Request(url,data=json.dumps(payload).encode(),headers={'Content-Type':'application/json','X-DST-Atlas-Timing':'local'},method='POST')
try:
 with urllib.request.urlopen(request,timeout=20) as r:r.read()
except urllib.error.HTTPError as e:
 message='Stop live and wait for current collection to finish before refreshing a snapshot.' if e.code==409 else 'The map service could not accept the request. Please retry.'
 print(json.dumps({'ok':False,'error':message}));sys.exit(0)
print(json.dumps(status()))
"""
    try:
        result = json.loads(ssh(config, 'sudo k3s kubectl exec -i -n ' + NAMESPACE +
                          ' deployment/map-helper -c collector -- python -c ' + shlex.quote(code),
                          json.dumps(value).encode(), timeout=25))
    except (RuntimeError, ValueError, subprocess.TimeoutExpired):
        raise RuntimeError('Could not contact the VM map service. Check the VM connection and retry.') from None
    if not result.get('ok'):
        raise RuntimeError(result.get('error', 'The map operation could not be completed. Please retry.'))
    return result


def remove(config):
    status = json.loads(ssh(config, 'if command -v tailscale >/dev/null && sudo rc-service tailscale status >/dev/null 2>&1; then sudo tailscale funnel status --json; else echo "{}"; fi'))
    for authority, site in status.get('Web', {}).items():
        if authority.endswith(':443') and site.get('Handlers') == {'/': {'Proxy': 'http://127.0.0.1:18445'}}:
            ssh(config, 'sudo tailscale funnel --https=443 off >/dev/null')
    ssh(config, 'sudo k3s kubectl delete deployment/map-helper -n ' + NAMESPACE + ' --ignore-not-found=true --wait=true')
    ssh(config, 'sudo rm -f ' + ' '.join(BASE + '/state/' + n for n in
        ('sessions.sqlite', 'sessions.sqlite-wal', 'sessions.sqlite-shm', 'sessions.sqlite-journal')))
    # Revoke the collector's API authority as well as stopping its process.
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]*', config['namespace']):
        raise ValueError('Invalid game namespace')
    ssh(config, 'sudo k3s kubectl delete role/dst-map-reader rolebinding/dst-map-reader -n ' + config['namespace'] + ' --ignore-not-found=true')
    # Preserve account/session state, prior releases and map preferences. This
    # endpoint can be reinstalled without deleting user data or game resources.
    return {'ok': True, 'dataPreserved': True}


if __name__ == '__main__':
    try:
        config = json.load(sys.stdin)
        commands = {'install': install, 'remove': remove, 'relay': relay,
                    'retire-public': retire_public, 'control': control}
        print(json.dumps(commands[sys.argv[1]](config)))
    except Exception as exc:
        print(json.dumps({'ok': False, 'error': str(exc)}))
        sys.exit(1)
