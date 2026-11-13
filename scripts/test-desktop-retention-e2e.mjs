#!/usr/bin/env node
// Real Nano executable + real local engine + mock agent, without accounts or
// personal application state. Run after `cargo build -p harness` and the Nano
// build. Override executable paths with --harness=PATH / --nano=PATH;
// --debug=1 captures each UI step. Output must be a new directory under .graff.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs/promises';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const flags = Object.fromEntries(process.argv.slice(2).map(arg => {
  assert(arg.startsWith('--') && arg.includes('='), 'Use --name=value arguments');
  const at = arg.indexOf('=');
  return [arg.slice(2, at), arg.slice(at + 1)];
}));
const target = path.resolve(root, process.env.CARGO_TARGET_DIR ?? 'target');
const harness = path.resolve(flags.harness ?? path.join(target, 'debug/harness'));
const nano = path.resolve(flags.nano ?? path.join(root, 'apps/nano/zig-out/bin/harness-nano'));
const out = path.resolve(flags.out ?? path.join(root, '.graff/retention-audit/deep/live', String(Date.now())));
await fs.access(harness);
await fs.access(nano);
assert(!path.relative(root, out).startsWith('..') && path.relative(root, out).startsWith('.graff/'), 'Fixture output must be under this checkout’s .graff directory');
await fs.mkdir(out, { recursive: true });
assert.equal((await fs.readdir(out)).length, 0, 'Refusing to reuse existing fixture data');
const data = path.join(out, 'data');
const home = path.join(out, 'home');
const project = path.join(out, 'synthetic-project');
await Promise.all([data, home, project].map(p => fs.mkdir(p, { recursive: true })));
await fs.writeFile(path.join(project, 'README.md'), '# Synthetic retention fixture\n');
await fs.writeFile(path.join(project, 'notes.txt'), 'SYNTHETIC_EDITOR_ORIGINAL\n');
const image = path.join(project, 'synthetic-attachment.png');
await fs.copyFile(path.join(root, 'apps/nano/src/icons/copy.png'), image);
const listener = net.createServer();
listener.listen(0, '127.0.0.1');
await once(listener, 'listening');
const port = listener.address().port;
await new Promise((resolve, reject) => listener.close(e => e ? reject(e) : resolve()));
// Do not inherit credentials, a real org, provider configuration or data paths.
const env = Object.fromEntries(['PATH', 'TMPDIR', 'LANG', 'LC_ALL', 'DEVELOPER_DIR', 'SDKROOT'].filter(k => process.env[k]).map(k => [k, process.env[k]]));
Object.assign(env, {
  HOME: home, XDG_CONFIG_HOME: path.join(home, '.config'), XDG_DATA_HOME: path.join(home, '.local/share'),
  // A genuine plain-folder fixture: Git discovery must stop before it can
  // inherit the enclosing source checkout. No synthetic commits are needed.
  GIT_CEILING_DIRECTORIES: out,
  HARNESS_DATA_DIR: data, HARNESS_IPC_PORT: String(port), HARNESS_DEVICE_NAME: 'Synthetic retention host',
  HARNESS_PROVIDER: 'mock', HARNESS_NANO_HARNESS: 'mock', HARNESS_NANO_NO_ENGINE_START: '1',
  // Explicit executable override skips unrelated managed-Graff update cards.
  // This nonexistent path is never executed: every fixture chat uses Mock.
  GRAFF_EXECUTABLE: path.join(project, 'unused-mock-graff'),
  HARNESS_AUTO_UPDATE: '0', HARNESS_GRAFF_AUTO_UPDATE: '0', HARNESS_CODEGRAFF_CLIENT_ID: '',
  HARNESS_EDGE_URL: 'http://127.0.0.1:9', HARNESS_MOCK_QUESTION: '1', HARNESS_MOCK_DELAY_MS: '50',
  RUST_LOG: 'warn',
});
const checks = [];
let engine;
let rpc;
let alphaResponse;
async function checked(name, run) {
  await run();
  checks.push({ name, passed: true });
  console.log(`PASS ${name}`);
}
async function child(executable, args, options = {}) {
  const proc = spawn(executable, args, { cwd: project, env, ...options, stdio: ['ignore', 'pipe', 'pipe'] });
  const chunks = [];
  proc.stdout.on('data', b => chunks.push(b));
  proc.stderr.on('data', b => chunks.push(b));
  const timer = setTimeout(() => proc.kill('SIGKILL'), 90_000);
  try {
    const [code, signal] = await once(proc, 'close');
    const log = Buffer.concat(chunks).toString();
    return { code, signal, log };
  } finally { clearTimeout(timer); }
}
class Rpc {
  constructor(ws) {
    this.ws = ws;
    this.next = 1;
    this.calls = new Map();
    ws.addEventListener('message', e => {
      const frame = JSON.parse(String(e.data));
      const pending = this.calls.get(frame.id);
      if (!pending) return;
      if ('err' in frame) pending.reject(new Error(`RPC ${pending.method}: ${frame.err}`));
      else if ('item' in frame) pending.item?.(frame.item);
      else if ('ok' in frame) pending.resolve(frame.ok);
      else if (frame.done) pending.done?.();
      if ('err' in frame || 'ok' in frame || frame.done) this.calls.delete(frame.id);
    });
  }
  call(method, params = {}) {
    const id = this.next++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.calls.delete(id); reject(new Error(`RPC timeout: ${method}`)); }, 20_000);
      this.calls.set(id, { method, resolve: v => { clearTimeout(timer); resolve(v); }, reject: e => { clearTimeout(timer); reject(e); } });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  watch(method, params = {}) {
    const id = this.next++;
    const values = [];
    const waits = new Set();
    let failure;
    const item = value => {
      values.push(value);
      if (values.length > 512) values.shift();
      for (const w of waits) if (w.predicate(value)) { clearTimeout(w.timer); waits.delete(w); w.resolve(value); }
    };
    this.calls.set(id, { method, item, resolve() {}, reject: e => {
      failure = e;
      for (const w of waits) { clearTimeout(w.timer); w.reject(e); }
      waits.clear();
    } });
    this.ws.send(JSON.stringify({ id, method, params }));
    return {
      values,
      wait: (predicate = () => true) => {
        if (failure) return Promise.reject(failure);
        const existing = values.findLast(predicate);
        if (existing !== undefined) return Promise.resolve(existing);
        return new Promise((resolve, reject) => {
          const w = { predicate, resolve, reject };
          w.timer = setTimeout(() => { waits.delete(w); reject(new Error(`Stream timeout: ${method}`)); }, 20_000);
          waits.add(w);
        });
      },
      close: () => {
        this.calls.delete(id);
        this.ws.send(JSON.stringify({ id, cancel: true }));
        for (const w of waits) { clearTimeout(w.timer); w.reject(new Error(`Cancelled ${method}`)); }
        waits.clear();
      },
    };
  }
  close() { this.ws.close(); }
}
async function connect() {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (engine.exitCode !== null) throw new Error('Isolated engine exited before accepting IPC');
    const ws = new WebSocket(`ws://127.0.0.1:${port}`);
    const opened = await new Promise(resolve => {
      ws.addEventListener('open', () => resolve(true), { once: true });
      ws.addEventListener('error', () => resolve(false), { once: true });
    });
    if (opened) return new Rpc(ws);
    ws.close();
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error('Isolated engine did not become ready');
}
async function snapshot(chat) {
  const stream = rpc.watch('WatchDocMessages', { chatId: chat, reset: true });
  try { return await stream.wait(v => Array.isArray(v.reset)); }
  finally { stream.close(); }
}
async function ui(name, chat, steps) {
  const shot = path.join(out, `${name}.png`);
  const scripted = flags.debug === '1' ? steps.flatMap((step, i) => [`snap:${path.join(out, `${name}-step-${String(i).padStart(2, '0')}.png`)}`, step]) : steps;
  await fs.writeFile(path.join(out, `${name}-steps.json`), JSON.stringify(scripted, null, 2) + '\n');
  const result = await child(nano, ['--nanoui-hidden', '--nanoui-dark', '--nanoui-wait=3', `--nanoui-snapshot=${shot}`, `--nanoui-script=${scripted.join(';')}`], { env: { ...env, HARNESS_NANO_OPEN_CHAT: chat } });
  const nativeLog = await fs.readFile(path.join(data, 'logs/harness-nano.log'), 'utf8').catch(() => '');
  await fs.writeFile(path.join(out, `${name}.log`), result.log + nativeLog);
  assert.equal(result.code, 0, `${name}: UI process failed (${result.signal ?? result.code}); see local fixture log`);
  assert((await fs.stat(shot)).size > 1000, `${name}: no rendered screenshot`);
}

