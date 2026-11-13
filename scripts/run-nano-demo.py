#!/usr/bin/env python3
"""A disposable native source-control demo; Python 3.9+, macOS, no packages."""
import argparse
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
DEMO_ROOT = ROOT / '.graff' / 'nano-demo'
MARKER = 'harness-nano-synthetic-demo-v1'
CHAT = 'nano-demo-chat'
PROJECT = 'nano-demo-project'

# Node is only the local WebSocket bootstrap. No npm, remote calls or engine hooks.
BOOTSTRAP = r'''
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
const [port, project, report] = process.argv.slice(2);
const chat = 'nano-demo-chat';
const space = 'nano-demo-project';
let ws;
const deadline = Date.now() + 30000;
for (;;) {
  ws = new WebSocket(`ws://127.0.0.1:${port}`);
  const opened = await new Promise(resolve => {
    ws.addEventListener('open', () => resolve(true), {once: true});
    ws.addEventListener('error', () => resolve(false), {once: true});
  });
  if (opened) break;
  ws.close();
  assert(Date.now() < deadline, 'Demo engine did not accept local IPC');
  await new Promise(resolve => setTimeout(resolve, 100));
}
let next = 1;
const calls = new Map();
ws.addEventListener('message', e => {
  const frame = JSON.parse(String(e.data));
  calls.get(frame.id)?.(frame);
});
function call(method, params = {}, stream = false, accept = () => true) {
  const id = next++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      calls.delete(id);
      reject(new Error(`Local demo RPC timed out: ${method}`));
    }, 20000);
    calls.set(id, frame => {
      if ('err' in frame) {
        clearTimeout(timer); calls.delete(id);
        reject(new Error(`Local demo RPC failed: ${method}`));
        return;
      }
      const key = stream ? 'item' : 'ok';
      if (!(key in frame) || !accept(frame[key])) return;
      clearTimeout(timer); calls.delete(id);
      if (stream) ws.send(JSON.stringify({id, cancel: true}));
      resolve(frame[key]);
    });
    ws.send(JSON.stringify({id, method, params}));
  });
}
const rows = v => Array.isArray(v) ? v : v?.items ?? v?.devices ?? [];
try {
  const devices = rows(await call('WatchDevices', {}, true, v => rows(v).length > 0));
  assert.equal(devices.length, 1, 'Demo must have only its isolated device');
  await call('Mutate', {op: 'createSpace', spaceId: space, deviceId: devices[0].id,
    path: project, name: 'Synthetic Studio', gitDetected: true});
  await call('Mutate', {op: 'createChat', chatId: chat, spaceId: space,
    config: {harness: 'mock', model: 'mock-1', reasoning: 'medium',
      sandbox: 'read-only', modelOptions: {}}});
  const prompts = [
    'SYNTHETIC DEMO — Walk through this made-up native Git history. All assistant replies and tool cards are scripted mock events, not executed commands.',
    'SYNTHETIC DEMO — Keep a longer example transcript so we can try scrolling alongside the Git history panel. Nothing here connects to an account.',
    'SYNTHETIC DEMO — Ready to explore. Git history and Changes use real local synthetic files. Session pull requests are empty: there is no GitHub remote or authentication. No live PR integration is being demonstrated.'
  ];
  let completed = 0;
  for (const [index, prompt] of prompts.entries()) {
    await call('QueueCommand', {chatId: chat, command: {kind: 'run',
      messageId: `nano-demo-prompt-${index}`, request: {prompt, turnOrigin: 'human',
        harness: 'mock', model: 'mock-1', cwd: project, sandbox: 'read-only',
        modelOptions: {}, autoApprove: false}}});
    const end = Date.now() + 30000;
    for (;;) {
      const snapshot = await call('WatchDocMessages', {chatId: chat, reset: true}, true,
        v => Array.isArray(v.reset));
      completed = snapshot.reset.filter(e => e.role === 'assistant' && e.status === 'complete').length;
      if (completed >= index + 1) break;
      assert(Date.now() < end, 'Synthetic mock conversation did not finish');
      await new Promise(resolve => setTimeout(resolve, 100));
    }
  }
  await call('Mutate', {op: 'renameChat', chatId: chat, title: 'Synthetic demo · Git history + scrolling'});
  const first = await call('ListGitHistory', {cwd: project, cursor: 0, limit: 50});
  assert.equal(first.commits.length, 50);
  assert.equal(first.commits[0].subject, 'demo: polish native history rail');
  assert.notEqual(first.nextCursor, null);
  const second = await call('ListGitHistory', {cwd: project, cursor: first.nextCursor, limit: 50});
  assert.equal(second.commits.length, 6);
  await fs.writeFile(report, JSON.stringify({synthetic: true, project: 'Synthetic Studio',
    chatId: chat, completedMockTurns: completed, historyPages: [50, 6],
    pullRequests: 'Empty: no remote, no authentication; no live GitHub integration'}, null, 2) + '\n');
} finally { ws.close(); }
'''


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')


