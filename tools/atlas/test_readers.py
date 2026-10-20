"""Reader restoration and process-restart recovery regression checks."""
from pathlib import Path
import importlib.util
import json
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2] / 'app/tools/DuneAtlas'
sys.path.insert(0, str(ROOT))
import atlas_readers as readers
import atlas_runtime as runtime


class ReaderTests(unittest.TestCase):
    def setUp(self):
        readers._checked = 0

    def test_bundled_readers_match_reviewed_hashes(self):
        self.assertEqual(set(readers.payloads(ROOT)), {'scan', 'bulk'})

    def test_corrupt_bundle_is_rejected_before_remote_install(self):
        with tempfile.TemporaryDirectory() as folder:
            Path(folder, 'reader-scan.b64').write_text('AAAA')
            calls = []
            with self.assertRaises(ValueError):
                readers.ensure(folder, lambda root, script: calls.append(script) or False)
            self.assertEqual(len(calls), 1)

    def test_missing_readers_install_and_verify_then_reuse_check(self):
        calls = []
        answers = iter([False, True, True])
        def remote(root, script):
            calls.append(script)
            return next(answers)
        readers.ensure(ROOT, remote)
        readers.ensure(ROOT, remote)
        self.assertEqual(len(calls), 3)
        self.assertIn('mktemp -d', calls[1])
        self.assertIn('sha256sum -c', calls[1])
        self.assertNotIn('/proc/', calls[1])
        self.assertNotIn('kill ', calls[1])

    def test_failed_install_does_not_mark_ready(self):
        with self.assertRaises(RuntimeError):
            readers.ensure(ROOT, lambda root, script: False)
        self.assertEqual(readers._checked, 0)

    def test_native_restart_rediscovers_and_rejects_old_process(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(readers, 'ensure'):
            root = Path(folder)
            (root / 'runtime-context.json').write_text(json.dumps({'pid': 22, 'startTime': 'new'}))
            (root / 'native-snapshot-current.json').write_text(json.dumps({'pid': 22, 'startTime': 'new'}))
            calls = []
            budgets = []
            def run(root, name, timeout):
                calls.append(name)
                budgets.append(timeout)
                return len(calls) != 1
            self.assertEqual(runtime.collect_native(root, run)['pid'], 22)
            self.assertEqual(calls, ['snapshot-native.py', 'discover-runtime.py', 'snapshot-native.py'])
            self.assertEqual(budgets, [120, 300, 120])
            (root / 'native-snapshot-current.json').write_text(json.dumps({'pid': 21, 'startTime': 'old'}))
            with self.assertRaisesRegex(RuntimeError, 'another process'):
                runtime.collect_native(root, lambda *args: True)

    def test_hagga_uses_shared_reader_with_separate_runtime_directory(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(runtime.atlas_process, 'run') as run:
            root=Path(folder);hag = root/'hagga';hag.mkdir()
            (root/'snapshot-native.py').write_text('pass')
            run.return_value.returncode=0
            self.assertTrue(runtime.execute(hag,'snapshot-native.py',120))
            args,kwargs=run.call_args
            self.assertEqual(Path(args[0][1]),root/'snapshot-native.py')
            self.assertEqual(kwargs['env']['DST_ATLAS_WORLD_ROOT'],str(hag.resolve()))
            self.assertEqual(kwargs['cwd'],hag)

    def test_fast_reader_rejects_same_pid_from_previous_process_start(self):
        spec=importlib.util.spec_from_file_location('worm_identity_test',ROOT/'worm-fast.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            (root/'runtime-context.json').write_text(json.dumps({'pid':22,'startTime':'new'}))
            with self.assertRaisesRegex(ValueError,'matching runtime'):
                module.WormReader(root).read({'pid':22,'startTime':'old'})


if __name__ == '__main__':
    unittest.main()
