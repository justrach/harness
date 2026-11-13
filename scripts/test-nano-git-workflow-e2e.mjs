#!/usr/bin/env node
// Native UI + real engine. All writes/pushes target a disposable synthetic
// repository and its local bare remote, never this checkout or a network host.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs/promises';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const base = path.join(root, '.graff/git-workflow-e2e', String(Date.now()));
const project = path.join(base, 'synthetic-project');
const remote = path.join(base, 'synthetic-remote.git');
const home = path.join(base, 'home');
const data = path.join(base, 'data');
await Promise.all([project, home, data].map(p => fs.mkdir(p, { recursive: true })));
const listener = net.createServer().listen(0, '127.0.0.1');
await once(listener, 'listening');
const port = listener.address().port;
await new Promise(resolve => listener.close(resolve));
const env = Object.fromEntries(['PATH', 'TMPDIR', 'LANG', 'LC_ALL'].filter(k => process.env[k]).map(k => [k, process.env[k]]));
Object.assign(env, {
  HOME: home, XDG_CONFIG_HOME: path.join(home, '.config'), XDG_DATA_HOME: path.join(home, '.local/share'),
  HARNESS_DATA_DIR: data, HARNESS_IPC_PORT: String(port), HARNESS_DEVICE_NAME: 'Synthetic Git host',
  HARNESS_PROVIDER: 'mock', HARNESS_NANO_HARNESS: 'mock', HARNESS_NANO_NO_ENGINE_START: '1',
  HARNESS_AUTO_UPDATE: '0', HARNESS_GRAFF_AUTO_UPDATE: '0', HARNESS_CODEGRAFF_CLIENT_ID: '',
  HARNESS_EDGE_URL: 'http://127.0.0.1:9', GRAFF_EXECUTABLE: path.join(project, 'unused-mock-graff'),
  GIT_CEILING_DIRECTORIES: base, GIT_CONFIG_NOSYSTEM: '1', GIT_TERMINAL_PROMPT: '0', RUST_LOG: 'warn',
});
async function run(exe, args, extra = {}) {
  const child = spawn(exe, args, { cwd: project, env: { ...env, ...extra }, stdio: ['ignore', 'pipe', 'pipe'] });
  const output = [];
  child.stdout.on('data', b => output.push(b));
  child.stderr.on('data', b => output.push(b));
  const timer = setTimeout(() => child.kill('SIGKILL'), 90_000);
  try {
    const [code] = await once(child, 'close');
    const text = Buffer.concat(output).toString();
    if (code !== 0) {
      await fs.writeFile(path.join(base, 'command-failure.log'), text);
      throw new Error(`${path.basename(exe)} fixture command failed (${code}); output saved locally`);
    }
    return text.trim();
  } finally { clearTimeout(timer); }
}
const git = args => run('git', args);
await git(['init', '-b', 'main']);
await git(['config', 'user.name', 'Demo Developer']);
await git(['config', 'user.email', 'demo@example.invalid']);
await fs.writeFile(path.join(project, 'navigation.zig'), '// version one\n');
await git(['add', '--', 'navigation.zig']);
await git(['commit', '-m', 'Synthetic initial commit']);
await git(['init', '--bare', remote]);
await git(['remote', 'add', 'origin', remote]);
await git(['push', '--set-upstream', 'origin', 'main']);
const originalHead = await git(['rev-parse', 'HEAD']);
await fs.writeFile(path.join(project, 'navigation.zig'), '// version two\n');
await fs.writeFile(path.join(project, 'notes.md'), '# Untracked synthetic notes\n');
let engine;
let socket;
let next = 1;
const calls = new Map();
const chat = 'git-workflow-chat';
function call(method, params = {}, stream = false) {
  const id = next++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { calls.delete(id); reject(new Error(`Fixture RPC timeout: ${method}`)); }, 30_000);
    calls.set(id, frame => {
      if (stream && 'ok' in frame) return;
      if (!('ok' in frame || 'item' in frame || 'err' in frame)) return;
      clearTimeout(timer);
      calls.delete(id);
      if (stream) socket.send(JSON.stringify({ id, cancel: true }));
      if ('err' in frame) reject(new Error(`Fixture RPC rejected: ${method}`));
      else resolve(frame.item ?? frame.ok);
    });
    socket.send(JSON.stringify({ id, method, params }));
  });
}
const state = () => call('GetCheckoutGitState', { chatId: chat });
const act = (snapshot, action) => call('ApplyCheckoutGitAction', {
  chatId: chat, checkoutId: snapshot.checkoutId, expectedChecksum: snapshot.checksum, action,
});
try {
  const log = await fs.open(path.join(base, 'engine.log'), 'w');
  engine = spawn(path.join(root, 'target/debug/harness'), ['headless'], { cwd: project, env, stdio: ['ignore', log.fd, log.fd] });
  await log.close();
  const deadline = Date.now() + 30_000;
  for (;;) {
    assert.equal(engine.exitCode, null, 'Fixture engine exited during startup');
    socket = new WebSocket(`ws://127.0.0.1:${port}`);
    const opened = await new Promise(resolve => {
      socket.addEventListener('open', () => resolve(true), { once: true });
      socket.addEventListener('error', () => resolve(false), { once: true });
    });
    if (opened) break;
    socket.close();
    assert(Date.now() < deadline, 'Fixture engine startup timed out');
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  socket.addEventListener('message', e => { const frame = JSON.parse(String(e.data)); calls.get(frame.id)?.(frame); });
  const devices = await call('WatchDevices', {}, true);
  const device = (Array.isArray(devices) ? devices : devices.items ?? devices.devices)[0].id;
  await call('Mutate', { op: 'createSpace', spaceId: 'git-workflow-project', deviceId: device, path: project, name: 'Synthetic Git project', gitDetected: true });
  await call('Mutate', { op: 'createChat', chatId: chat, spaceId: 'git-workflow-project', config: { harness: 'mock', model: 'mock-1', sandbox: 'workspace-write' } });
  await call('Mutate', { op: 'renameChat', chatId: chat, title: 'Synthetic staged changes' });
  let snapshot = await state();
  assert.equal(snapshot.branch, 'main');
  assert.equal(snapshot.blockedReason, null);
  assert.equal(snapshot.upstream.remote, 'origin');
  assert.equal(snapshot.files.length, 2);
  const beforeFiles = await git(['status', '--porcelain=v1']);
  const nano = path.join(root, 'apps/nano/zig-out/bin/harness-nano');
  await run(nano, ['--nanoui-hidden', '--nanoui-dark', '--nanoui-wait=3',
    `--nanoui-snapshot=${path.join(base, 'native-staging.png')}`,
    '--nanoui-script=click:Staging;live:2;click:Stage;live:2;click:Unstage;live:2'],
  { HARNESS_NANO_OPEN_CHAT: chat, HARNESS_NANO_PANELS: 'git-history' });
  assert.equal(await git(['status', '--porcelain=v1']), beforeFiles);
  assert.equal(await git(['rev-parse', 'HEAD']), originalHead);
  console.log('PASS real native controls stage then unstage one synthetic file without changing HEAD or working bytes');

  snapshot = await state();
  const staged = await act(snapshot, { kind: 'stage', path: 'navigation.zig' });
  assert(staged.files.some(f => f.path === 'navigation.zig' && f.indexStatus === 'M'));
  await assert.rejects(act(snapshot, { kind: 'commit', message: 'Must not commit stale index' }));
  await fs.writeFile(path.join(project, 'navigation.zig'), '// version three left unstaged\n');
  await assert.rejects(act(staged, { kind: 'stage', path: 'navigation.zig' }));
  snapshot = await state();
  const committed = await act(snapshot, { kind: 'commit', message: 'Commit only staged synthetic version two' });
  assert.notEqual(committed.headSha, originalHead);
  assert.equal(await git(['show', 'HEAD:navigation.zig']), '// version two');
  assert.equal(await fs.readFile(path.join(project, 'navigation.zig'), 'utf8'), '// version three left unstaged\n');
  assert.equal(await fs.readFile(path.join(project, 'notes.md'), 'utf8'), '# Untracked synthetic notes\n');
  assert.equal(await git(['log', '-1', '--format=%s']), 'Commit only staged synthetic version two');
  assert.equal(await git(['--git-dir', remote, 'rev-parse', 'refs/heads/main']), originalHead);
  console.log('PASS real engine rejects stale index/content and commits only the index, preserving unstaged/untracked files');
  await act(committed, { kind: 'push' });
  assert.equal(await git(['--git-dir', remote, 'rev-parse', 'refs/heads/main']), committed.headSha);
  assert.equal(await git(['show', 'HEAD:notes.md']).then(() => true, () => false), false);
  console.log('PASS normal one-branch push reaches only the fixture local bare remote; no real network or account used');
} finally {
  socket?.close();
  if (engine?.exitCode === null) {
    engine.kill('SIGTERM');
    await once(engine, 'close');
  }
}
