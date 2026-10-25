import contextlib
import io
import json
import shlex
import sys
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch
import manage


class ControlTests(unittest.TestCase):
    def remote(self, config, command, data, timeout):
        code = shlex.split(command)[-1]
        output = io.StringIO()
        with patch.object(Path, 'read_text', return_value=json.dumps({'url':'http://127.0.0.1:18446/?key=test'})), \
             patch.object(sys, 'stdin', io.StringIO(data.decode())), contextlib.redirect_stdout(output):
            try:
                exec(compile(code, '<remote-control>', 'exec'), {})
            except SystemExit as result:
                self.assertEqual(result.code, 0)
        return output.getvalue()

    def test_conflict_is_plain_guidance_instead_of_a_remote_traceback(self):
        conflict = urllib.error.HTTPError('private', 409, 'conflict', {}, None)
        with patch.object(manage, 'ssh', side_effect=self.remote), patch('urllib.request.urlopen', side_effect=conflict):
            with self.assertRaisesRegex(RuntimeError, '^Stop live and wait for current collection to finish before refreshing a snapshot.$'):
                manage.control({'control':{'action':'refresh'}})

    def test_status_uses_the_service_without_registering_a_viewer(self):
        value = {'live':False,'refreshing':True,'stopping':False,'activity':['native'],'refreshSeconds':3}
        with patch.object(manage, 'ssh', side_effect=self.remote), patch('urllib.request.urlopen', return_value=io.BytesIO(json.dumps(value).encode())) as request:
            self.assertEqual(manage.control({'control':{'action':'status'}}), {'ok':True,**value})
            self.assertIn('/collection-status?', request.call_args.args[0])

    def test_transport_failure_does_not_expose_remote_paths(self):
        with patch.object(manage, 'ssh', side_effect=RuntimeError('private traceback /usr/local/lib/python')):
            with self.assertRaisesRegex(RuntimeError, '^Could not contact the VM map service. Check the VM connection and retry.$'):
                manage.control({'control':{'action':'stop'}})


if __name__ == '__main__':
    unittest.main()
