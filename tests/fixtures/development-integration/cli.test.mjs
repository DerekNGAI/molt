import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { after, test } from 'node:test';

const root = process.env.MOLT_DEVELOPMENT_SOURCE;
const tmp = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'molt-combined-'));
const home = path.join(tmp, 'home');
const cli = path.join(home, 'bin/molt');
const env = { ...process.env, MOLT_HOME: home, MOLT_LOCAL: '0', GIT_CEILING_DIRECTORIES: tmp };
fs.mkdirSync(home);
fs.cpSync(path.join(root, 'bin'), path.join(home, 'bin'), { recursive: true });
fs.cpSync(path.join(root, 'shims'), path.join(home, 'shims'), { recursive: true });
fs.symlinkSync(process.env.MOLT_DEVELOPMENT_TEST_BINARY, path.join(home, 'bin/molt-tui'));
fs.writeFileSync(path.join(home, '.install-manifest'), `FORMAT=2\nROOT=${home}\nINSTALL_ID=0123456789abcdef0123456789abcdef\n`);
fs.writeFileSync(path.join(home, 'config'), 'MOLT_HOST=fixture-vm\n');
after(() => fs.rmSync(tmp, { recursive: true, force: true }));
function run(command, args = [], options = {}) {
  return spawnSync(command, args, { encoding: 'utf8', env, ...options });
}
function ok(result) {
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return result.stdout.trim();
}
const repos = ['one', 'two'].map(name => {
  const repo = path.join(tmp, name);
  fs.mkdirSync(repo);
  ok(run('git', ['-C', repo, 'init', '-q']));
  ok(run('bash', [cli, 'register', repo]));
  return { repo, id: ok(run('bash', [cli, 'project-id', repo])) };
});
function shell(body) {
  return run('bash', ['-c', `source "$0" help >/dev/null\n${body}`, cli]);
}

test('real main CLI observes two unprepared repositories without mutation', () => {
  for (const { repo, id } of repos) {
    const state = path.join(home, 'projects', id);
    const before = fs.readdirSync(state);
    const status = JSON.parse(ok(run('bash', [cli, 'dev', `@${id}`, 'status', '--json'])));
    assert.equal(status.project_id, id);
    assert.equal(status.environment.state, 'unknown');
    assert.deepEqual(status.ports, []);
    assert.deepEqual(JSON.parse(ok(run('bash', [cli, 'dev', repo, 'ports', '--json']))), []);
    assert.deepEqual(fs.readdirSync(state), before);
    assert.equal(fs.existsSync(path.join(repo, '.molt')), false);
    assert.equal(fs.existsSync(path.join(repo, 'devenv.nix')), false);
    assert.equal(ok(run('bash', [cli, 'setup-state', `@${id}`])), 'untouched');
  }
});

test('public dev syntax rejects extra flags and preserves cancellation exit', () => {
  const ref = `@${repos[0].id}`;
  for (const args of [[], [ref], [ref, 'status'], [ref, 'start', '--json'], [ref, 'android', 'reset']]) {
    assert.equal(run('bash', [cli, 'dev', ...args]).status, 2, args.join(' '));
  }
  assert.equal(shell(`development_prepare() { return 130; }; main dev @${repos[0].id} prepare`).status, 130);
});

test('recorded development work makes offline removal require a warning', () => {
  const state = path.join(home, 'projects', repos[1].id);
  fs.writeFileSync(path.join(state, 'development.json'), '{}');
  try {
    assert.equal(ok(run('bash', [cli, 'setup-state', `@${repos[1].id}`])), 'started');
  } finally { fs.unlinkSync(path.join(state, 'development.json')); }
});

test('reuse readiness restores services after the OpenCode forward', () => {
  const result = shell(`
    load_project @${repos[0].id}
    remote_run() { printf true; }; start_sync() { :; }; wait_opencode_ready() { :; }
    forward_opencode_port() { printf 'forward\\n'; }
    development_workspace_ready() { printf 'development\\n'; }
    startup_progress() { :; }; save_project() { :; }
    reuse_opencode_server
  `);
  assert.equal(ok(result), 'forward\ndevelopment');
});

test('fresh and already-active startup both restore development after readiness', () => {
  for (const active of [false, true]) {
    const result = shell(`
      load_project @${repos[0].id}
      PROJECT_ACTIVE=${active ? 1 : 0}; PROJECT_RUNTIME_VERSION="$MOLT_RUNTIME_VERSION"
      PROJECT_SETUP_WORK=${tmp}; PROJECT_REMOTE_HOME=/fixture
      ssh_up() { :; }; prepare_opencode_version() { :; }; molt_owned_home() { :; }
      cmd_setup() { :; }; load_project() { :; }; set_remote_paths() { :; }
      prepare_project_dirs() { :; }; start_sync() { :; }; sync_opencode_config() { :; }
      build_project_image() { :; }; sync_password() { :; }; ensure_container() { :; }
      wait_opencode_ready() { printf 'ready\\n'; }
      forward_opencode_port() { printf 'forward\\n'; }
      development_workspace_ready() { printf 'development\\n'; }
      startup_progress() { :; }; save_project() { :; }
      ensure_project_container_locked
    `);
    assert.equal(ok(result), 'ready\nforward\ndevelopment');
  }
});

