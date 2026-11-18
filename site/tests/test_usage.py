"""Exercise the actual PHP collector against a temporary private SQLite DB."""
import concurrent.futures
from contextlib import closing
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request
import uuid


class UsageCollectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='dst-usage-test-')
        cls.data = Path(cls.temp.name) / 'private'
        cls.public = Path(__file__).resolve().parents[1] / 'public'
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
        cls.url = f'http://127.0.0.1:{port}/api/usage.php'
        php = shutil.which('php')
        if not php: raise RuntimeError('PHP 8.1+ with pdo_sqlite is required for collector tests')
        cls.log = (Path(cls.temp.name) / 'php.log').open('w')
        cls.server = subprocess.Popen([php, '-S', f'127.0.0.1:{port}', '-t', str(cls.public)],
            env={**os.environ, 'DST_USAGE_DATA_DIR': str(cls.data)}, stdout=cls.log, stderr=subprocess.STDOUT)
        for _ in range(50):
            try:
                code, _ = cls.request();
                if code == 200: break
            except OSError: pass
            time.sleep(.1)
        else:
            cls.server.terminate(); cls.server.wait(); cls.log.close()
            raise RuntimeError('PHP collector did not become ready')

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate(); cls.server.wait(timeout=5); cls.log.close(); cls.temp.cleanup()

    def setUp(self):
        with closing(sqlite3.connect(str(self.data / 'presence.sqlite'))) as db, db: db.execute('DELETE FROM presence')
        self.identity = str(uuid.uuid4()); self.token = secrets.token_hex(32)
        self.refresh_snapshot()

    @classmethod
    def request(cls, method='GET', body=None, token=None):
        headers = {'Content-Type': 'application/json'}
        if token: headers['Authorization'] = 'Bearer ' + token
        request = urllib.request.Request(cls.url, data=json.dumps(body).encode() if body is not None else None,
                                         headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=5) as reply: return reply.status, json.load(reply)
        except urllib.error.HTTPError as error: return error.code, json.load(error)

    def refresh_snapshot(self):
        raw = subprocess.check_output([shutil.which('php'), str(self.public / 'api/usage.php'), '--refresh'],
            env={**os.environ, 'DST_USAGE_DATA_DIR': str(self.data)}, timeout=5)
        return json.loads(raw.decode())

    def snapshot(self):
        self.refresh_snapshot()
        return self.request()[1]

    def report(self, edition='windows', **changes):
        return self.request('POST', {'id': self.identity, 'edition': edition, 'version': '1.0.7', **changes}, self.token)

    def test_counts_editions_once_per_installation(self):
        self.assertEqual(self.report()[0], 200)
        self.assertEqual(self.report(version='16.7.10')[0], 200)
        self.assertEqual(self.request('POST', {'id': str(uuid.uuid4()), 'edition': 'docker', 'version': '1.0.7'}, secrets.token_hex(32))[0], 200)
        snapshot = self.snapshot()
        self.assertEqual((snapshot['total'],snapshot['windows'],snapshot['docker']), (2,1,1))
        self.assertEqual(snapshot['refreshHours'], 1)

    def test_opt_out_removes_only_the_authenticated_installation(self):
        self.report()
        self.assertEqual(self.request('DELETE', {'id': self.identity}, secrets.token_hex(32))[0], 403)
        self.assertEqual(self.snapshot()['total'], 1)
        self.assertEqual(self.request('DELETE', {'id': self.identity}, self.token)[1], {'accepted': True})
        self.assertEqual(self.snapshot()['total'], 0)
        self.assertEqual(self.request('DELETE', {'id': self.identity}, self.token)[0], 200)

    def test_confirmed_installations_remain_counted_after_24_hours(self):
        self.report()
        with closing(sqlite3.connect(str(self.data / 'presence.sqlite'))) as db, db: db.execute('UPDATE presence SET seen_at=?', (int(time.time())-86401,))
        legacy_snapshot = {'protocol': 1, 'windowHours': 24, 'refreshHours': 6,
                           'updatedAt': int(time.time()), 'total': 0, 'windows': 0, 'docker': 0}
        (self.data / 'snapshot.json').write_text(json.dumps(legacy_snapshot), encoding='utf-8')
        self.assertEqual(self.request()[1]['windows'], 1)
        self.assertEqual(self.request('POST', {'id': str(uuid.uuid4()), 'edition': 'docker', 'version': '1.0.7'}, secrets.token_hex(32))[0], 200)
        self.assertEqual(self.snapshot()['total'], 2)
        with closing(sqlite3.connect(str(self.data / 'presence.sqlite'))) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM presence').fetchone()[0], 2)

    def test_unknown_or_private_fields_are_rejected(self):
        for key in ['serverName', 'ip', 'players', 'config', 'account', 'logs']:
            self.assertEqual(self.report(**{key: 'never-store'})[0], 400)
        self.assertEqual(self.snapshot()['total'], 0)
        self.assertEqual(self.report(id='../private')[0], 400)
        self.assertEqual(self.report(edition='other')[0], 400)
        self.assertEqual(self.report(version='C:/private/file')[0], 400)

    def test_requires_the_generated_reporting_credential(self):
        self.assertEqual(self.request('POST', {'id': self.identity, 'edition': 'windows', 'version': '16.7.9'})[0], 401)
        self.report()
        self.assertEqual(self.request('POST', {'id': self.identity, 'edition': 'docker', 'version': '1.0.7'}, secrets.token_hex(32))[0], 403)
        self.assertEqual(self.snapshot()['windows'], 1)

    def test_database_contains_only_hashed_credentials_and_allowed_presence_fields(self):
        self.report()
        with closing(sqlite3.connect(str(self.data / 'presence.sqlite'))) as db:
            row = db.execute('SELECT * FROM presence').fetchone()
            columns = [r[1] for r in db.execute('PRAGMA table_info(presence)')]
        self.assertEqual(columns, ['id_hash', 'token_hash', 'edition', 'version', 'seen_at'])
        self.assertNotIn(self.identity, str(row)); self.assertNotIn(self.token, str(row))
        if os.name != 'nt':
            self.assertEqual((self.data / 'presence.sqlite').stat().st_mode & 0o777, 0o600)
            self.assertEqual(self.data.stat().st_mode & 0o777, 0o700)

    def test_repeated_requests_do_not_inflate_the_public_total(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
            results = list(pool.map(lambda _: self.report(), range(12)))
        self.assertTrue(all(code == 200 for code, _ in results))
        self.assertEqual(self.snapshot()['total'], 1)

    def test_response_is_uncached_and_public_read_exposes_no_installation_records(self):
        self.report(); self.refresh_snapshot()
        with urllib.request.urlopen(self.url, timeout=5) as reply:
            self.assertEqual(reply.headers['Cache-Control'], 'no-store')
            value = json.load(reply)
        self.assertEqual(set(value), {'protocol','basis','refreshHours','updatedAt','total','windows','docker'})
        self.assertNotIn(self.identity, json.dumps(value)); self.assertNotIn(self.token, json.dumps(value))

    def test_rejects_unsupported_methods_and_oversized_reports(self):
        self.assertEqual(self.request('PUT', {'id':self.identity}, self.token)[0], 405)
        self.assertEqual(self.report(version='x'*2000)[0], 413)
        self.assertEqual(self.snapshot()['total'], 0)

    def test_public_requests_cannot_force_a_refresh_but_cli_can(self):
        before = self.request()[1]
        self.report()
        with urllib.request.urlopen(self.url + '?force=1&refresh=1', timeout=5) as reply:
            self.assertEqual(json.load(reply), before)
        self.assertEqual(self.refresh_snapshot()['total'], 1)
        self.assertEqual(self.request()[1]['total'], 1)

    def test_public_snapshot_updates_automatically_after_one_hour(self):
        before = self.request()[1]
        self.report()
        self.assertEqual(self.request()[1], before)
        path = self.data / 'snapshot.json'
        old = {**before, 'updatedAt': int(time.time()) - 3590}
        path.write_text(json.dumps(old))
        self.assertEqual(self.request()[1], old)
        old['updatedAt'] = int(time.time()) - 3600
        path.write_text(json.dumps(old))
        self.assertEqual(self.request()[1]['total'], 1)

    def test_public_snapshot_refreshes_when_the_configured_interval_changes(self):
        before = self.request()[1]
        self.report()
        path = self.data / 'snapshot.json'
        path.write_text(json.dumps({**before, 'refreshHours': 6}))
        snapshot = self.request()[1]
        self.assertEqual((snapshot['refreshHours'], snapshot['total']), (1, 1))


if __name__ == '__main__': unittest.main(verbosity=2)
