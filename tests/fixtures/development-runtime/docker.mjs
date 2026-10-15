#!/usr/bin/env node
// Docker/AI double only: the real controller owns snapshots, revisions and promotion.
import * as fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
const root = process.env.MOLT_FIXTURE_ROOT, owner = process.env.MOLT_FIXTURE_OWNER, project = process.env.MOLT_FIXTURE_PROJECT;
const file = path.join(root, 'docker-fixture.json');
let state = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file)) : { images: {}, containers: {} };
const args = process.argv.slice(2), last = args.at(-1);
const digest = input => `sha256:${createHash('sha256').update(input).digest('hex')}`;
const base = `molt-env-${owner.slice(0, 8)}-${project}:latest`, workspace = `molt-${owner.slice(0, 8)}-${project}`;
const labels = { 'io.molt.installation': owner, 'io.molt.project': project, 'io.molt.role': 'workspace', 'io.molt.opencode': '1.18.34' };
const baseObject = { Id: digest(base), Architecture: 'arm64', Config: { Labels: labels }, Image: digest(base), State: { Running: true } };
function save() { fs.writeFileSync(file, JSON.stringify(state)); }
function option(flag) { return args[args.indexOf(flag) + 1]; }
function objectLabels() { const result = {}; args.forEach((arg, index) => { if (arg === '--label') { const [key, ...value] = args[index + 1].split('='); result[key] = value.join('='); } }); return result; }
if (args[0] === 'info') process.exit(0);
if (args[0] === 'pull') { const pin = last; state.images[pin] = { Id: digest(pin), Architecture: 'arm64', Config: { Labels: {} }, RepoTags: [], RepoDigests: [pin.slice(0, pin.indexOf('@')).replace(/:[^/:]+$/, '') + pin.slice(pin.indexOf('@'))] }; save(); process.exit(0); }
if (args[0] === 'inspect' || args[0] === 'image' && args[1] === 'inspect') {
  const names = args[0] === 'image' ? [last] : args.slice(1);
  const objects = names.map(name => name === workspace || name === base || name === digest(base) ? baseObject : state.images[name] || state.containers[name] || Object.values(state.images).find(object => object.Id === name));
  if (objects.some(object => !object)) process.exit(1);
  console.log(JSON.stringify(objects)); process.exit(0);
}
if (args.includes('ls') || args[0] === 'ps') { console.log(Object.keys(args[0] === 'image' ? state.images : state.containers).join('\n')); process.exit(0); }
if (args[0] === 'exec') {
  if (args.includes('/opt/opencode/opencode') && args.includes('run')) {
    if (process.env.MOLT_FIXTURE_AI_FAIL === '1') { console.error('synthetic provider secret'); process.exit(1); }
    if (process.env.MOLT_FIXTURE_AI_SIGNAL === '1') process.kill(process.pid, 'SIGTERM');
    if (process.env.MOLT_FIXTURE_AI_EMPTY === '1') process.exit(0);
    const containerDirectory = option('--workdir');
    const directory = containerDirectory.replace('/molt-cache', path.join(root, 'cache', project));
    const config = JSON.parse(args.find(arg => arg.startsWith('OPENCODE_CONFIG_CONTENT=')).slice('OPENCODE_CONFIG_CONTENT='.length));
    // OpenCode 1.19 checks read/edit paths relative to '/' for these snapshots without .git.
    function allowed(permission, tool, resource) {
      const rules = permission[tool] ?? permission['*'];
      if (typeof rules === 'string') return rules === 'allow';
      let action = permission['*'];
      for (const [pattern, value] of Object.entries(rules)) {
        const regex = new RegExp(`^${pattern.replace(/[.+^${}()|[\]\\]/gu, '\\$&').replace(/\*/gu, '.*').replace(/\?/gu, '.')}$`, 'su');
        if (regex.test(resource)) action = value;
      }
      return action === 'allow';
    }
    for (const permission of [config.permission, config.agent.build.permission]) {
      for (const name of ['', 'package.json', 'source.js', '.github/workflows/check.yml']) {
        assert.equal(allowed(permission, 'read', path.posix.relative('/', path.posix.join(containerDirectory, name))), true, `read denied: ${name || 'staging directory'}`);
      }
      for (const name of ['.molt/development.json', 'devenv.nix', 'devenv.yaml', 'devenv.lock', 'menu']) {
        assert.equal(allowed(permission, 'edit', path.posix.relative('/', `${containerDirectory}/${name}`)), !fs.existsSync(path.join(directory, name)), `incorrect edit permission: ${name}`);
      }
      for (const name of ['/workspace/source.js', '/molt-cache/data/opencode/auth.json', '/molt-config/opencode/opencode.json', `${containerDirectory}-other/package.json`]) {
        for (const tool of ['read', 'edit']) assert.equal(allowed(permission, tool, path.posix.relative('/', name)), false, `${tool} allowed outside staging: ${name}`);
      }
      assert.equal(allowed(permission, 'edit', path.posix.relative('/', `${containerDirectory}/source.js`)), false);
      for (const tool of ['bash', 'task', 'external_directory', 'question']) assert.equal(allowed(permission, tool, '*'), false, `${tool} allowed`);
    }
    fs.mkdirSync(path.join(directory, '.molt'), { recursive: true });
    const generated = {
      '.molt/development.json': JSON.stringify({ version: 1, name: 'Generated', actions: [], ports: [], android: { enabled: false } }),
      'devenv.nix': '{ pkgs, ... }: { packages = [ pkgs.nodejs_24 ]; }',
      'devenv.yaml': 'inputs:\n  nixpkgs:\n    url: github:cachix/devenv-nixpkgs/256551e45f6303e142ab4a98be1bf243feb77dc0\n',
    };
    for (const [name, contents] of Object.entries(generated)) if (!fs.existsSync(path.join(directory, name))) fs.writeFileSync(path.join(directory, name), contents);
    if (process.env.MOLT_FIXTURE_AI_EDIT === '1') fs.writeFileSync(path.join(directory, 'source.js'), 'AI changed existing source');
  } else if (args.includes('status')) console.log('[]');
  else if (args.includes('activity')) console.log('{"busy":false}');
  process.exit(0);
}
if (args[0] === 'run') {
  const pin = args.find(arg => arg.includes('@sha256:'));
  if (pin && !state.images[pin]) state.images[pin] = { Id: digest(pin), Architecture: 'arm64', Config: { Labels: {} }, RepoTags: [], RepoDigests: [pin.slice(0, pin.indexOf('@')).replace(/:[^/:]+$/, '') + pin.slice(pin.indexOf('@'))] };
  const name = option('--name'); if (name) { const image = args[args.indexOf('/bin/sh') - 1] || args.find(arg => arg.includes('@sha256:')); state.containers[name] = { Id: digest(name), Name: `/${name}`, Config: { Labels: objectLabels(), Image: image }, State: { Running: false }, Image: digest(args.join(' ')), Mounts: [] }; save(); }
  if (args.includes('/bin/sh') && args.some(arg => arg.includes('container build'))) {
    if (process.env.MOLT_FIXTURE_BUILD_FAIL === '1') process.exit(1);
    const mounts = args.filter((_arg, index) => args[index - 1] === '--mount');
    const parse = destination => mounts.find(value => value.includes(`target=${destination}`) || value.includes(`dst=${destination}`)).split(',').find(value => value.startsWith('source=') || value.startsWith('src=')).split('=').slice(1).join('=');
    const metadata = fs.readFileSync(path.join(parse('/workspace'), 'molt-build.json'));
    fs.writeFileSync(path.join(parse('/output'), 'environment.tar'), metadata);
    const revision = JSON.parse(metadata).revision, store = parse('/nix');
    const roots = path.join(store, 'var/nix/gcroots/molt', project, revision);
    fs.mkdirSync(roots, { recursive: true }); fs.writeFileSync(path.join(roots, 'owner.json'), JSON.stringify({ owner, project, revision }));
    const target = 'a'.repeat(32) + '-fixture'; fs.mkdirSync(path.join(store, 'store', target), { recursive: true }); fs.symlinkSync(`/nix/store/${target}`, path.join(roots, 'b'.repeat(32)));
  }
  process.exit(0);
}
if (args[0] === 'load') { const metadata = JSON.parse(fs.readFileSync(option('--input'))); const image = `${metadata.image}:${metadata.revision}`; state.images[image] = { Id: digest(image), Config: { Labels: {} }, Architecture: 'arm64' }; save(); process.exit(0); }
if (args[0] === 'build') { const image = option('--tag'); state.images[image] = { Id: digest(image), Config: { Labels: objectLabels() }, Architecture: 'arm64' }; save(); process.exit(0); }
if (args[0] === 'tag') { const object = args[1] === digest(base) ? baseObject : state.images[args[1]]; if (!object) process.exit(1); state.images[args[2]] = object; save(); process.exit(0); }
if (args[0] === 'rm') { delete state.containers[last]; save(); process.exit(0); }
if (args[0] === 'image' && args[1] === 'rm') { delete state.images[last]; save(); process.exit(0); }
if (args[0] === 'stop') { if (state.containers[last]) state.containers[last].State.Running = false; save(); process.exit(0); }
if (args[0] === 'logs') process.exit(0);
console.error(`Unexpected fixture docker command: ${args.join(' ')}`); process.exit(2);
