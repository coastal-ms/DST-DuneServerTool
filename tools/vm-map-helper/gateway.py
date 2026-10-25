"""Isolated TLS map gateway preserving the existing remote map permission boundary."""
import http.client
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import ssl
import threading
import urllib.parse

from access import allowed, verify

SECRET = Path(os.environ['DST_MAP_SECRETS'])
ROOT = Path(os.environ['DST_MAP_ROOT'])
SLOTS = threading.BoundedSemaphore(16)


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, body=b'', mime='application/json', cookie=None):
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        if cookie:
            self.send_header('Set-Cookie', cookie)
        self.end_headers()
        self.wfile.write(body)

    def claims(self):
        token = self.headers.get('Authorization', '')
        if token.startswith('Bearer '):
            token = token[7:]
        else:
            cookies = SimpleCookie(self.headers.get('Cookie', ''))
            token = cookies['dst_vm_map'].value if 'dst_vm_map' in cookies else ''
        return verify(token, (SECRET / 'grant.key').read_bytes(),
                      json.loads((SECRET / 'acl.json').read_text()))

    def do_GET(self):
        self.dispatch('GET')

    def do_POST(self):
        self.dispatch('POST')

    def dispatch(self, method):
        if not SLOTS.acquire(blocking=False):
            return self.reply(503)
        try:
            self.request.settimeout(20)
            url = urllib.parse.urlsplit(self.path)
            if len(self.path) > 2048 or self.headers.get('Transfer-Encoding'):
                return self.reply(400)
            if method == 'GET' and url.path == '/launch':
                # Grant stays in the fragment until exchanged for an HttpOnly cookie.
                html = b'''<!doctype html><meta name="referrer" content="no-referrer"><title>DST map prototype</title><p id="s">Opening map...</p><script>(async()=>{const token=location.hash.slice(1);history.replaceState(null,'','/launch');const r=await fetch('/session',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token})});if(r.ok)location.replace('/api/v1/maps/atlas/view');else document.querySelector('#s').textContent='Map access expired or denied.'})()</script>'''
                return self.reply(200, html, 'text/html; charset=utf-8')
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 <= length <= 40960:
                return self.reply(413)
            if method == 'POST':
                if self.headers.get('Origin') != 'https://' + self.headers.get('Host', ''):
                    return self.reply(403)
                if self.headers.get('Content-Type', '').split(';')[0] != 'application/json':
                    return self.reply(415)
            body = self.rfile.read(length) if length else b''
            if method == 'POST' and url.path == '/session':
                token = json.loads(body)['token']
                verify(token, (SECRET / 'grant.key').read_bytes(),
                       json.loads((SECRET / 'acl.json').read_text()))
                return self.reply(200, b'{"ok":true}', cookie='dst_vm_map=' + token +
                                  '; Path=/; Max-Age=600; Secure; HttpOnly; SameSite=Strict')
            claims = self.claims()
            if url.path == '/api/v1/maps/atlas/view' and method == 'GET':
                path = '/'
            elif url.path == '/api/v1/maps/atlas/resource':
                values = urllib.parse.parse_qs(url.query)
                if set(values) != {'path'} or len(values['path']) != 1:
                    return self.reply(400)
                path = values['path'][0]
            else:
                return self.reply(404)
            if not allowed(claims, method, path):
                return self.reply(403)
            self.proxy(method, path, body, claims)
        except (ValueError, KeyError, TypeError, json.JSONDecodeError):
            self.reply(401, b'{"error":"Map access expired or denied"}')
        except (OSError, http.client.HTTPException):
            try:
                self.reply(503, b'{"error":"Map collector unavailable"}')
            except OSError:
                pass
        finally:
            SLOTS.release()

    def proxy(self, method, path, body, claims):
        ready = json.loads((ROOT / 'ready.json').read_text())
        target = urllib.parse.urlsplit(ready['url'])
        headers = {'Host': target.netloc, 'Accept-Encoding': self.headers.get('Accept-Encoding', ''),
                   'X-DST-Atlas-Timing': 'local' if claims.get('localOwner') else 'remote'}
        viewer = self.headers.get('X-DST-Atlas-Viewer', '')
        if re.fullmatch(r'[A-Za-z0-9_-]{16,80}', viewer):
            headers['X-DST-Atlas-Viewer'] = viewer
        if self.headers.get('If-None-Match'):
            headers['If-None-Match'] = self.headers['If-None-Match']
        if method == 'POST':
            headers['Content-Type'] = 'application/json'
        conn = http.client.HTTPConnection('127.0.0.1', target.port, timeout=15)
        try:
            conn.request(method, path + '?' + target.query,
                         body=body if method == 'POST' else None, headers=headers)
            response = conn.getresponse()
            data = response.read()
            self.send_response(response.status)
            for name in ('Content-Type', 'Content-Encoding', 'ETag', 'Vary'):
                if response.getheader(name):
                    self.send_header(name, response.getheader(name))
            static = path.startswith('/icons/')
            self.send_header('Cache-Control', 'private, max-age=3600' if static else 'no-store')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(data)
        finally:
            conn.close()

    def log_message(self, *args):
        pass  # Never log cookies, grants or private request URLs.


if __name__ == '__main__':
    server = ThreadingHTTPServer((os.environ.get('DST_MAP_BIND', '127.0.0.1'),
                                  int(os.environ.get('DST_MAP_PORT', '18443'))), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(SECRET / 'cert.pem', SECRET / 'key.pem')
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()
