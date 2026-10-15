import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../../../', import.meta.url));
const owner = '0123456789abcdef0123456789abcdef', id = 'aaaaaaaaaaaa';
const spec = { version: 1, name: 'Environment', actions: [{ id: 'test', label: 'Tests', kind: 'task', argv: ['node', '--version'], cwd: '.' }], ports: [], android: { enabled: false } };
function fixture(t, missing = false) {
  const base = fs.realpathSync(fs.mkdtempSync(path.join(tmpdir(), 'molt-host.')));
  const root = path.join(base, 'remote with $literal'); const source = path.join(root, 'projects', id);
  const meta = path.join(root, 'meta', id, 'development'); const tools = path.join(base, 'tools');
  for (const name of [source, meta, tools, path.join(root, 'state'), path.join(root, 'auth')]) fs.mkdirSync(name, { recursive: true });
  fs.writeFileSync(path.join(root, '.install-manifest'), owner);
  fs.writeFileSync(path.join(source, 'package.json'), '{"scripts":{"test":"node --version"}}');
  fs.writeFileSync(path.join(source, '.env'), 'SECRET=never-snapshot');
  fs.writeFileSync(path.join(source, 'source.js'), 'original source');
  if (!missing) {
    fs.mkdirSync(path.join(source, '.molt')); fs.writeFileSync(path.join(source, '.molt/development.json'), JSON.stringify(spec));
    fs.writeFileSync(path.join(source, 'devenv.nix'), '{ pkgs, ... }: { packages = [ pkgs.nodejs_24 ]; }');
    fs.writeFileSync(path.join(source, 'devenv.yaml'), 'inputs:\n  nixpkgs:\n    url: github:cachix/devenv-nixpkgs/256551e45f6303e142ab4a98be1bf243feb77dc0\n');
  }
  fs.cpSync(path.join(repo, 'templates/development'), path.join(meta, 'templates'), { recursive: true });
  fs.copyFileSync(path.join(repo, 'development-tools.lock.json'), path.join(meta, 'development-tools.lock.json'));
  fs.writeFileSync(path.join(tools, 'docker'), `#!/bin/sh\nexec ${JSON.stringify(process.execPath)} ${JSON.stringify(path.join(repo, 'tests/fixtures/development-runtime/docker.mjs'))} "$@"\n`, { mode: 0o755 });
  const env = { ...process.env, PATH: `${tools}:${process.env.PATH}`, MOLT_FIXTURE_ROOT: root, MOLT_FIXTURE_OWNER: owner, MOLT_FIXTURE_PROJECT: id };
  const run = (command, args = [], input = '', extra = {}) => spawnSync(process.execPath, [path.join(repo, 'remote/development.mjs'), '--control', command, '--root', root, '--owner', owner, '--project', id, ...args], { input, encoding: 'utf8', env: { ...env, ...extra }, timeout: 20000 });
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  return { base, root, source, meta, run };
}
function ok(result) { assert.equal(result.status, 0, result.stderr); return JSON.parse(result.stdout); }