try {
  const log = await fs.open(path.join(out, 'engine.log'), 'w');
  engine = spawn(harness, ['headless'], { cwd: project, env, stdio: ['ignore', log.fd, log.fd] });
  await log.close();
  rpc = await connect();
  const devices = rpc.watch('WatchDevices');
  const rows = value => Array.isArray(value) ? value : value?.items ?? value?.devices ?? [];
  const deviceFrame = await devices.wait(v => rows(v).length > 0);
  const device = rows(deviceFrame)[0].id;
  devices.close();
  assert.equal(rows(deviceFrame).length, 1, 'Fixture must have only its own synthetic device');
  const space = 'retention-project';
  const alpha = 'retention-alpha';
  const beta = 'retention-beta';
  await checked('isolated engine accepts a synthetic project and chat configuration', async () => {
    await rpc.call('Mutate', { op: 'createSpace', spaceId: space, deviceId: device, path: project, gitDetected: false });
    for (const [chatId, title] of [[alpha, 'Synthetic Alpha'], [beta, 'Synthetic Beta']]) {
      await rpc.call('Mutate', { op: 'createChat', chatId, spaceId: space, config: { harness: 'mock', model: 'mock-1', reasoning: 'medium', modelOptions: {}, sandbox: 'workspace-write' } });
      await rpc.call('Mutate', { op: 'renameChat', chatId, title });
    }
  });
  const pending = rpc.watch('WatchDocMessages', { chatId: alpha, reset: true });
  await pending.wait();
  await rpc.call('QueueCommand', { chatId: alpha, command: { kind: 'run', messageId: 'retention-initial-message', request: { prompt: 'SYNTHETIC_QUESTION_NAVIGATION', turnOrigin: 'human', harness: 'mock', model: 'mock-1', cwd: project, sandbox: 'workspace-write', modelOptions: {}, autoApprove: false } } });
  await pending.wait(v => JSON.stringify(v).includes('Which sync strategy should the rewrite use?'));
  pending.close();
  await checked('real UI preserves question choices and page across new-tab navigation', async () => {
    await ui('question-navigation', alpha, [
      'click:Event-driven fold with coalesced commits', 'click:Next', 'click:Unit tests',
      'chord:cmd+t', 'chord:cmd+l', 'type:SYNTHETIC_PARKED_CANVAS_DRAFT', 'chord:ctrl+shift+tab',
      'click:Which suites should gate the merge?', 'click:Golden screenshots',
      `snap:${path.join(out, 'question-before-submit.png')}`, 'click:Submit', 'live:3',
    ]);
    const final = await snapshot(alpha);
    await fs.writeFile(path.join(out, 'question-final.json'), JSON.stringify(final, null, 2) + '\n');
    const answer = final.reset.filter(e => e.role === 'assistant').flatMap(e => e.parts ?? []).filter(p => p.kind === 'text').map(p => p.text ?? '').join('\n');
    assert(answer.includes('Locked in:'), 'Mock did not receive an actual answer command');
    assert(answer.includes('Unit tests'), 'The selected option was lost across navigation');
    assert(answer.includes('Golden screenshots'), 'The second selected option did not reach the engine');
    assert(answer.includes('Event-driven fold with coalesced commits'), 'The first question choice was lost');
    alphaResponse = answer.slice(answer.indexOf('Locked in:')).replaceAll('**', '').trim();
  });
  const fixtureFiles = await rpc.call('ListWorkspaceDirectory', { chatId: alpha, directory: '', includeIgnored: true });
  await fs.writeFile(path.join(out, 'fixture-file-listing.json'), JSON.stringify(fixtureFiles, null, 2) + '\n');
  const fixtureChats = rpc.watch('WatchChats');
  await fs.writeFile(path.join(out, 'fixture-chat-contexts.json'), JSON.stringify(await fixtureChats.wait(), null, 2) + '\n');
  fixtureChats.close();
  assert(fixtureFiles.entries?.some(entry => entry.path === 'notes.txt'), 'Fixture workspace escaped its plain-folder boundary');
  await checked('real composer send uploads an image and delivers its prompt to the engine', async () => {
    await ui('native-send-and-drop', alpha, [
      'chord:cmd+t', 'chord:cmd+l', 'type:SYNTHETIC_NATIVE_SEND_WITH_IMAGE',
      `drop:800,500,${image}`, 'live:2', `snap:${path.join(out, 'attachment-before-send.png')}`,
      'key:enter', 'live:1',
    ]);
    const chats = rpc.watch('WatchChats');
    const frame = await chats.wait(v => rows(v).some(c => c.id !== alpha && c.id !== beta));
    chats.close();
    const created = rows(frame).filter(c => c.id !== alpha && c.id !== beta);
    assert.equal(created.length, 1, 'Sending one draft should create exactly one conversation');
    // Fresh isolated Git setup can outlast a fixed UI delay. Synchronize on
    // the actual pending question, then answer through another real UI mount.
    const question = rpc.watch('WatchDocMessages', { chatId: created[0].id, reset: true });
    await question.wait(v => JSON.stringify(v).includes('Which sync strategy should the rewrite use?'));
    question.close();
    await ui('attachment-question-answer', created[0].id, [
      'click:Event-driven fold with coalesced commits', 'click:Next',
      'click:Unit tests', 'click:Submit', 'live:3',
    ]);
    const final = await snapshot(created[0].id);
    await fs.writeFile(path.join(out, 'native-send-final.json'), JSON.stringify(final, null, 2) + '\n');
    const text = JSON.stringify(final);
    assert(text.includes('SYNTHETIC_NATIVE_SEND_WITH_IMAGE'), 'Composer text did not reach the actual transcript');
    assert(text.includes('synthetic-attachment.png'), 'Dropped image was not retained in the delivered user message');
    const answer = final.reset.filter(e => e.role === 'assistant').flatMap(e => e.parts ?? []).filter(p => p.kind === 'text').map(p => p.text ?? '').join('\n');
    assert(answer.includes('Locked in:'), 'The created chat did not finish its mock question workflow');
  });
  await checked('cancelling a question resolves it through the real command queue', async () => {
    const requested = rpc.watch('WatchDocMessages', { chatId: beta, reset: true });
    await requested.wait();
    await rpc.call('QueueCommand', { chatId: beta, command: { kind: 'run', messageId: 'retention-cancel-message', request: { prompt: 'SYNTHETIC_CANCEL_QUESTION', turnOrigin: 'human', harness: 'mock', model: 'mock-1', cwd: project, sandbox: 'workspace-write', modelOptions: {}, autoApprove: false } } });
    await requested.wait(v => JSON.stringify(v).includes('Which sync strategy should the rewrite use?'));
    requested.close();
    await ui('question-cancel', beta, ['click:Cancel question', 'live:3']);
    const final = await snapshot(beta);
    await fs.writeFile(path.join(out, 'question-cancel-final.json'), JSON.stringify(final, null, 2) + '\n');
    const inputs = final.reset.flatMap(e => e.parts ?? []).filter(p => p.kind === 'input');
    assert(inputs.length > 0 && inputs.every(p => p.resolved), 'Cancel did not resolve the actual pending question');
  });
  await checked('project-picker, close/reopen and cycle shortcuts work on actual engine-backed chats', async () => {
    await ui('live-shortcuts', alpha, [
      'chord:cmd+shift+p', 'click:Search projects…', 'key:escape',
      // Check the unique reply, not the sidebar title: clicking the latter
      // would accidentally repair a failed reopen/cycle by navigating itself.
      'chord:cmd+alt+w', 'chord:cmd+shift+t', 'live:1', `click:${alphaResponse}`,
      'chord:cmd+t', 'chord:ctrl+shift+tab', 'live:1', `click:${alphaResponse}`,
    ]);
  });
  await checked('real file editor explicitly saves through the engine with checkout and content fences', async () => {
    await ui('workspace-file-save', alpha, [
      'resize:1320x880', 'chord:cmd+e', 'live:1',
      // The isolated directory is intentionally below ignored .graff. Enable
      // the native file toolbar's Show all control at this fixed viewport.
      'at:1294,63', 'live:1', 'click:notes.txt', 'live:1',
      'chord:cmd+a', 'type:SYNTHETIC_EXPLICIT_FILE_EDIT', 'chord:cmd+s', 'live:2',
    ]);
    assert.equal(await fs.readFile(path.join(project, 'notes.txt'), 'utf8'), 'SYNTHETIC_EXPLICIT_FILE_EDIT', 'Explicit editor Save did not publish the intended file through the real engine');
  });
  await checked('plain-folder working-tree diff stops loading and explains Git is unavailable (#750)', async () => {
    await assert.rejects(fs.stat(path.join(project, '.git')), { code: 'ENOENT' }, 'The fixture must remain a plain folder');
    await assert.rejects(rpc.call('GetCheckoutDiff', { cwd: project, mode: 'workingTree' }), /not a git repository/i);
    await ui('plain-folder-diff-unavailable', alpha, [
      'chord:cmd+l', 'type:/diff', 'click:Open changes', 'live:2',
      'click:This folder is not a Git repository. Working-tree diffs require a Git checkout.',
    ]);
    await assert.rejects(fs.stat(path.join(project, '.git')), { code: 'ENOENT' }, 'Reviewing changes must not initialize Git');
    assert.equal(await fs.readFile(path.join(project, 'notes.txt'), 'utf8'), 'SYNTHETIC_EXPLICIT_FILE_EDIT', 'The plain-folder edit must be preserved');
  });
  await fs.writeFile(path.join(out, 'results.json'), JSON.stringify({ passed: true, engine: 'real local IPC', agent: 'mock', personalData: false, checks }, null, 2) + '\n');
  console.log(`Synthetic end-to-end evidence: ${path.relative(root, out)}`);
} catch (error) {
  await fs.writeFile(path.join(out, 'results.json'), JSON.stringify({ passed: false, checks, error: String(error) }, null, 2) + '\n');
  throw error;
} finally {
  rpc?.close();
  if (engine && engine.exitCode === null) {
    const exited = once(engine, 'exit');
    engine.kill('SIGTERM');
    const timer = setTimeout(() => engine.kill('SIGKILL'), 5000);
    await exited;
    clearTimeout(timer);
  }
}
