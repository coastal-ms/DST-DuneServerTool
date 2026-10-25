"""Short-lived delegated map access; no copied account passwords or admin API."""
import base64
import hashlib
import hmac
import json
import time


def encode(value):
    return base64.urlsafe_b64encode(value).rstrip(b'=').decode()


def issue(key, account, lifetime=600, local_owner=False):
    if not account.get('enabled') or account.get('mustChangePassword'):
        raise ValueError('Account cannot open a map session')
    if account.get('role') not in ('owner', 'admin', 'player'):
        raise ValueError('Unknown account role')
    now = int(time.time())
    body = encode(json.dumps({'aud': 'dst-vm-map-prototype', 'sub': account['id'],
                              'role': account['role'], 'iat': now, 'exp': now + min(lifetime, 600),
                              'localOwner': bool(local_owner and account['role'] == 'owner')},
                             separators=(',', ':')).encode())
    return body + '.' + encode(hmac.digest(key, body.encode(), 'sha256'))


def verify(token, key, acl, now=None):
    now = time.time() if now is None else now
    if not isinstance(token, str) or len(token) > 4096:
        raise ValueError('Invalid grant')
    body, signature = token.split('.')
    if not hmac.compare_digest(signature, encode(hmac.digest(key, body.encode(), 'sha256'))):
        raise ValueError('Invalid grant')
    claims = json.loads(base64.urlsafe_b64decode(body + '=' * (-len(body) % 4)))
    if claims.get('aud') != 'dst-vm-map-prototype' or not claims.get('iat', 0) <= now < claims.get('exp', 0):
        raise ValueError('Expired or invalid grant')
    if claims['exp'] - claims['iat'] > 600 or now >= acl.get('validUntil', 0):
        raise ValueError('Access export expired')
    account = next((a for a in acl.get('accounts', []) if a['id'] == claims.get('sub')), None)
    if not account or not account.get('enabled') or account.get('mustChangePassword'):
        raise ValueError('Account disabled or password change required')
    if account.get('role') != claims.get('role') or account['role'] not in ('owner', 'admin', 'player'):
        raise ValueError('Account role changed')
    if claims.get('localOwner') and claims['role'] != 'owner':
        raise ValueError('Local controls require the owner')
    return claims


def allowed(claims, method, path):
    # Existing HttpServer.ps1 permits player GET maps; session/start writes need owner/admin.
    if method == 'GET':
        return path in ('/', '/state', '/preferences', '/marker-icons', '/pois',
                        '/gathering', '/gathering/HaggaBasin') or (
            path.startswith(('/icons/', '/bases/')) and '..' not in path and '%' not in path)
    if method != 'POST':
        return False
    if claims['role'] == 'player':
        return False
    if path in ('/preferences', '/viewer', '/live/start'):
        return True
    return bool(claims.get('localOwner') and path in ('/live/stop', '/refresh'))