test('host status/cache are read-only and absent has no fabricated ready state', t => {
  const f = fixture(t);
  const before = fs.readdirSync(path.join(f.root, 'state'));
  assert.equal(ok(f.run('status')).environment.state, 'absent');
  assert.deepEqual(ok(f.run('cache')).items, []);
  assert.deepEqual(fs.readdirSync(path.join(f.root, 'state')), before);
});
test('missing configuration with no provider is blocked without modifying source', t => {
  const f = fixture(t, true);
  fs.writeFileSync(path.join(f.root, 'auth/auth.json'), '{}');
  const result = f.run('candidate'); assert.equal(result.status, 1); assert.match(result.stderr, /provider/i);
  assert.equal(fs.existsSync(path.join(f.source, 'devenv.nix')), false);
});
test('generation can read staging and write only missing configuration with relative permission paths', t => {
  const f = fixture(t, true);
  fs.writeFileSync(path.join(f.root, 'auth/auth.json'), '{"fixture":{"type":"api","key":"synthetic"}}');
  const candidate = ok(f.run('candidate'));
  assert.equal(candidate.profile.name, 'Generated');
  assert.equal(fs.existsSync(path.join(f.source, '.molt/development.json')), false);
});
test('generation keeps existing definitions read-only when another definition is missing', t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.root, 'auth/auth.json'), '{"fixture":{"type":"api","key":"synthetic"}}');
  fs.unlinkSync(path.join(f.source, 'devenv.yaml'));
  const candidate = ok(f.run('candidate'));
  assert.deepEqual(candidate.profile, spec);
  const snapshot = path.join(f.root, 'cache', id, 'development', 'staging', candidate.token, 'repo');
  assert.deepEqual(fs.readFileSync(path.join(snapshot, 'devenv.nix')), fs.readFileSync(path.join(f.source, 'devenv.nix')));
});
test('generation reports missing required files when the model exits without creating them', t => {
  const f = fixture(t, true);
  fs.writeFileSync(path.join(f.root, 'auth/auth.json'), '{"fixture":{"type":"api","key":"synthetic"}}');
  const result = f.run('candidate', [], '', { MOLT_FIXTURE_AI_EMPTY: '1' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /missing required files: \.molt\/development\.json, devenv\.nix, devenv\.yaml/);
  assert.match(result.stderr, /source and working runtime preserved/);
  const ledger = JSON.parse(fs.readFileSync(path.join(f.root, 'state/development', id, 'resources.json')));
  assert.equal(Object.values(ledger.stages)[0].state, 'failed');
  assert.equal(fs.existsSync(path.join(f.source, '.molt/development.json')), false);
});
test('generation reports process failures without exposing provider output', t => {
  const f = fixture(t, true);
  fs.writeFileSync(path.join(f.root, 'auth/auth.json'), '{"fixture":{"type":"api","key":"synthetic"}}');
  for (const [env, reason] of [['MOLT_FIXTURE_AI_FAIL', /exited with code 1/], ['MOLT_FIXTURE_AI_SIGNAL', /terminated by SIGTERM/]]) {
    const result = f.run('candidate', [], '', { [env]: '1' });
    assert.equal(result.status, 1);
    assert.match(result.stderr, reason);
    assert.match(result.stderr, /source and working runtime preserved/);
    assert.doesNotMatch(result.stdout + result.stderr, /synthetic provider secret/);
  }
});
test('existing definitions are preserved and unchanged prepare reuses the revision', t => {
  const f = fixture(t); const before = fs.readFileSync(path.join(f.source, 'devenv.nix'));
  const candidate = ok(f.run('candidate'));
  const snapshot = path.join(f.root, 'cache', id, 'development', 'staging', candidate.token, 'repo');
  assert.equal(fs.existsSync(path.join(snapshot, '.env')), false);
  const built = ok(f.run('build', [candidate.token], JSON.stringify(candidate.profile)));
  ok(f.run('promote', [candidate.token]));
  assert.deepEqual(fs.readFileSync(path.join(f.source, 'devenv.nix')), before);
  assert.equal(ok(f.run('candidate')).revision, built.revision);
  assert.equal(ok(f.run('candidate')).reused, true);
});
test('AI failure, unexpected edits and build failure preserve source and working environment', t => {
  const f = fixture(t, true); fs.writeFileSync(path.join(f.root, 'auth/auth.json'), '{"fixture":{"type":"api","key":"synthetic"}}');
  assert.equal(f.run('candidate', [], '', { MOLT_FIXTURE_AI_FAIL: '1' }).status, 1);
  assert.equal(f.run('candidate', [], '', { MOLT_FIXTURE_AI_EDIT: '1' }).status, 1);
  const candidate = ok(f.run('candidate'));
  assert.equal(f.run('build', [candidate.token], JSON.stringify(candidate.profile), { MOLT_FIXTURE_BUILD_FAIL: '1' }).status, 1);
  assert.equal(fs.existsSync(path.join(f.source, '.molt/development.json')), false);
  assert.equal(fs.readFileSync(path.join(f.source, 'source.js'), 'utf8'), 'original source');
});
test('promotion rejects concurrent changes and retains the candidate for retry', t => {
  const f = fixture(t); const candidate = ok(f.run('candidate'));
  ok(f.run('build', [candidate.token], JSON.stringify(candidate.profile)));
  fs.writeFileSync(path.join(f.source, 'source.js'), 'concurrent edit');
  assert.equal(f.run('promote', [candidate.token]).status, 1);
  assert.equal(fs.readFileSync(path.join(f.source, 'source.js'), 'utf8'), 'concurrent edit');
  assert.equal(fs.existsSync(path.join(f.root, 'cache', id, 'development', 'staging', candidate.token)), true);
});
test('cache requires the displayed revision and excludes Android/database/foreign state', t => {
  const f = fixture(t); const candidate = ok(f.run('candidate'));
  ok(f.run('build', [candidate.token], JSON.stringify(candidate.profile)));
  const preview = ok(f.run('cache'));
  assert.equal(preview.items.some(item => /android|auth|database/.test(item.path)), false);
  const stage = path.join(f.root, 'cache', id, 'development', 'staging', candidate.token);
  fs.writeFileSync(path.join(stage, 'new-output'), 'changed inventory');
  assert.equal(f.run('clean-cache', [preview.revision]).status, 1);
  assert.equal(fs.existsSync(stage), true);
  assert.equal(f.run('clean-cache', ['0'.repeat(64)]).status, 1);
});
test('status and cache count Nix symlinks without following external or missing targets', t => {
  const f = fixture(t); const candidate = ok(f.run('candidate'));
  const stage = path.join(f.root, 'cache', id, 'development', 'staging', candidate.token);
  const before = ok(f.run('cache')).items.find(item => item.path === stage).bytes;
  const outside = path.join(f.base, 'outside'); fs.mkdirSync(outside);
  fs.writeFileSync(path.join(outside, 'private-data'), Buffer.alloc(1024 * 1024));
  const links = [path.join(stage, 'nix-result'), path.join(stage, 'missing-result')];
  fs.symlinkSync(outside, links[0]);
  fs.symlinkSync('/nix/store/nonexistent-fixture', links[1]);
  const preview = ok(f.run('cache'));
  assert.equal(preview.items.find(item => item.path === stage).bytes, before + links.reduce((sum, file) => sum + fs.lstatSync(file).size, 0));
  assert.equal(ok(f.run('status')).environment.state, 'absent');
  ok(f.run('clean-cache', [preview.revision]));
  assert.equal(fs.existsSync(path.join(outside, 'private-data')), true);
});
test('foreign markers and redirected owned paths prevent cleanup', t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.root, '.install-manifest'), 'foreign');
  assert.equal(f.run('cleanup').status, 1);
  fs.writeFileSync(path.join(f.root, '.install-manifest'), owner);
  fs.mkdirSync(path.join(f.base, 'outside')); fs.symlinkSync(path.join(f.base, 'outside'), path.join(f.root, 'state/development'));
  assert.equal(f.run('cleanup').status, 1);
  assert.equal(fs.existsSync(path.join(f.source, 'source.js')), true);
});
test('stale build output and its owned Nix roots can be cleaned with a fresh preview', t => {
  const f = fixture(t); const candidate = ok(f.run('candidate'));
  ok(f.run('build', [candidate.token], JSON.stringify(candidate.profile)));
  const preview = ok(f.run('cache'));
  assert.ok(preview.items.some(item => item.kind === 'nix-root'), 'no private Nix root in preview');
  ok(f.run('clean-cache', [preview.revision]));
  assert.equal(ok(f.run('cache')).items.length, 0);
  assert.equal(fs.readFileSync(path.join(f.source, 'source.js'), 'utf8'), 'original source');
});
