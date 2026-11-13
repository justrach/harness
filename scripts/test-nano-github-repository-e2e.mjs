#!/usr/bin/env node
// Real engine/native UI + fake gh. No account, real repository data or external
// API traffic: macOS sandboxing permits loopback IPC only.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs/promises';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
assert.equal(process.platform, 'darwin', 'This native e2e requires macOS sandbox-exec');
const root = fileURLToPath(new URL('../', import.meta.url));
const base = path.join(root, '.graff/github-repository-e2e', String(Date.now()));
const project = path.join(base, 'synthetic-project');
const home = path.join(base, 'home');
const data = path.join(base, 'data');
const bin = path.join(base, 'bin');
await Promise.all([project, home, data, bin].map(p => fs.mkdir(p, { recursive: true })));
const profile = path.join(base, 'loopback-only.sb');
await fs.writeFile(profile, '(version 1)\n(allow default)\n(deny network*)\n(allow network-inbound (local ip "localhost:*"))\n(allow network-outbound (remote ip "localhost:*"))\n');
const requestLog = path.join(base, 'fake-gh.jsonl');
const fakeGh = `#!${process.execPath}
import fs from 'node:fs';
const args = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(requestLog)}, JSON.stringify(args) + '\\n');
if (args[0] === 'pr') { console.log('[]'); process.exit(0); }
if (args[0] === 'repo') { console.log('{"defaultBranchRef":{"name":"main"}}'); process.exit(0); }
const endpoint = args.find(a => a.startsWith('/repos/'));
if (args[0] !== 'api' || !endpoint || args[args.indexOf('--method') + 1] !== 'GET' || args[args.indexOf('--hostname') + 1] !== 'github.com') process.exit(3);
const u = new URL('https://fixture.invalid' + endpoint);
if (!u.pathname.startsWith('/repos/demo/fieldnotes/')) process.exit(4);
const item = (number, title, issue = false) => ({number,title,state:'open',draft:false,user:{login:'demo-author'},created_at:'2026-11-12T10:00:00Z',updated_at:'2026-11-13T10:00:00Z',body:issue?'Synthetic issue description':'Synthetic pull request description',base:{ref:'main'},head:{ref:'feature/navigation'},additions:18,deletions:4,changed_files:2});
let body; let next = false;
if (u.pathname.endsWith('/timeline')) body = [{id:1,event:'commented',user:{login:'demo-reviewer'},body:'Please preserve keyboard focus.',created_at:'2026-11-13T10:00:00Z'},{id:2,event:'reviewed',user:{login:'demo-maintainer'},state:'approved',submitted_at:'2026-11-13T11:00:00Z',body:'Native regression coverage looks good.'}];
else if (u.pathname.endsWith('/files')) body = [{filename:'src/navigation.zig',status:'modified',additions:18,deletions:4,patch:'@@ -1 +1 @@\\n-old navigation\\n+native repository navigation'},{filename:'assets/navigation.png',status:'modified',additions:0,deletions:0}];
else if (u.pathname.endsWith('/pulls/42')) body = item(42,'Polish repository navigation');
else if (u.pathname.endsWith('/issues/51')) body = item(51,'Track keyboard navigation',true);
else if (u.pathname.endsWith('/pulls')) { next = u.searchParams.get('page') !== '2'; body = next ? [item(42,'Polish repository navigation')] : [item(44,'Improve repository search')]; }
else if (u.pathname.endsWith('/issues')) body = [{...item(42,'PR excluded from issue list'),pull_request:{url:'https://api.github.com/repos/demo/fieldnotes/pulls/42'}},item(51,'Track keyboard navigation',true)];
else process.exit(5);
process.stdout.write('HTTP/2.0 200 OK\\ncontent-type: application/json\\n' + (next ? 'link: <https://untrusted.invalid/never-follow-this>; rel="next"\\n' : '') + '\\n' + JSON.stringify(body));
`;
await fs.writeFile(path.join(bin, 'gh'), fakeGh, { mode: 0o755 });
const listener = net.createServer().listen(0, '127.0.0.1');
await once(listener, 'listening');
const port = listener.address().port;
await new Promise(resolve => listener.close(resolve));
const env = Object.fromEntries(['PATH', 'TMPDIR', 'LANG', 'LC_ALL'].filter(k => process.env[k]).map(k => [k, process.env[k]]));
Object.assign(env, {
  PATH: `${bin}:${env.PATH}`, HOME: home, XDG_CONFIG_HOME: path.join(home, '.config'), XDG_DATA_HOME: path.join(home, '.local/share'),
  HARNESS_NO_LOGIN_SHELL: '1', HARNESS_DATA_DIR: data, HARNESS_IPC_PORT: String(port), HARNESS_DEVICE_NAME: 'Synthetic GitHub host',
  HARNESS_PROVIDER: 'mock', HARNESS_NANO_HARNESS: 'mock', HARNESS_NANO_NO_ENGINE_START: '1',
  HARNESS_AUTO_UPDATE: '0', HARNESS_GRAFF_AUTO_UPDATE: '0', HARNESS_CODEGRAFF_CLIENT_ID: '',
  HARNESS_EDGE_URL: 'http://127.0.0.1:9', GRAFF_EXECUTABLE: path.join(project, 'unused-mock-graff'),
  GIT_CEILING_DIRECTORIES: base, GIT_CONFIG_NOSYSTEM: '1', GIT_TERMINAL_PROMPT: '0', RUST_LOG: 'warn',
});
const sandbox = (exe, args) => ['/usr/bin/sandbox-exec', ['-f', profile, exe, ...args]];
async function run(exe, args, extra = {}, guarded = false) {
  const [command, argv] = guarded ? sandbox(exe, args) : [exe, args];
  const child = spawn(command, argv, { cwd: project, env: { ...env, ...extra }, stdio: ['ignore', 'pipe', 'pipe'] });
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
await fs.writeFile(path.join(project, 'README.md'), '# Synthetic repository fixture\n');
await git(['add', '--', 'README.md']);
await git(['commit', '-m', 'Synthetic initial commit']);
await git(['remote', 'add', 'origin', 'https://github.com/demo/fieldnotes.git']);
const beforeHead = await git(['rev-parse', 'HEAD']);
const beforeIndex = await git(['ls-files', '--stage']);
const beforeStatus = await git(['status', '--porcelain=v1']);
let engine;
let socket;
let next = 1;
const calls = new Map();
const chat = 'github-browser-chat';
function call(method, params = {}, stream = false) {
  const id = next++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { calls.delete(id); reject(new Error(`Fixture RPC timeout: ${method}`)); }, 30_000);
    calls.set(id, frame => {
      if (stream && 'ok' in frame) return;
      if (!('ok' in frame || 'item' in frame || 'err' in frame)) return;
      clearTimeout(timer); calls.delete(id);
      if (stream) socket.send(JSON.stringify({ id, cancel: true }));
      if ('err' in frame) reject(new Error(`Fixture RPC rejected: ${method}`));
      else resolve(frame.item ?? frame.ok);
    });
    socket.send(JSON.stringify({ id, method, params }));
  });
}
const browse = params => call('BrowseCheckoutGitHub', { chatId: chat, ...params });
try {
  const log = await fs.open(path.join(base, 'engine.log'), 'w');
  const [exe, argv] = sandbox(path.join(root, 'target/debug/harness'), ['headless']);
  engine = spawn(exe, argv, { cwd: project, env, stdio: ['ignore', log.fd, log.fd] });
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
  await call('Mutate', { op: 'createSpace', spaceId: 'github-browser-project', deviceId: device, path: project, name: 'Synthetic GitHub project', gitDetected: true });
  await call('Mutate', { op: 'createChat', chatId: chat, spaceId: 'github-browser-project', config: { harness: 'mock', model: 'mock-1', sandbox: 'read-only' } });
  await call('Mutate', { op: 'renameChat', chatId: chat, title: 'Synthetic repository browser' });
  const first = await browse({ kind: 'pulls', state: 'open' });
  assert.equal(first.repository.key, 'github.com/demo/fieldnotes');
  assert.equal(first.items[0].number, 42);
  assert.equal(first.hasNextPage, true);
  const expectedRepository = first.repository.key;
  const second = await browse({ kind: 'pulls', page: 2, expectedRepository });
  assert.equal(second.items[0].number, 44);
  const issueList = await browse({ kind: 'issues', expectedRepository });
  assert.deepEqual(issueList.items.map(i => i.number), [51]);
  const summary = await browse({ kind: 'pull', number: 42, expectedRepository });
  assert.equal(summary.detail.headRef, 'feature/navigation');
  const code = await browse({ kind: 'files', number: 42, expectedRepository });
  assert.equal(code.files[1].patchTruncated, true);
  const timeline = await browse({ kind: 'activity', number: 42, expectedRepository });
  assert.equal(timeline.events[1].event, 'reviewed: approved');
  await git(['remote', 'set-url', 'origin', 'https://github.com/demo/another-repository.git']);
  await assert.rejects(browse({ kind: 'pull', number: 42, expectedRepository }));
  await git(['remote', 'set-url', 'origin', 'https://github.com/demo/fieldnotes.git']);
  console.log('PASS real engine: repository-wide pages, issue filtering, PR detail/files/activity and repository fences through fake gh');
  const nano = path.join(root, 'apps/nano/zig-out/bin/harness-nano');
  const extra = { HARNESS_NANO_OPEN_CHAT: chat, HARNESS_NANO_PANELS: 'github' };
  await run(nano, ['--nanoui-hidden', '--nanoui-dark', '--nanoui-wait=3', `--nanoui-snapshot=${path.join(base, 'native-code.png')}`,
    '--nanoui-script=click:Repository;live:1;click:Polish repository navigation;live:1;click:Code;live:1;click:src/navigation.zig;live:1'], extra, true);
  await run(nano, ['--nanoui-hidden', '--nanoui-dark', '--nanoui-wait=3', `--nanoui-snapshot=${path.join(base, 'native-activity.png')}`,
    '--nanoui-script=click:Repository;live:1;click:Polish repository navigation;live:1;click:Activity;live:1;click:demo-maintainer · reviewed: approved'], extra, true);
  await run(nano, ['--nanoui-hidden', '--nanoui-dark', '--nanoui-wait=3', `--nanoui-snapshot=${path.join(base, 'native-issue.png')}`,
    '--nanoui-script=click:Repository;live:1;click:Issues;live:1;click:Track keyboard navigation;live:1'], extra, true);
  assert.equal(await git(['rev-parse', 'HEAD']), beforeHead);
  assert.equal(await git(['ls-files', '--stage']), beforeIndex);
  assert.equal(await git(['status', '--porcelain=v1']), beforeStatus);
  assert.equal(await fs.readFile(path.join(project, 'README.md'), 'utf8'), '# Synthetic repository fixture\n');
  const requests = (await fs.readFile(requestLog, 'utf8')).trim().split('\n').map(JSON.parse).filter(a => a[0] === 'api');
  assert(requests.length >= 12);
  assert(requests.every(a => a[a.indexOf('--method') + 1] === 'GET'));
  assert(requests.every(a => a.find(v => v.startsWith('/repos/'))?.startsWith('/repos/demo/fieldnotes/')));
  console.log('PASS real native PR code/activity and issue details; checkout HEAD/index/files unchanged; all provider calls GET-only and network sandboxed');
} finally {
  socket?.close();
  if (engine?.exitCode === null) { engine.kill('SIGTERM'); await once(engine, 'close'); }
}