test('stop fails before stopping a writer when the development hook fails', () => {
  const result = shell(`
    load_project @${repos[0].id}; PROJECT_ACTIVE=1
    development_stop_project() { printf 'development\\n'; return 1; }
    stop_project_writer() { printf 'WRITER STOPPED\\n'; }
    stop_loaded_project
  `);
  assert.equal(result.status, 1);
  assert.equal(result.stdout.trim(), 'development');
});

test('project cleanup failure preserves registration and synchronization', () => {
  const result = shell(`
    load_project @${repos[0].id}; PROJECT_SETUP_STATE=complete
    molt_stop_workers() { :; }
    load_project_state() { PROJECT_SETUP_STATE=complete; }
    development_cleanup_project() { printf 'development\\n'; return 1; }
    stop_loaded_project() { :; }
    terminate_project_sync() { printf 'SYNC TERMINATED\\n'; }
    cleanup_project_remote() { printf 'REMOTE DELETED\\n'; }
    reset_loaded_project
  `);
  assert.equal(result.status, 1);
  assert.equal(result.stdout.trim(), 'development');
  assert.equal(fs.existsSync(path.join(home, 'projects', repos[0].id, 'path')), true);
});

test('local shutdown stops development helpers before closing SSH masters', () => {
  const result = shell(`
    molt_stop_workers() { :; }; molt_stop_daemon() { :; }
    development_local_down() { printf 'development\\n'; return 1; }
    main local-down
  `);
  assert.equal(result.status, 1);
  assert.equal(result.stdout.trim(), 'development');
});

test('shared cleanup failure retains the host retry record and never removes its root', () => {
  const record = path.join(home, 'state/remotes/test');
  fs.mkdirSync(record, { recursive: true });
  fs.writeFileSync(path.join(record, 'host'), 'fixture-vm\n');
  fs.writeFileSync(path.join(record, 'root'), '/fixture\n');
  try {
    const result = shell(`
      development_cleanup_shared() { printf '%s:%s\\n' "$PROJECT_REMOTE_HOME" "$PROJECT_ID"; return 1; }
      remote_script() { printf 'ROOT REMOVED\\n'; }
      main remove-remote-roots
    `);
    assert.equal(result.status, 1);
    assert.equal(result.stdout.trim(), '/fixture:000000000000');
    assert.equal(fs.existsSync(path.join(record, 'root')), true);
  } finally { fs.rmSync(record, { recursive: true }); }
});

test('inventory includes development records and exact non-OpenCode endpoints', () => {
  const { id } = repos[0];
  const state = path.join(home, 'projects', id);
  fs.writeFileSync(path.join(state, 'development.json'), JSON.stringify({ version: 1,
    owner: '0123456789abcdef0123456789abcdef', project_id: id, resources: ['/owned/staging/output'] }));
  fs.writeFileSync(path.join(state, 'forwards'), 'app:web\tfixture-vm\t3001\t31000\tactive\tunknown\n');
  try {
    const inventory = ok(run('bash', [cli, 'cleanup-inventory']));
    assert.match(inventory, /recorded resource: \/owned\/staging\/output/);
    assert.match(inventory, /app:web tunnel: fixture-vm 127\.0\.0\.1:3001 -> 127\.0\.0\.1:31000/);
  } finally {
    fs.unlinkSync(path.join(state, 'development.json'));
    fs.unlinkSync(path.join(state, 'forwards'));
  }
});

test('menu shim selects nearest project, honors local mode, and avoids recursion', () => {
  const shim = path.join(home, 'shims/menu');
  assert.equal(fs.existsSync(shim), true, 'local menu shim is missing');
  const fallback = path.join(tmp, 'fallback');
  fs.mkdirSync(fallback);
  fs.writeFileSync(path.join(fallback, 'menu'), '#!/bin/sh\nprintf "fallback:%s\\n" "$*"\nexit 7\n', { mode: 0o755 });
  const shimEnv = { ...env, PATH: `${home}/shims:${fallback}:${process.env.PATH}` };
  const local = run('bash', [shim, 'literal argument'], { cwd: repos[0].repo, env: { ...shimEnv, MOLT_LOCAL: '1' } });
  assert.equal(local.status, 7);
  assert.equal(local.stdout.trim(), 'fallback:literal argument');
  const outside = run('bash', [shim], { cwd: tmp, env: shimEnv });
  assert.equal(outside.status, 7);
  const other = path.join(tmp, 'other-installation');
  fs.mkdirSync(path.join(other, 'shims'), { recursive: true });
  fs.cpSync(path.join(home, 'bin'), path.join(other, 'bin'), { recursive: true });
  fs.copyFileSync(shim, path.join(other, 'shims/menu'));
  fs.chmodSync(path.join(other, 'shims/menu'), 0o755);
  const twoInstallations = run('bash', [shim], { cwd: tmp, timeout: 2000,
    env: { ...shimEnv, PATH: `${home}/shims:${other}/shims:${fallback}:${process.env.PATH}` } });
  assert.equal(twoInstallations.status, 7, 'multiple Molt shims must not recurse');
  const noFallback = run('bash', [shim], { cwd: tmp, env: { ...env, PATH: `${home}/shims:/usr/bin:/bin` } });
  assert.equal(noFallback.status, 127);
  assert.match(noFallback.stderr, /menu.*unavailable/i);
  const registered = run('bash', [shim], { cwd: repos[0].repo, env: shimEnv });
  assert.equal(registered.status, 1);
  assert.match(registered.stderr, /interactive terminal/);
  assert.equal(registered.stdout, '');
});
