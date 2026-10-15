import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, realpathSync, existsSync, symlinkSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const runner = fileURLToPath(new URL('../../../remote/development.mjs', import.meta.url));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function fixture(t, actions) {
  const base = realpathSync(mkdtempSync(join(tmpdir(), 'molt-runner.')));
  const root = join(base, 'repo with $literal');
  const state = join(base, 'state');
  const profile = join(base, 'profile.json');
  mkdirSync(root);
  writeFileSync(profile, JSON.stringify({ version: 1, name: 'Runner', actions, ports: [], android: { enabled: false } }));
  const args = ['--root', root, '--state', state, '--profile', profile];
  const run = (...command) => spawnSync(process.execPath, [runner, ...args, ...command], { encoding: 'utf8', timeout: 15000 });
  t.after(() => { run('stop'); rmSync(base, { recursive: true, force: true }); });
  return { base, root, state, profile, args, run };
}
const task = (code, cwd = '.') => ({ id: 'test', label: 'Run tests', kind: 'task', argv: [process.execPath, '-e', code], cwd });
const service = { id: 'dev', label: 'Development', kind: 'service', argv: [process.execPath, '-e', 'console.log("service ready"); setInterval(() => {}, 1000)'], cwd: '.' };
function ok(result) { assert.equal(result.status, 0, result.stderr); }

test('status and logs observe an absent state without creating it', t => {
  const f = fixture(t, [service]);
  ok(f.run('status'));
  assert.equal(existsSync(f.state), false, 'status created runtime state');
  assert.deepEqual(JSON.parse(f.run('status').stdout), [{ id: 'dev', label: 'Development', state: 'stopped', reason: '' }]);
  ok(f.run('logs', 'dev'));
  assert.equal(existsSync(f.state), false);
});

test('tasks execute literal argv and preserve their exit status', t => {
  const f = fixture(t, [{ ...task('console.log(JSON.stringify(process.argv.slice(1))); process.exit(7)'), argv: [process.execPath, '-e', 'console.log(JSON.stringify(process.argv.slice(1))); process.exit(7)', 'a b', '$(touch injected)', '`literal`', '$HOME'] }]);
  const result = f.run('run', 'test');
  assert.equal(result.status, 7, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), ['a b', '$(touch injected)', '`literal`', '$HOME']);
  assert.equal(existsSync(join(f.root, 'injected')), false);
});

test('schema, unknown actions and cwd escapes fail with status 2', t => {
  const f = fixture(t, [task('process.exit(0)')]);
  assert.equal(f.run('run', 'missing').status, 2);
  symlinkSync(f.base, join(f.root, 'escape'));
  writeFileSync(f.profile, JSON.stringify({ version: 1, name: 'Bad', actions: [task('', 'escape')], ports: [] }));
  assert.equal(f.run('run', 'test').status, 2);
  writeFileSync(f.profile, '{"version":1,"version":1,"name":"Duplicate","actions":[]}');
  assert.equal(f.run('list').status, 2);
  for (const invalid of [{ ...task('process.exit(0)'), id: undefined }, { ...task('process.exit(0)'), id: ['test'] }, task('process.exit(0)', '')]) {
    writeFileSync(f.profile, JSON.stringify({ version: 1, name: 'Bad', actions: [invalid] }));
    assert.equal(f.run('list').status, 2, 'accepted an invalid action ID or cwd');
  }
  writeFileSync(f.profile, '{\u00a0"version":1,"name":"Bad"}');
  assert.equal(f.run('list').status, 2, 'accepted non-JSON whitespace');
});

test('service action through run persists after the client exits and stop is idempotent', async t => {
  const f = fixture(t, [service]);
  ok(f.run('run', 'dev'));
  await sleep(200);
  assert.equal(JSON.parse(f.run('status').stdout)[0].state, 'running');
  ok(f.run('start', 'dev'));
  assert.match(f.run('logs', 'dev').stdout, /service ready/);
  ok(f.run('stop'));
  ok(f.run('stop'));
  assert.equal(JSON.parse(f.run('status').stdout)[0].state, 'stopped');
});

test('failed exec is recorded and never reported running', async t => {
  const f = fixture(t, [{ ...service, argv: ['/molt-nonexistent-executable'] }]);
  assert.equal(f.run('start', 'dev').status, 1);
  await sleep(100);
  assert.equal(JSON.parse(f.run('status').stdout)[0].state, 'failed');
});

test('stop rejects a live process whose recorded start identity changed', async t => {
  const f = fixture(t, [service]);
  ok(f.run('start', 'dev'));
  const path = join(f.state, 'services', 'dev.json');
  const original = readFileSync(path, 'utf8');
  const record = JSON.parse(original);
  record.supervisor.start = 'foreign-start';
  writeFileSync(path, JSON.stringify(record));
  assert.equal(f.run('stop', 'dev').status, 1);
  assert.doesNotThrow(() => process.kill(record.supervisor.pid, 0));
  writeFileSync(path, original);
  ok(f.run('stop', 'dev'));
});

test('state symlinks are rejected before writing or signaling', t => {
  const f = fixture(t, [service]);
  const outside = join(f.base, 'outside'); mkdirSync(outside);
  symlinkSync(outside, f.state);
  assert.equal(f.run('start', 'dev').status, 1);
  assert.equal(existsSync(join(outside, 'services')), false);
});

test('restore replaces records from a previous container without signaling reused PIDs', async t => {
  const f = fixture(t, [service]);
  ok(f.run('start', 'dev')); ok(f.run('stop', 'dev'));
  const file = join(f.state, 'services', 'dev.json');
  const record = JSON.parse(readFileSync(file, 'utf8'));
  record.desired = true; record.incarnation = '0'.repeat(64);
  record.supervisor.pid = process.pid;
  writeFileSync(file, JSON.stringify(record));
  ok(f.run('restore'));
  assert.doesNotThrow(() => process.kill(process.pid, 0));
  assert.equal(JSON.parse(f.run('status').stdout)[0].state, 'running');
});

test('a failed service launcher cannot leave a detached writer behind', async t => {
  const childCode = 'require("fs").writeFileSync("daemon.pid",String(process.pid));setInterval(()=>{},1000)';
  const f = fixture(t, [{ ...service, argv: [process.execPath, '-e', `require('child_process').spawn(process.execPath,['-e',${JSON.stringify(childCode)}],{detached:true,stdio:'ignore'});setTimeout(()=>process.exit(1),100)`] }]);
  const result = f.run('start', 'dev');
  assert.ok(result.status === 0 || result.status === 1);
  await sleep(500);
  const pid = Number(readFileSync(join(f.root, 'daemon.pid'), 'utf8'));
  t.after(() => { try { process.kill(pid, 'SIGTERM'); } catch {} });
  ok(f.run('stop'));
  assert.throws(() => process.kill(pid, 0), 'failed launcher left an untracked child');
});

test('foreground cancellation returns 130 and stops its child', async t => {
  const f = fixture(t, [task('console.log(process.pid); setInterval(() => {}, 1000)')]);
  const child = spawn(process.execPath, [runner, ...f.args, 'run', 'test'], { stdio: ['ignore', 'pipe', 'pipe'] });
  let output = ''; child.stdout.on('data', data => { output += data; });
  for (let i = 0; i < 100 && !output.trim(); i++) await sleep(20);
  assert.match(output.trim(), /^\d+$/);
  child.kill('SIGINT');
  const code = await new Promise(resolve => child.once('exit', resolve));
  assert.equal(code, 130);
  assert.throws(() => process.kill(Number(output.trim()), 0));
});
