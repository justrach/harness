#!/usr/bin/env node
// Real engine + native UI over a temporary, synthetic Git repository.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs/promises';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const base = path.join(root, '.graff/source-control-e2e', String(Date.now()));
const home = path.join(base, 'home');
const data = path.join(base, 'data');
const project = path.join(base, 'synthetic-project');
await Promise.all([home, data, project].map(p => fs.mkdir(p, { recursive: true })));
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
  GIT_CEILING_DIRECTORIES: base, GIT_CONFIG_NOSYSTEM: '1', RUST_LOG: 'warn',
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
    if (code !== 0) throw new Error(`${path.basename(exe)} failed (${code}); fixture output saved locally`);
    return text.trim();
  } finally { clearTimeout(timer); }
}
const git = args => run('git', args);
await git(['init', '-b', 'main']);
await git(['config', 'user.name', 'Demo Developer']);
await git(['config', 'user.email', 'demo@example.invalid']);
await fs.writeFile(path.join(project, 'README.md'), '# Synthetic source control fixture\n');
await git(['add', 'README.md']);
const tree = await git(['write-tree']);
let head;
for (let i = 1; i <= 52; i++) head = await git(['commit-tree', tree, ...(head ? ['-p', head] : []), '-m', `Synthetic commit ${i}`]);
await git(['update-ref', 'refs/heads/main', head]);
const before = await git(['status', '--porcelain=v1']);
let engine;
let socket;
let next = 1;
const calls = new Map();
function call(method, params = {}, stream = false) {
  const id = next++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { calls.delete(id); reject(new Error(`Fixture RPC timeout: ${method}`)); }, 20_000);
    calls.set(id, frame => {
      if (stream && 'ok' in frame) return;
      if (!('ok' in frame || 'item' in frame || 'err' in frame)) return;
      clearTimeout(timer);
      calls.delete(id);
      if (stream) socket.send(JSON.stringify({ id, cancel: true }));
      if ('err' in frame) reject(new Error(`Fixture RPC failed: ${method}`));
      else resolve(frame.item ?? frame.ok);
    });
    socket.send(JSON.stringify({ id, method, params }));
  });
}
try {
  const log = await fs.open(path.join(base, 'engine.log'), 'w');
  engine = spawn(path.join(root, 'target/debug/harness'), ['headless'], { cwd: project, env, stdio: ['ignore', log.fd, log.fd] });
  await log.close();
  const deadline = Date.now() + 30_000;
  for (;;) {
    assert.equal(engine.exitCode, null, 'Fixture engine exited during startup');
    socket = new WebSocket(`ws://127.0.0.1:${port}`);
    const ready = await new Promise(resolve => {
      socket.addEventListener('open', () => resolve(true), { once: true });
      socket.addEventListener('error', () => resolve(false), { once: true });
    });
    if (ready) break;
    socket.close();
    assert(Date.now() < deadline, 'Fixture engine startup timed out');
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  socket.addEventListener('message', e => { const frame = JSON.parse(String(e.data)); calls.get(frame.id)?.(frame); });
  const devices = await call('WatchDevices', {}, true);
  const device = (Array.isArray(devices) ? devices : devices.items ?? devices.devices)[0].id;
  await call('Mutate', { op: 'createSpace', spaceId: 'git-fixture-project', deviceId: device, path: project, name: 'Synthetic Git project', gitDetected: true });
  await call('Mutate', { op: 'createChat', chatId: 'git-fixture-chat', spaceId: 'git-fixture-project', config: { harness: 'mock', model: 'mock-1', sandbox: 'workspace-write' } });
  await call('Mutate', { op: 'renameChat', chatId: 'git-fixture-chat', title: 'Synthetic source control' });
  const first = await call('ListGitHistory', { cwd: project, cursor: 0, limit: 50 });
  assert.equal(first.commits.length, 50);
  assert.equal(first.commits[0].subject, 'Synthetic commit 52');
  const second = await call('ListGitHistory', { cwd: project, cursor: first.nextCursor, limit: 50 });
  assert.equal(second.commits.length, 2);
  console.log('PASS real engine returns two correctly paged synthetic Git history pages');
  const nano = path.join(root, 'apps/nano/zig-out/bin/harness-nano');
  const steps = ['click:Synthetic commit 52', 'click:Next', 'live:1', 'click:Synthetic commit 2', 'click:Previous', 'live:1', 'click:Synthetic commit 52'];
  await run(nano, ['--nanoui-hidden', '--nanoui-dark', '--nanoui-wait=3', `--nanoui-snapshot=${path.join(base, 'git-history.png')}`, `--nanoui-script=${steps.join(';')}`], { HARNESS_NANO_OPEN_CHAT: 'git-fixture-chat', HARNESS_NANO_PANELS: 'git-history' });
  console.log('PASS real native history surface opens at startup and pages against the engine');
  await run(nano, ['--nanoui-hidden', '--nanoui-dark', '--nanoui-wait=3', `--nanoui-snapshot=${path.join(base, 'github-empty.png')}`, '--nanoui-script=click:Session pull requests'], { HARNESS_NANO_OPEN_CHAT: 'git-fixture-chat', HARNESS_NANO_PANELS: 'github' });
  console.log('PASS real native GitHub surface opens safely without GitHub credentials or a remote');
  assert.equal(await git(['rev-parse', 'HEAD']), head);
  assert.equal(await git(['status', '--porcelain=v1']), before);
  console.log('PASS history and PR surfaces leave HEAD, the index and files unchanged');
} finally {
  socket?.close();
  if (engine?.exitCode === null) {
    engine.kill('SIGTERM');
    await once(engine, 'close');
  }
}