def run(args, *, cwd, env, timeout=90):
    result = subprocess.run([str(a) for a in args], cwd=str(cwd), env=env,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout)
    if result.returncode:
        # Do not echo incidental environment/path information from child output.
        raise RuntimeError('{} failed (exit {}); demo launch aborted'.format(
            Path(args[0]).name, result.returncode))
    return result.stdout.decode('utf-8', errors='replace').rstrip('\r\n')


def runtime_env(base, port):
    home = base / 'home'
    return {
        'PATH': str(base / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin',
        'HOME': str(home), 'TMPDIR': str(base / 'tmp') + '/',
        'XDG_CONFIG_HOME': str(home / '.config'),
        'XDG_DATA_HOME': str(home / '.local/share'),
        'XDG_CACHE_HOME': str(home / '.cache'), 'LANG': 'en_US.UTF-8',
        'HARNESS_DATA_DIR': str(base / 'data'), 'HARNESS_IPC_PORT': str(port),
        'HARNESS_DEVICE_NAME': 'Synthetic demo host', 'HARNESS_PROVIDER': 'mock',
        'HARNESS_NANO_HARNESS': 'mock', 'HARNESS_NANO_NO_ENGINE_START': '1',
        'HARNESS_NANO_OPEN_CHAT': CHAT, 'HARNESS_NANO_PANELS': 'git-history',
        'HARNESS_NO_LOGIN_SHELL': '1', 'HARNESS_AUTO_UPDATE': '0',
        'HARNESS_GRAFF_AUTO_UPDATE': '0', 'HARNESS_CODEGRAFF_CLIENT_ID': '',
        'HARNESS_EDGE_URL': 'http://127.0.0.1:9',
        'GRAFF_EXECUTABLE': str(base / 'bin' / 'unused-mock-graff'),
        'HARNESS_MOCK_REPEAT': '4', 'HARNESS_MOCK_CODE': '1',
        'HARNESS_MOCK_TABLE': '1', 'HARNESS_MOCK_DELAY_MS': '0',
        'GIT_CEILING_DIRECTORIES': str(base), 'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': str(home / '.gitconfig'),
        'GIT_TERMINAL_PROMPT': '0', 'GIT_PAGER': '', 'PAGER': '',
        'RUST_LOG': 'warn',
    }


def snapshot_path(base, requested):
    """Snapshot names are relative to this fresh session, never arbitrary writes."""
    name = Path(requested)
    if name.is_absolute() or '..' in name.parts or not name.parts:
        raise ValueError('--snapshot must be a relative path within the new demo session')
    # Keep captures out of the state, repository and bundle directories.
    path = base / 'snapshots' / name
    if path.suffix.lower() != '.png':
        raise ValueError('--snapshot requires a .png filename')
    return path


def create_repository(base, env):
    project = base / 'synthetic-project'
    project.mkdir()
    (project / 'src').mkdir()
    (project / 'docs').mkdir()
    (base / 'empty-hooks').mkdir()
    git = lambda *args: run(['git', *args], cwd=project, env=env)
    git('init', '-b', 'main')
    git('config', 'user.name', 'Demo Developer')
    git('config', 'user.email', 'demo@example.invalid')
    git('config', 'core.hooksPath', str(base / 'empty-hooks'))
    git('config', 'core.fsmonitor', 'false')
    (project / 'README.md').write_text(
        '# Synthetic Studio\n\nA disposable, fictional Nano source-control demo.\n'
        'History and file changes are real local Git data.\n'
        'Mock conversation/tool cards are scripted, never executed.\n'
        'No remotes, accounts, shell actions, or live pull requests.\n', encoding='utf-8')
    (project / 'src' / 'palette.json').write_text(
        '{"accent": "violet", "surface": "midnight"}\n', encoding='utf-8')
    subjects = ['demo: seed synthetic studio'] + [
        'demo: document design checkpoint {:02d}'.format(i) for i in range(2, 53)
    ] + ['demo: add source-control workspace', 'demo: refine timeline spacing',
         'demo: add history pagination', 'demo: polish native history rail']
    head = None
    for index, subject in enumerate(subjects):
        (project / 'docs' / 'design.md').write_text(
            '# Fictional design notes\n\nCheckpoint {} of 56.\n'
            'Browse history, inspect local changes, and try transcript scrolling.\n'.format(index + 1),
            encoding='utf-8')
        git('add', '.')
        tree = git('write-tree')
        date = (datetime(2026, 1, 1, tzinfo=timezone.utc) + timedelta(days=index)).isoformat()
        commit_env = dict(env, GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
        head = run(['git', 'commit-tree', tree, *(['-p', head] if head else []), '-m', subject],
                   cwd=project, env=commit_env)
        if index == 51:
            git('update-ref', 'refs/heads/main', head)
    git('update-ref', 'refs/heads/demo/native-history', head)
    git('symbolic-ref', 'HEAD', 'refs/heads/demo/native-history')
    (project / 'src' / 'palette.json').write_text(
        '{"accent": "iris", "surface": "midnight", "timeline": true}\n', encoding='utf-8')
    git('add', 'src/palette.json')
    with (project / 'README.md').open('a', encoding='utf-8') as file:
        file.write('\nTry the Changes button in the Git history panel.\n')
    (project / 'docs' / 'next-steps.md').write_text(
        '# Synthetic next steps\n\n- Try Previous / Next in history.\n'
        '- Inspect staged and unstaged changes.\n- Scroll the mock conversation.\n'
        '- Open Session pull requests to see the honest empty state.\n', encoding='utf-8')
    return project


def repository_state(project, env):
    return {key: run(['git', *args], cwd=project, env=env) for key, args in (
        ('head', ['rev-parse', 'HEAD']), ('status', ['status', '--porcelain=v1']),
        ('index', ['write-tree']), ('diff', ['diff', '--no-ext-diff']),
        ('stagedDiff', ['diff', '--cached', '--no-ext-diff']))}


def sandbox_profile(executables):
    # The allowlist prevents terminal/shell/provider actions even if clicked.
    # Git is allowed for native read-only history/status; this fixture has no hooks,
    # filters, credentials or remote. No GitHub executable is permitted.
    literals = ' '.join('(literal {})'.format(json.dumps(str(p)))
                        for p in sorted(set(executables), key=str))
    return ('(version 1)\n(allow default)\n(deny network*)\n'
            '(allow network-inbound (local ip "localhost:*"))\n'
            '(allow network-outbound (remote ip "localhost:*"))\n'
            '(deny process-exec)\n(allow process-exec ' + literals + ')\n')


def sandbox_command(profile, executable, *args):
    return ['/usr/bin/sandbox-exec', '-f', str(profile), str(executable), *args]


def seed_zig_packages(build, env):
    """Reuse installed dependency sources without writing into the shared cache."""
    text = run(['zig', 'env'], cwd=ROOT, env=env)
    try:
        cache = json.loads(text)['global_cache_dir']
    except (ValueError, KeyError):
        cache = None
        for line in text.splitlines():
            if line.strip().startswith('.global_cache_dir = '):
                cache = json.loads(line.split('=', 1)[1].strip().rstrip(','))
                break
    if not cache:
        raise RuntimeError('Could not locate Zig dependency cache; build the checkout normally first')
    packages = Path(cache) / 'p'
    if packages.is_dir():
        shutil.copytree(str(packages), str(build / 'zig-global-cache/p'), symlinks=True)


def build_binaries(base):
    build = base / 'build'
    build.mkdir()
    target = build / 'target'
    env = dict(os.environ, CARGO_TARGET_DIR=str(target))
    seed_zig_packages(build, env)
    # Compilation is offline too. Only installed/cached dependencies are used;
    # every compiler child inherits the network restriction.
    profile = build / 'offline.sb'
    profile.write_text('(version 1)\n(allow default)\n(deny network*)\n', encoding='utf-8')
    commands = [
        (ROOT, [ROOT / 'scripts/heavy-build.sh', 'cargo', 'build', '-p', 'harness',
                '--profile', 'app-dev', '--offline', '--target-dir', target]),
        (ROOT / 'apps/nano', [ROOT / 'scripts/heavy-build.sh', 'zig', 'build',
                             '-Doptimize=ReleaseSafe', '--prefix', build / 'nano',
                             '--cache-dir', build / 'zig-cache',
                             '--global-cache-dir', build / 'zig-global-cache']),
    ]
    for index, (cwd, command) in enumerate(commands):
        print('Building {} (serialized by heavy-build.sh)…'.format('engine' if index == 0 else 'Nano'), flush=True)
        with (build / '{}.log'.format(index)).open('wb') as log:
            result = subprocess.run(sandbox_command(profile, command[0], *[str(a) for a in command[1:]]),
                                    cwd=str(cwd), env=env,
                                    stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        if result.returncode:
            raise RuntimeError('Build failed; see this session\'s build/{}.log'.format(index))
    return target / 'app-dev/harness', build / 'nano/bin/harness-nano'


def local_binary(value, default):
    path = Path(value).resolve() if value else default.resolve()
    if ROOT not in path.parents or not path.is_file() or not os.access(str(path), os.X_OK):
        raise ValueError('Demo requires an executable built inside this checkout: ' + str(path))
    return path


def stage_bundle(base, nano, env, profile):
    app = base / 'Harness Nano Demo.app'
    contents = app / 'Contents'
    macos = contents / 'MacOS'
    macos.mkdir(parents=True)
    (contents / 'Resources').mkdir()
    binary = macos / 'harness-nano'
    shutil.copy2(str(nano), str(binary))
    # LaunchServices supplies an uncontrolled environment: env -i is essential.
    command = ['/usr/bin/env', '-i', *['{}={}'.format(k, v) for k, v in sorted(env.items())],
               *sandbox_command(profile, binary)]
    wrapper = macos / 'nano-demo-launcher'
    wrapper.write_text('#!/bin/sh\ncd {} || exit 1\necho $$ > {}\nexec {} >> {} 2>&1\n'.format(
        shlex.quote(str(base / 'synthetic-project')), shlex.quote(str(base / 'preview.pid')),
        ' '.join(shlex.quote(a) for a in command), shlex.quote(str(base / 'preview.log'))), encoding='utf-8')
    wrapper.chmod(0o755)
    with (contents / 'Info.plist').open('wb') as file:
        plistlib.dump({
            'CFBundleIdentifier': 'com.codegraff.harness.nano-demo',
            'CFBundleName': 'Harness Nano Demo', 'CFBundleDisplayName': 'Harness Nano Demo',
            'CFBundleExecutable': wrapper.name, 'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1',
            'LSMinimumSystemVersion': '13.0', 'NSPrincipalClass': 'NSApplication',
            'NSHighResolutionCapable': True,
        }, file)
    run(['/usr/bin/codesign', '--force', '--sign', '-', app], cwd=base, env=env)
    return app, binary


def process_identity(pid):
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 1:
        return None
    def ps(field):
        result = subprocess.run(['/bin/ps', '-ww', '-p', str(pid), '-o', field + '='],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}, timeout=5)
        return result.stdout.decode('utf-8', errors='replace').strip() if result.returncode == 0 else ''
    started, command = ps('lstart'), ps('command')
    return {'pid': pid, 'started': started, 'command': command} if started and command else None


def wait_identity(proc, expected):
    for _ in range(100):
        identity = process_identity(proc.pid)
        if identity and identity['command'] == expected:
            return identity
        if proc.poll() is not None:
            break
        time.sleep(.05)
    raise RuntimeError('Owned demo process exited or did not reach its expected executable')


def stop_owned(identity, expected):
    """Never signal by name, port or process group, nor trust a bare stored PID."""
    if not identity or identity.get('command') != expected:
        return False
    pid = identity.get('pid')
    if process_identity(pid) != identity:
        return False
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return False
    for _ in range(80):
        if process_identity(pid) != identity:
            return True
        time.sleep(.1)
    if process_identity(pid) == identity:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return True


def resolve_session(value):
    if value == 'latest':
        candidates = sorted(p for p in DEMO_ROOT.glob('*')
                            if p.is_dir() and not p.is_symlink() and (p / 'session.json').is_file())
        if not candidates:
            raise ValueError('No demo session exists')
        path = candidates[-1]
    else:
        path = Path(value).resolve()
    if path.parent != DEMO_ROOT.resolve() or path.is_symlink():
        raise ValueError('--stop requires a session directly under this checkout\'s .graff/nano-demo')
    state = json.loads((path / 'session.json').read_text(encoding='utf-8'))
    if state.get('owner') != MARKER or state.get('directory') != str(path):
        raise ValueError('Not an owned Nano demo session')
    return path, state


def stop_session(value):
    base, state = resolve_session(value)
    expected = {'preview': str(base / 'Harness Nano Demo.app/Contents/MacOS/harness-nano'),
                'engine': str(base / 'bin/harness') + ' headless'}
    for role in ('preview', 'engine'):
        stopped = stop_owned(state.get(role), expected[role])
        print('{}: {}'.format(role, 'stopped owned process' if stopped else 'not running or identity differs; not signalled'))
    state['status'] = 'stopped'
    write_json(base / 'session.json', state)


def launch(args):
    if sys.platform != 'darwin':
        raise RuntimeError('The native demo requires macOS (sandbox-exec and Nano Metal rendering)')
    if not Path('/usr/bin/sandbox-exec').is_file():
        raise RuntimeError('sandbox-exec is required; refusing an unsandboxed demo')
    node = shutil.which('node')
    if not node:
        raise RuntimeError('Node with built-in WebSocket is required (Node 22+); no npm packages needed')
    # Validate before creating anything or building.
    if args.snapshot:
        snapshot_path(Path('/unused-session'), args.snapshot)
    DEMO_ROOT.mkdir(parents=True, exist_ok=True)
    base = DEMO_ROOT / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S') + '-{}'.format(time.time_ns()))
    base.mkdir(mode=0o700)
    state = {'owner': MARKER, 'directory': str(base), 'synthetic': True, 'status': 'preparing'}
    write_json(base / 'session.json', state)
    print('Demo session: ' + str(base), flush=True)
    engine = None
    preview = None
    try:
        for directory in ('home', 'data', 'tmp', 'bin'):
            (base / directory).mkdir()
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        env = runtime_env(base, port)
        run([node, '-e', 'if (typeof WebSocket !== "function") process.exit(1)'], cwd=base, env=env)
        if args.no_build:
            target = Path(os.environ.get('CARGO_TARGET_DIR', str(ROOT / 'target')))
            if not target.is_absolute():
                target = ROOT / target
            harness = local_binary(args.engine, target / 'debug/harness')
            nano = local_binary(args.nano, ROOT / 'apps/nano/zig-out/bin/harness-nano')
        else:
            harness, nano = build_binaries(base)
        # Resolve Apple's real Git binary; avoid its developer-tool dispatch shim.
        git = Path(run(['/usr/bin/xcrun', '--find', 'git'], cwd=base, env=env)).resolve()
        (base / 'bin/git').symlink_to(git)
        engine_path = base / 'bin/harness'
        engine_path.symlink_to(harness)
        project = create_repository(base, env)
        before = repository_state(project, env)
        write_json(base / 'repository-before.json', before)
        write_json(base / 'data/nano-ui-settings.json', {
            'appearance': 'dark', 'soundEnabled': False, 'notificationsEnabled': False,
            'sharePerformanceStats': False, 'surface': 'opaque',
        })
        profile = base / 'demo.sb'
        preview_binary = base / 'Harness Nano Demo.app/Contents/MacOS/harness-nano'
        profile.write_text(sandbox_profile([engine_path, harness, preview_binary, git,
                                           base / 'bin/git']), encoding='utf-8')
        app, preview_binary = stage_bundle(base, nano, env, profile)
        state.update(bundle=str(app), port=port, project=str(project), chatId=CHAT)
        with (base / 'engine.log').open('wb') as log:
            engine = subprocess.Popen(sandbox_command(profile, engine_path, 'headless'), cwd=str(project),
                                      env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                      start_new_session=True)
        state['engine'] = wait_identity(engine, str(engine_path) + ' headless')
        state['status'] = 'bootstrapping'
        write_json(base / 'session.json', state)
        bootstrap = base / 'bootstrap.mjs'
        bootstrap.write_text(BOOTSTRAP, encoding='utf-8')
        with (base / 'bootstrap.log').open('wb') as log:
            result = subprocess.run([node, str(bootstrap), str(port), str(project), str(base / 'validation.json')],
                                    cwd=str(project), env=env, stdin=subprocess.DEVNULL,
                                    stdout=log, stderr=log, timeout=120)
        if result.returncode:
            raise RuntimeError('Local RPC bootstrap failed; see this session\'s bootstrap.log')
        if args.snapshot:
            shot = snapshot_path(base, args.snapshot)
            shot.parent.mkdir(parents=True, exist_ok=True)
            with (base / 'preview.log').open('wb') as log:
                preview = subprocess.Popen(sandbox_command(profile, preview_binary, '--nanoui-hidden',
                    '--nanoui-dark', '--nanoui-wait=3', '--nanoui-snapshot=' + str(shot)),
                    cwd=str(project), env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            # Snapshot arguments differ from the visible process; it is reaped here,
            # never controlled by persisted PID or stop-by-name.
            preview.wait(timeout=90)
            if preview.returncode or not shot.is_file() or shot.stat().st_size < 1000:
                raise RuntimeError('Hidden native snapshot failed; see this session\'s preview.log')
            if shot.read_bytes()[:8] != b'\x89PNG\r\n\x1a\n':
                raise RuntimeError('Native snapshot did not produce a PNG')
            after = repository_state(project, env)
            write_json(base / 'repository-after.json', after)
            if before != after:
                raise RuntimeError('Read-only demo validation changed synthetic Git state')
            state.update(status='validated', snapshot=str(shot))
            print('PASS: real engine history (50 + 6), three completed mock turns, hidden native PNG, unchanged Git state.')
            print('Snapshot: ' + str(shot))
        else:
            run(['/usr/bin/open', '-n', app], cwd=project, env=env)
            for _ in range(100):
                pidfile = base / 'preview.pid'
                if pidfile.is_file():
                    identity = process_identity(int(pidfile.read_text().strip()))
                    if identity and identity['command'] == str(preview_binary):
                        state['preview'] = identity
                        break
                time.sleep(.1)
            else:
                raise RuntimeError('Demo bundle did not become ready; see this session\'s preview.log')
            state['status'] = 'running'
            print('Opened Harness Nano Demo — synthetic Git, mock conversation; no live GitHub account.')
            print('Stop only this demo: python3 scripts/run-nano-demo.py --stop ' + shlex.quote(str(base)))
        write_json(base / 'session.json', state)
    except BaseException:
        state['status'] = 'failed'
        if preview is not None and preview.poll() is None:
            preview.terminate()
            try:
                preview.wait(timeout=10)
            except subprocess.TimeoutExpired:
                preview.kill()
                preview.wait()
        # A cancellation can arrive after LaunchServices starts the wrapper but
        # before its identity was stored. Recover only the exact owned binary.
        if not args.snapshot and not state.get('preview') and (base / 'preview.pid').is_file():
            try:
                candidate = process_identity(int((base / 'preview.pid').read_text().strip()))
                if candidate and candidate['command'] == str(preview_binary):
                    state['preview'] = candidate
            except (OSError, ValueError):
                pass
        if state.get('preview'):
            stop_owned(state['preview'], str(base / 'Harness Nano Demo.app/Contents/MacOS/harness-nano'))
        raise
    finally:
        if engine is not None and (args.snapshot or state['status'] != 'running'):
            if engine.poll() is None:
                engine.terminate()
                try:
                    engine.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    engine.kill()
                    engine.wait()
            state['engineStopped'] = True
        write_json(base / 'session.json', state)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--no-build', action='store_true', help='use already-built checkout-local executables')
    parser.add_argument('--engine', help='checkout-local harness executable (requires --no-build)')
    parser.add_argument('--nano', help='checkout-local Nano executable (requires --no-build)')
    parser.add_argument('--snapshot', metavar='PATH', help='hidden validation; save PNG under SESSION/snapshots/PATH, then stop')
    parser.add_argument('--stop', metavar='SESSION', help='stop exact owned processes in SESSION (or latest); never build/open')
    args = parser.parse_args(argv)
    if args.stop and (args.snapshot or args.no_build or args.engine or args.nano):
        parser.error('--stop cannot be combined with launch options')
    if (args.engine or args.nano) and not args.no_build:
        parser.error('--engine and --nano require --no-build')
    try:
        if args.stop:
            stop_session(args.stop)
        else:
            launch(args)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print('Nano demo: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
