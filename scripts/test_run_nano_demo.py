#!/usr/bin/env python3
"""Launcher safety/unit checks. No compiler, visible window, account or network."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location('nano_demo', Path(__file__).with_name('run-nano-demo.py'))
demo = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(demo)


class DemoTests(unittest.TestCase):
    def setUp(self):
        demo.DEMO_ROOT.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='unit-{}-'.format(time.time_ns()), dir=str(demo.DEMO_ROOT))
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        for directory in ('home', 'data', 'tmp', 'bin'):
            (self.base / directory).mkdir()
        self.env = demo.runtime_env(self.base, 49123)

    def test_environment_is_allowlisted_not_inherited(self):
        with mock.patch.dict(os.environ, {'GH_TOKEN': 'synthetic-secret', 'HARNESS_DATA_DIR': '/not-demo',
                                          'HARNESS_MOCK_ERROR': '1', 'SSH_AUTH_SOCK': '/not-demo'}):
            env = demo.runtime_env(self.base, 49123)
        for key in ('GH_TOKEN', 'SSH_AUTH_SOCK', 'HARNESS_MOCK_ERROR', 'DYLD_INSERT_LIBRARIES'):
            self.assertNotIn(key, env)
        self.assertEqual(env['HOME'], str(self.base / 'home'))
        self.assertEqual(env['HARNESS_DATA_DIR'], str(self.base / 'data'))
        self.assertEqual(env['HARNESS_IPC_PORT'], '49123')
        self.assertEqual(env['HARNESS_NANO_OPEN_CHAT'], demo.CHAT)
        self.assertEqual(env['HARNESS_NANO_PANELS'], 'git-history')
        self.assertEqual(env['HARNESS_NO_LOGIN_SHELL'], '1')
        self.assertEqual(env['HARNESS_EDGE_URL'], 'http://127.0.0.1:9')
        self.assertNotIn(os.environ.get('HOME', '/not-used') + '/.cargo/bin', env['PATH'])

    def test_snapshot_path_cannot_escape_session(self):
        for name in ('../oops.png', '/tmp/oops.png', 'nested/../../oops.png', 'not-a-png.jpg', ''):
            with self.subTest(name=name), self.assertRaises(ValueError):
                demo.snapshot_path(self.base, name)
        self.assertEqual(demo.snapshot_path(self.base, 'checks/history.png'),
                         self.base / 'snapshots/checks/history.png')

    def test_real_git_fixture_has_history_changes_and_no_remote(self):
        project = demo.create_repository(self.base, self.env)
        git = lambda *args: demo.run(['git', *args], cwd=project, env=self.env)
        self.assertEqual(git('rev-list', '--count', 'HEAD'), '56')
        self.assertEqual(git('rev-list', '--count', 'main..HEAD'), '4')
        self.assertEqual(git('branch', '--show-current'), 'demo/native-history')
        self.assertEqual(git('log', '-1', '--format=%s'), 'demo: polish native history rail')
        self.assertEqual(git('log', '-1', '--format=%an <%ae>'), 'Demo Developer <demo@example.invalid>')
        self.assertEqual(git('remote'), '')
        self.assertEqual(git('status', '--porcelain=v1'),
                         ' M README.md\nM  src/palette.json\n?? docs/next-steps.md')
        before = demo.repository_state(project, self.env)
        git('log', '-56', '--format=%h %s')
        git('diff', '--stat')
        self.assertEqual(demo.repository_state(project, self.env), before)
        self.assertIn('iris', before['stagedDiff'])
        self.assertIn('Changes button', before['diff'])

    def test_sandbox_has_loopback_only_and_no_shell_or_gh(self):
        profile = demo.sandbox_profile([self.base / 'engine', self.base / 'nano', Path('/usr/bin/git')])
        self.assertIn('(deny network*)', profile)
        self.assertIn('(deny process-exec)', profile)
        self.assertEqual(profile.count('localhost:*'), 2)
        self.assertNotIn('/bin/sh', profile)
        self.assertNotIn('/usr/bin/gh', profile)
        self.assertNotIn('remote ip "*', profile)
        if sys.platform == 'darwin':
            file = self.base / 'check.sb'
            file.write_text(profile)
            denied = subprocess.run(demo.sandbox_command(file, '/bin/sh', '-c', 'exit 0'),
                                    env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertNotEqual(denied.returncode, 0, 'Runtime sandbox must refuse shell execution')

    def test_bundle_cleans_launchservices_environment_and_does_not_open(self):
        nano = self.base / 'fake-nano'
        nano.write_bytes(b'synthetic binary placeholder')
        profile = self.base / 'demo.sb'
        with mock.patch.object(demo, 'run') as run:
            app, binary = demo.stage_bundle(self.base, nano, self.env, profile)
        self.assertEqual(app.name, 'Harness Nano Demo.app')
        self.assertEqual(binary.read_bytes(), nano.read_bytes())
        with (app / 'Contents/Info.plist').open('rb') as file:
            plist = demo.plistlib.load(file)
        self.assertEqual(plist['CFBundleIdentifier'], 'com.codegraff.harness.nano-demo')
        wrapper = (app / 'Contents/MacOS/nano-demo-launcher').read_text()
        self.assertIn('/usr/bin/env -i', wrapper)
        self.assertIn('HARNESS_NANO_PANELS=git-history', wrapper)
        self.assertIn('/usr/bin/sandbox-exec', wrapper)
        self.assertIn('preview.pid', wrapper)
        run.assert_called_once()
        self.assertEqual(run.call_args.args[0][0], '/usr/bin/codesign')

    def test_builds_use_heavy_build_and_session_local_outputs(self):
        with mock.patch.object(demo, 'seed_zig_packages'):
            with mock.patch.object(demo.subprocess, 'run', return_value=mock.Mock(returncode=0)) as run:
                engine, nano = demo.build_binaries(self.base)
        self.assertTrue(str(engine).startswith(str(self.base / 'build')))
        self.assertTrue(str(nano).startswith(str(self.base / 'build')))
        self.assertEqual(run.call_count, 2)
        for call in run.call_args_list:
            self.assertEqual(call.args[0][0], '/usr/bin/sandbox-exec')
            self.assertEqual(call.args[0][3], str(demo.ROOT / 'scripts/heavy-build.sh'))
            self.assertEqual(call.kwargs['env']['CARGO_TARGET_DIR'], str(self.base / 'build/target'))
        self.assertIn('-Doptimize=ReleaseSafe', run.call_args_list[1].args[0])
        self.assertIn('--global-cache-dir', run.call_args_list[1].args[0])
        self.assertIn('--offline', run.call_args_list[0].args[0])
        self.assertIn('(deny network*)', (self.base / 'build/offline.sb').read_text())

    def test_zig_dependency_cache_is_copied_without_touching_shared_sources(self):
        cache = self.base / 'existing-cache'
        (cache / 'p' / 'synthetic-package').mkdir(parents=True)
        source = cache / 'p/synthetic-package/build.zig'
        source.write_text('// synthetic dependency')
        build = self.base / 'build'
        build.mkdir()
        for index, text in enumerate((json.dumps({'global_cache_dir': str(cache)}),
                                      '.{\n.global_cache_dir = ' + json.dumps(str(cache)) + ',\n}')):
            output = build / str(index)
            output.mkdir()
            with mock.patch.object(demo, 'run', return_value=text):
                demo.seed_zig_packages(output, self.env)
            copied = output / 'zig-global-cache/p/synthetic-package/build.zig'
            self.assertEqual(copied.read_text(), source.read_text())
            self.assertNotEqual(copied.stat().st_ino, source.stat().st_ino)

    def test_stop_never_signals_a_reused_or_unexpected_pid(self):
        identity = {'pid': 12345, 'started': 'synthetic-start', 'command': '/owned/nano'}
        with mock.patch.object(demo, 'process_identity', return_value=dict(identity, started='different')):
            with mock.patch.object(demo.os, 'kill') as kill:
                self.assertFalse(demo.stop_owned(identity, '/owned/nano'))
                kill.assert_not_called()
        with mock.patch.object(demo.os, 'kill') as kill:
            self.assertFalse(demo.stop_owned(identity, '/user/Harness'))
            self.assertFalse(demo.stop_owned(None, '/owned/nano'))
            kill.assert_not_called()

    def test_stop_signals_only_verified_owned_process(self):
        identity = {'pid': 12345, 'started': 'synthetic-start', 'command': '/owned/nano'}
        with mock.patch.object(demo, 'process_identity', side_effect=[identity, None]):
            with mock.patch.object(demo.os, 'kill') as kill:
                self.assertTrue(demo.stop_owned(identity, '/owned/nano'))
        kill.assert_called_once_with(12345, signal.SIGTERM)

    def test_stop_rejects_unowned_session(self):
        with self.assertRaises(ValueError):
            demo.resolve_session(str(demo.ROOT))
        demo.write_json(self.base / 'session.json', {'owner': 'not-ours', 'directory': str(self.base)})
        with self.assertRaises(ValueError):
            demo.resolve_session(str(self.base))
        demo.write_json(self.base / 'session.json', {'owner': demo.MARKER, 'directory': str(self.base)})
        base, state = demo.resolve_session(str(self.base))
        self.assertEqual(base, self.base)
        self.assertEqual(state['owner'], demo.MARKER)

    def test_invalid_process_ids_are_never_inspected(self):
        with mock.patch.object(demo.subprocess, 'run') as run:
            for pid in (-1, 0, 1, True, '123'):
                self.assertIsNone(demo.process_identity(pid))
            run.assert_not_called()

    def test_node_bootstrap_syntax_without_execution(self):
        node = shutil.which('node')
        if not node:
            self.skipTest('Node not installed')
        file = self.base / 'bootstrap.mjs'
        file.write_text(demo.BOOTSTRAP)
        demo.run([node, '--check', file], cwd=self.base, env=self.env)


if __name__ == '__main__':
    unittest.main()
