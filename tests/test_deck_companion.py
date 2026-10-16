"""Portable companion checks. Filesystem/locking tests run on Linux (SteamOS).

Run: python -m unittest discover -s tests -p test_deck_companion.py -v
"""
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('deck_builder', ROOT / 'scripts/build-deck-companion.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


def companion_namespace():
    script = builder.build()
    source = script.split("<<'DST_DECK_COMPANION_PYTHON'\n", 1)[1].rsplit('\nDST_DECK_COMPANION_PYTHON\n', 1)[0]
    namespace = {'__name__': 'test_companion'}
    exec(compile(source, 'companion.py', 'exec'), namespace)
    return script, namespace


def reader_namespace():
    _, companion = companion_namespace()
    namespace = {'__name__': 'test_reader'}
    exec(compile(companion['reader_source'](), 'reader.py', 'exec'), namespace)
    return namespace


class BuildTests(unittest.TestCase):
    def test_generic_reproducible_artifact_and_complete_positive_schema(self):
        script, namespace = companion_namespace()
        self.assertEqual(script, builder.build())
        reader = namespace['reader_source']().decode()
        self.assertNotIn('__READER_B64__', script)
        self.assertNotIn('__BRIDGE__', reader)
        self.assertNotIn('__PAIR_TOKEN__', reader)
        self.assertNotIn(str(ROOT), script)
        # Constants in the unpaired source cannot contain an IP or Steam account.
        self.assertNotRegex(reader + script, r'192\.168\.\d+\.\d+|7656119\d{10}')
        if sys.platform == 'linux':
            loaded = reader_namespace()
            native = loaded['WRITE_SCHEMA']['ServerCustomSettings.ini']['/Script/DuneSandbox.UserServerCustomSettings']
            self.assertNotIn('DifficultyLevel', native)
            self.assertNotIn('PVPMode', native)
            self.assertIn('bAllowSandworms', native)
            self.assertEqual(set(native), set(builder.settings_schema()['ServerCustomSettings.ini']['/Script/DuneSandbox.UserServerCustomSettings']) - {'DifficultyLevel', 'PVPMode'})

    def test_schema_does_not_depend_on_working_directory(self):
        original = Path.cwd()
        with tempfile.TemporaryDirectory() as temporary:
            try:
                __import__('os').chdir(temporary)
                self.assertIn('Engine.ini', builder.settings_schema())
                self.assertTrue(builder.build().startswith('#!/bin/sh\n'))
            finally:
                __import__('os').chdir(original)

    def test_expired_pairing_code_can_be_replaced_in_the_same_companion(self):
        import urllib.error
        from unittest.mock import Mock
        _, companion = companion_namespace()
        opener = Mock()
        opener.open.side_effect = [urllib.error.HTTPError('https://fixture/ssh-info', 403, 'expired', {}, None), io.BytesIO(b'{"public_key":"fixture"}')]
        prompts = []
        answers = iter([(0, 'old-code'), (0, ''), (0, ' new-code ')])

        def dialog(*args):
            prompts.append(args)
            return next(answers)

        with patch.dict(companion, {'dialog': dialog}):
            code, info = companion['get_pairing_info'](opener, 'https://fixture')
        self.assertEqual(code, 'NEW-CODE')
        self.assertEqual(info['public_key'], 'fixture')
        self.assertIn('Refresh pairing code', prompts[1][1])
        self.assertEqual(opener.open.call_args[0][0].get_header('Authorization'), 'Bearer NEW-CODE')

    def test_rejected_pairing_code_can_be_cancelled_without_setup(self):
        import urllib.error
        from unittest.mock import Mock
        _, companion = companion_namespace()
        opener = Mock()
        opener.open.side_effect = urllib.error.HTTPError('https://fixture/ssh-info', 403, 'expired', {}, None)
        answers = iter([(0, 'old-code'), (1, '')])
        with patch.dict(companion, {'dialog': lambda *args: next(answers)}):
            self.assertIsNone(companion['get_pairing_info'](opener, 'https://fixture'))
        self.assertEqual(opener.open.call_count, 1)

    def test_installer_payload_matches_the_current_sources(self):
        self.assertEqual((builder.SOURCES / 'DST-Deck-Companion.sh').read_text(encoding='utf-8'), builder.build())


@unittest.skipUnless(sys.platform == 'linux', 'SteamOS filesystem and fcntl locking')
class ReaderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.reader = reader_namespace()

    def fixture(self, root):
        saved = root / 'different library/pfx/Saved'
        config = saved / 'Config/Windows'
        config.mkdir(parents=True)
        schema = self.reader['WRITE_SCHEMA']
        originals, files = {}, []
        for name, sections in schema.items():
            section = next(iter(sections))
            key = sections[section][0]
            raw = b'\xef\xbb\xbf; original\r\n[Unrelated]\r\nKeepMe=yes\r\n'
            (config / name).write_bytes(raw)
            originals[name] = raw
            files.append({'file': name, 'expected_sha256': self.reader['digest'](raw),
                          'values': [{'section': section, 'key': key, 'value': '1'}]})
        request = {'action': 'apply-settings', 'files': files, 'confirmed': True, 'cloud_confirmed': True}
        report = {'settings_candidates': [{'saved_root': str(saved)}], 'errors': [], 'game_processes': []}
        return config, request, report, originals

    def test_multi_file_apply_preserves_unrelated_bytes_and_exact_backups(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config, request, report, originals = self.fixture(root)
            result = self.reader['handle_batch'](request, lambda: report, root / 'backups')
            self.assertTrue(result['applied'])
            self.assertEqual(len(result['files']), 3)
            for file in request['files']:
                raw = (config / file['file']).read_bytes()
                self.assertTrue(raw.startswith(originals[file['file']]))
                self.assertEqual((Path(result['backup']) / file['file']).read_bytes(), originals[file['file']])
                self.assertIn((file['values'][0]['key'] + '=1\r\n').encode(), raw)

    def test_second_file_failure_restores_originals(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config, request, report, originals = self.fixture(root)
            calls = []

            def fail_second(path, raw):
                calls.append(path)
                if len(calls) == 2:
                    raise OSError('simulated replacement failure')
                self.reader['atomic_settings_file'](path, raw)

            with self.assertRaisesRegex(RuntimeError, 'original settings restored'):
                self.reader['handle_batch'](request, lambda: report, root / 'backups', fail_second)
            for name, raw in originals.items():
                self.assertEqual((config / name).read_bytes(), raw)

    def test_stale_unapproved_live_or_injected_requests_never_write(self):
        for variant in ('key', 'path', 'value', 'hash', 'confirmation', 'cloud', 'running'):
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                config, request, report, originals = self.fixture(root)
                if variant == 'key':
                    request['files'][0]['values'][0]['key'] = 'Unknown.CVar'
                elif variant == 'path':
                    request['files'][0]['file'] = '../game.db'
                elif variant == 'value':
                    request['files'][0]['values'][0]['value'] = '0\nOther=1'
                elif variant == 'hash':
                    request['files'][-1]['expected_sha256'] = 'stale'
                elif variant == 'confirmation':
                    request['confirmed'] = False
                elif variant == 'cloud':
                    request['cloud_confirmed'] = False
                else:
                    report['game_processes'] = [{'pid': 123}]
                with self.assertRaises(ValueError):
                    self.reader['handle_batch'](request, lambda: report, root / 'backups')
                self.assertFalse((root / 'backups').exists())
                for name, raw in originals.items():
                    self.assertEqual((config / name).read_bytes(), raw)

    def test_traversal_in_mod_archive_rejected(self):
        for name in ('../escape', '/etc/escape', 'runtime/../../escape', 'Mods/Test:escape', 'runtime\\escape'):
            raw = io.BytesIO()
            with zipfile.ZipFile(raw, 'w') as archive:
                archive.writestr(name, 'invalid')
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.reader['validate_mod_archive'](raw.getvalue())

    def test_mod_launch_keeps_retail_install_and_nonsteam_shortcut_identity(self):
        reader = self.reader
        payload = {
            'runtime/dwmapi.dll': b'fixture loader',
            'runtime/ue4ss/UE4SS.dll': b'fixture runtime',
            'runtime/ue4ss/UE4SS-settings.ini': b'[Overrides]\nModsFolderPath = Mods\nControllingModsTxt = mods.txt\n',
            'Mods/Fixture/Scripts/main.lua': b'-- fixture only',
        }
        manifest = {'protocol': 1, 'enabled': ['Fixture'], 'runtimeVersion': 'fixture',
                    'launchOptions': ['-nobattleye'], 'files': {name: reader['digest'](raw) for name, raw in payload.items()}}
        bundle = io.BytesIO()
        with zipfile.ZipFile(bundle, 'w') as archive:
            for name, raw in payload.items():
                archive.writestr(name, raw)
            archive.writestr('manifest.json', json.dumps(manifest))
        with tempfile.TemporaryDirectory() as temporary, patch.object(Path, 'home', return_value=Path(temporary)), patch.dict(reader['os'].environ, {'SteamGameId': '9876543210987654321', 'SteamOverlayGameId': '9876543210987654321'}):
            home = Path(temporary)
            steam = home / '.local/share/Steam'
            common = steam / 'steamapps/common'
            game = common / 'Different Dune Folder'
            binary = game / 'DuneSandbox/Binaries/Win64'
            binary.mkdir(parents=True)
            (binary / 'DuneSandbox-Win64-Shipping.exe').write_bytes(b'original game fixture')
            (game / 'Engine').mkdir()
            (game / 'Engine/content.bin').write_bytes(b'original content')
            tool = common / 'Proton Fixture'
            tool.mkdir()
            (tool / 'proton').write_text('# fixture')
            (tool / 'toolmanifest.vdf').write_text('"require_tool_appid" "1628350"')
            runtime = common / 'SteamLinuxRuntime_sniper'
            runtime.mkdir()
            (runtime / '_v2-entry-point').write_text('# fixture')
            (steam / 'steamapps/appmanifest_1628350.acf').write_text('"installdir" "SteamLinuxRuntime_sniper"')
            prefix = steam / 'steamapps/compatdata/1172710/pfx'
            prefix.mkdir(parents=True)
            (prefix.parent / 'config_info').write_text(str(tool))
            report = {'libraries': [str(steam)], 'installations': [{'path': str(game), 'exists': True}],
                      'prefixes': [str(prefix)], 'game_processes': []}
            originals = {str(path.relative_to(game)): path.read_bytes() for path in game.rglob('*') if path.is_file()}
            root = home / '.local/share/dst-deck-companion'
            result = reader['install_mod_bundle'](bundle.getvalue(), report, root)
            state = json.loads((root / 'mods-current.json').read_text())
            command, env, session, cwd = reader['prepare_mod_launch'](report, state, root)
            self.assertEqual(env['STEAM_COMPAT_DATA_PATH'], str(prefix.parent))
            self.assertEqual(env['SteamAppId'], '1172710')
            self.assertEqual(env['SteamGameId'], '9876543210987654321')
            self.assertEqual(env['SteamOverlayGameId'], '9876543210987654321')
            self.assertEqual(env['PROTON_LOG'], '0')
            self.assertIn('-nobattleye', command)
            self.assertIn(str(runtime / '_v2-entry-point'), command)
            self.assertTrue((cwd / 'dwmapi.dll').is_file())
            self.assertFalse((binary / 'dwmapi.dll').exists())
            self.assertEqual({str(path.relative_to(game)): path.read_bytes() for path in game.rglob('*') if path.is_file()}, originals)
            self.assertTrue(Path(result['launcher']).stat().st_mode & 0o111)
            reader['install_mod_bundle'](bundle.getvalue(), report, root)
            self.assertTrue(Path(state['root']).is_dir())
            current = json.loads((root / 'mods-current.json').read_text())
            self.assertNotEqual(current['root'], state['root'])
            self.assertEqual(current['previous']['root'], state['root'])

    def test_companion_update_preserves_pairing_and_other_ssh_keys(self):
        _, companion = companion_namespace()
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            folder = home / '.local/share/dst-deck-companion'
            folder.mkdir(parents=True)
            prior = b'def discover(): pass\ndef reader_dispatch(): pass\n'
            fresh = prior + b'# fixture update\n'
            (folder / 'reader.py').write_bytes(prior)
            pairing = b'{"pc":"192.0.2.10","port":18748}'
            (folder / 'pairing.json').write_bytes(pairing)
            (home / '.ssh').mkdir()
            (home / '.ssh/authorized_keys').write_bytes(b'preserve existing access\n')
            with patch.dict(companion, {'reader_source': lambda: fresh}):
                self.assertTrue(companion['update_paired_reader'](home))
                self.assertFalse(companion['update_paired_reader'](home))
            self.assertEqual((folder / 'pairing.json').read_bytes(), pairing)
            self.assertEqual((home / '.ssh/authorized_keys').read_bytes(), b'preserve existing access\n')
            self.assertEqual(next(folder.glob('reader-before-update-*.py')).read_bytes(), prior)

    def test_private_connection_uses_only_owned_files_and_a_password_free_user_service(self):
        import base64
        import os
        import subprocess
        _, companion = companion_namespace()
        key = 'ssh-ed25519 ' + base64.b64encode(b'\0\0\0\x0bssh-ed25519\0\0\0\x20' + os.urandom(32)).decode()
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            (home / '.ssh').mkdir()
            shared = home / '.ssh/authorized_keys'
            shared.write_bytes(b'preserve existing SSH access\n')
            commands = []

            def run(command):
                commands.append(command)
                if '-f' in command and '-N' in command:
                    Path(command[-1]).write_bytes(b'fixture private host key')
                return subprocess.CompletedProcess(command, 0, stdout=key if '-y' in command else '', stderr='')

            with patch.dict(companion, {'private_tools': lambda: ('/usr/bin/sshd', '/usr/bin/ssh-keygen'),
                                        'private_run': run, 'wait_private_connection': lambda port: None}):
                folder, connection = companion['install_private_connection'](home, key, b'# fixture reader', '192.0.2.10')
                companion['stop_private_connection'](home)
            self.assertEqual(shared.read_bytes(), b'preserve existing SSH access\n')
            self.assertGreaterEqual(connection['ssh_port'], 1024)
            self.assertEqual((folder / 'reader.py').read_bytes(), b'# fixture reader')
            config = (folder / 'private-ssh/sshd_config').read_text()
            self.assertIn('PasswordAuthentication no', config)
            self.assertIn('UsePAM no', config)
            self.assertIn('DisableForwarding yes', config)
            self.assertIn('ForceCommand /usr/bin/python3', config)
            self.assertIn('from="192.0.2.10",restrict', (folder / 'private-ssh/authorized_keys').read_text())
            self.assertTrue((home / '.config/systemd/user/dst-deck-companion-ssh.service').is_file())
            self.assertTrue(all(command[:2] == ['systemctl', '--user'] for command in commands if command[0] == 'systemctl'))
            self.assertFalse(any(command[0] in {'sudo', 'passwd', 'useradd'} for command in commands))
            self.assertEqual(commands[-1], ['systemctl', '--user', 'disable', '--now', 'dst-deck-companion-ssh.service'])

    def test_private_connection_preserves_a_foreign_user_service(self):
        import base64
        import os
        _, companion = companion_namespace()
        key = 'ssh-ed25519 ' + base64.b64encode(b'\0\0\0\x0bssh-ed25519\0\0\0\x20' + os.urandom(32)).decode()
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            unit = home / '.config/systemd/user/dst-deck-companion-ssh.service'
            unit.parent.mkdir(parents=True)
            unit.write_bytes(b'unrelated service\n')
            with patch.dict(companion, {'private_tools': lambda: ('/usr/bin/sshd', '/usr/bin/ssh-keygen')}):
                with self.assertRaisesRegex(ValueError, 'unrelated service'):
                    companion['install_private_connection'](home, key, b'# fixture reader', '192.0.2.10')
            self.assertEqual(unit.read_bytes(), b'unrelated service\n')

    def test_pairing_refreshes_only_its_own_restricted_key_when_pc_address_or_comment_changes(self):
        import base64
        import os
        _, companion = companion_namespace()
        key = 'ssh-ed25519 ' + base64.b64encode(b'\0\0\0\x0bssh-ed25519\0\0\0\x20' + os.urandom(32)).decode()
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            (home / '.ssh').mkdir()
            authorized = home / '.ssh/authorized_keys'
            unrelated = b'# unrelated access is retained\n'
            authorized.write_bytes(unrelated)
            companion['install_reader'](home,key+' old-comment',b'# fixture reader','192.0.2.10')
            before=authorized.read_bytes()
            companion['install_reader'](home,key,b'# fixture reader','192.0.2.11')
            after=authorized.read_bytes()
            self.assertTrue(after.startswith(unrelated))
            self.assertIn(b'from="192.0.2.11",restrict,command=',after)
            self.assertNotIn(b'192.0.2.10',after)
            self.assertEqual(after.count(key.encode()),1)
            self.assertTrue(any(p.read_bytes()==before for p in (home/'.ssh').glob('authorized_keys.before-dst-*')))
            companion['install_reader'](home,key,b'# fixture reader','192.0.2.11')
            self.assertEqual(authorized.read_bytes(),after)

    def test_pairing_never_replaces_unrestricted_existing_access_for_the_same_key(self):
        import base64
        import os
        _, companion=companion_namespace()
        key='ssh-ed25519 '+base64.b64encode(b'\0\0\0\x0bssh-ed25519\0\0\0\x20'+os.urandom(32)).decode()
        with tempfile.TemporaryDirectory() as temporary:
            home=Path(temporary)
            (home/'.ssh').mkdir()
            authorized=home/'.ssh/authorized_keys'
            original=(key+' unrestricted\n').encode()
            authorized.write_bytes(original)
            with self.assertRaisesRegex(ValueError,'different authorization'):
                companion['install_reader'](home,key,b'# fixture','192.0.2.10')
            self.assertEqual(authorized.read_bytes(),original)


if __name__ == '__main__':
    unittest.main()
