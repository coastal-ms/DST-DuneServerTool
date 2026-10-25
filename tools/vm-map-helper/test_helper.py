import base64
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

from access import allowed, issue, verify
import local_pwsh


class AccessTests(unittest.TestCase):
    def setUp(self):
        self.key = os.urandom(32)
        self.account = dict(id='test', role='admin', enabled=True, mustChangePassword=False)
        self.acl = dict(validUntil=time.time() + 1000, accounts=[self.account])

    def claims(self, **changes):
        self.account.update(changes)
        return verify(issue(self.key, self.account), self.key, self.acl)

    def test_real_role_matrix_and_remote_control_boundary(self):
        for role in ('owner', 'admin', 'player'):
            claims = self.claims(role=role)
            for path in ('/', '/state', '/pois', '/gathering', '/gathering/HaggaBasin',
                         '/marker-icons', '/icons/hagga-background-v1.webp', '/bases/12.svg'):
                self.assertTrue(allowed(claims, 'GET', path), (role, path))
            for path in ('/preferences', '/viewer', '/live/start'):
                self.assertEqual(allowed(claims, 'POST', path), role != 'player')
            for path in ('/live/stop', '/refresh'):
                self.assertFalse(allowed(claims, 'POST', path))
        owner = verify(issue(self.key, dict(self.account, role='owner'), local_owner=True),
                       self.key, dict(self.acl, accounts=[dict(self.account, role='owner')]))
        self.assertTrue(allowed(owner, 'POST', '/live/stop'))

    def test_expiration_wrong_signature_audience_and_revocation(self):
        token = issue(self.key, self.account)
        with self.assertRaises(ValueError):
            verify(token, os.urandom(32), self.acl)
        with self.assertRaises(ValueError):
            verify(token, self.key, self.acl, now=time.time() + 601)
        with self.assertRaises(ValueError):
            verify(token, self.key, dict(self.acl, validUntil=0))
        self.account['enabled'] = False
        with self.assertRaises(ValueError):
            verify(token, self.key, self.acl)
        self.account['enabled'] = True
        self.account['role'] = 'player'
        with self.assertRaises(ValueError):
            verify(token, self.key, self.acl)

    def test_forced_password_change_and_unknown_account(self):
        with self.assertRaises(ValueError):
            issue(self.key, dict(self.account, mustChangePassword=True))
        token = issue(self.key, self.account)
        with self.assertRaises(ValueError):
            verify(token, self.key, dict(self.acl, accounts=[]))

    def test_non_map_routes_and_traversal_denied(self):
        claims = self.claims()
        for path in ('/api/commands', '/api/db/query', '/icons/../access.json',
                     '/icons/%2e%2e/access.json', '/access.json'):
            self.assertFalse(allowed(claims, 'GET', path))
        self.assertFalse(allowed(claims, 'POST', '/api/commands'))
        self.assertFalse(allowed(claims, 'DELETE', '/state'))


class TransportTests(unittest.TestCase):
    def test_query_is_explicitly_read_only_and_never_returns_stderr(self):
        with tempfile.TemporaryDirectory() as folder:
            query = Path(folder) / 'collect.sql'
            query.write_text('SELECT 1;')
            output = Path(folder) / 'result.json'
            result = type('Result', (), dict(returncode=0, stdout='{"readOnly":"on"}\n', stderr='secret'))()
            with patch.dict(os.environ, DST_MAP_NAMESPACE='test'), \
                 patch.object(local_pwsh.subprocess, 'check_output', return_value='pod/test-db-dbdepl-sts-0\n'), \
                 patch.object(local_pwsh.subprocess, 'run', return_value=result) as run:
                self.assertEqual(local_pwsh.main(['-File', 'query.ps1', '-SqlFile', str(query),
                                                 '-OutputFile', str(output)]), 0)
            self.assertIn('BEGIN READ ONLY;', run.call_args.kwargs['input'])
            self.assertIn('ROLLBACK;', run.call_args.kwargs['input'])
            self.assertNotIn('secret', output.read_text())
            self.assertEqual(json.loads(output.read_text())['rowCount'], 1)


if __name__ == '__main__':
    unittest.main()
