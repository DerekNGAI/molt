#!/usr/bin/env node
import { spawn, execFileSync } from 'node:child_process';
import * as fs from 'node:fs';
import path from 'node:path';
import { createHash, randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const script = fs.realpathSync(fileURLToPath(import.meta.url));
const idPattern = /^[a-z][a-z0-9-]{0,31}$/;
const digestPattern = /^[a-f0-9]{64}$/;
const architecture = process.arch === 'x64' ? 'amd64' : process.arch;
const hash = value => createHash('sha256').update(value).digest('hex');
function canonical(value) { return Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value; }
const jsonHash = value => hash(JSON.stringify(canonical(value)));
const json = value => process.stdout.write(`${JSON.stringify(value)}\n`);
const error = (message, code = 1) => Object.assign(new Error(message), { exitCode: code });
function checked(condition, message, code = 1) { if (!condition) throw error(message, code); }

// Check every component, including missing leaves, before a file operation.
function safePath(name, missing = true) {
  checked(typeof name === 'string' && path.isAbsolute(name) && path.normalize(name) === name && name !== '/' && !/[\x00-\x1f\x7f]/u.test(name), 'unsafe development path');
  let current = '/';
  for (const part of name.slice(1).split('/')) {
    current = path.join(current, part);
    try { checked(!fs.lstatSync(current).isSymbolicLink(), 'redirected development path'); }
    catch (e) { if (e.code !== 'ENOENT' || !missing) throw e; }
  }
  return name;
}
function readJSON(name, fallback, allowNull = true) {
  safePath(name);
  try {
    checked(fs.statSync(name).isFile() && fs.statSync(name).size <= 64 * 1024 * 1024, 'invalid development state file');
    return strictJSON(fs.readFileSync(name), allowNull);
  } catch (e) { if (e.code === 'ENOENT') return fallback; throw e; }
}
function writeJSON(name, value) {
  safePath(name);
  const temporary = `${name}.${randomBytes(8).toString('hex')}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(value)}\n`, { flag: 'wx', mode: 0o600 });
  fs.renameSync(temporary, name);
}
function directory(name) { safePath(name); fs.mkdirSync(name, { recursive: true, mode: 0o700 }); }

function strictJSON(bytes, allowNull = false) {
  checked(bytes.length <= 64 * 1024 * 1024, 'development JSON too large', 2);
  const source = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  let offset = 0;
  const whitespace = () => { while (/[ \t\r\n]/u.test(source[offset] ?? '') && offset < source.length) offset++; };
  function string() {
    const start = offset++;
    while (offset < source.length) {
      const char = source[offset++];
      if (char === '\\') offset++;
      else if (char === '"') return JSON.parse(source.slice(start, offset));
    }
    throw error('invalid JSON string', 2);
  }
  function value(depth = 0) {
    checked(depth <= 16, 'development JSON too deeply nested', 2); whitespace();
    if (source[offset] === '"') return string();
    if (source[offset] === '{' || source[offset] === '[') {
      const object = source[offset++] === '{'; const end = object ? '}' : ']';
      const output = object ? Object.create(null) : []; whitespace();
      while (source[offset] !== end) {
        if (object) {
          checked(source[offset] === '"', 'invalid JSON key', 2);
          const key = string(); whitespace();
          checked(!Object.hasOwn(output, key) && source[offset++] === ':', 'duplicate or invalid JSON key', 2);
          output[key] = value(depth + 1);
        } else output.push(value(depth + 1));
        whitespace(); if (source[offset] === end) break;
        checked(source[offset++] === ',', 'invalid JSON delimiter', 2); whitespace();
        checked(source[offset] !== end, 'trailing JSON comma', 2);
      }
      checked(source[offset++] === end, 'invalid JSON object', 2); return output;
    }
    const match = /^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/u.exec(source.slice(offset));
    checked(match, 'invalid JSON value', 2); offset += match[0].length;
    const result = JSON.parse(match[0]); checked(allowNull || result !== null, 'null development field', 2);
    if (typeof result === 'number') checked(Number.isSafeInteger(result) && /^-?(?:0|[1-9]\d*)$/u.test(match[0]), 'development numbers must be integers', 2);
    return result;
  }
  try { const result = value(); whitespace(); checked(offset === source.length, 'trailing JSON data', 2); return result; }
  catch (e) { throw error(e.message, 2); }
}
function fields(value, allowed) {
  checked(value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).every(key => allowed.includes(key)), 'unknown development field', 2);
}
function text(value, maximum) { return typeof value === 'string' && value.trim() !== '' && [...value].length <= maximum && !/\p{Cc}/u.test(value); }
function profileAt(profilePath, root) {
  const spec = readJSON(safePath(profilePath, false), undefined, false); fields(spec, ['version', 'name', 'actions', 'ports', 'android']);
  checked(spec.version === 1 && text(spec.name, 80), 'invalid development profile identity', 2);
  spec.actions ??= []; spec.ports ??= []; spec.android ??= { enabled: false };
  fields(spec.android, ['enabled']); spec.android.enabled ??= false;
  checked(typeof spec.android.enabled === 'boolean' && Array.isArray(spec.actions) && spec.actions.length <= 32 && Array.isArray(spec.ports) && spec.ports.length <= 16, 'invalid development profile entries', 2);
  const actions = new Map();
  for (const action of spec.actions) {
    fields(action, ['id', 'label', 'kind', 'argv', 'cwd']); action.cwd ??= '.';
    checked(typeof action.id === 'string' && idPattern.test(action.id) && !actions.has(action.id) && text(action.label, 80) && ['task', 'service'].includes(action.kind) && Array.isArray(action.argv) && action.argv.length > 0 && action.argv.length <= 64 && action.argv.every(arg => typeof arg === 'string' && Buffer.byteLength(arg) > 0 && Buffer.byteLength(arg) <= 4096 && !/[\0\r\n]/u.test(arg)) && text(action.cwd, 4096) && !path.isAbsolute(action.cwd), 'invalid development action', 2);
    const cwd = path.resolve(root, action.cwd);
    checked(cwd === root || cwd.startsWith(`${root}/`), 'action cwd escapes repository', 2);
    let resolved; try { resolved = fs.realpathSync(cwd); } catch { throw error('action cwd is unavailable', 2); }
    checked((resolved === root || resolved.startsWith(`${root}/`)) && fs.statSync(resolved).isDirectory(), 'action cwd escapes repository', 2);
    action.cwd = path.relative(root, cwd) || '.'; actions.set(action.id, action);
  }
  const ports = new Set(), ids = new Set();
  for (const port of spec.ports) {
    fields(port, ['id', 'label', 'service', 'container_port', 'local_port', 'scheme']);
    checked(typeof port.id === 'string' && idPattern.test(port.id) && !ids.has(port.id) && text(port.label, 80) && typeof port.service === 'string' && actions.get(port.service)?.kind === 'service' && Number.isInteger(port.container_port) && port.container_port > 0 && port.container_port <= 65535 && port.container_port !== 4096 && !ports.has(port.container_port) && Number.isInteger(port.local_port) && port.local_port >= 1024 && port.local_port <= 65535 && ['http', 'https'].includes(port.scheme), 'invalid development port', 2);
    ports.add(port.container_port); ids.add(port.id);
  }
  return spec;
}

function identity(pid) {
  if (!Number.isInteger(pid) || pid <= 1) return null;
  try {
    if (process.platform === 'linux') {
      const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8'); const fields = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
      if (fields[0] === 'Z') return null;
      return { pid, start: `${fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim()}:${fs.readlinkSync('/proc/self/ns/pid')}:${fields[19]}`, executable: fs.realpathSync(`/proc/${pid}/exe`), command: hash(fs.readFileSync(`/proc/${pid}/cmdline`)) };
    }
    const start = execFileSync('ps', ['-p', String(pid), '-o', 'lstart='], { encoding: 'utf8' }).trim();
    const executable = execFileSync('ps', ['-p', String(pid), '-o', 'comm='], { encoding: 'utf8' }).trim();
    const command = execFileSync('ps', ['-ww', '-p', String(pid), '-o', 'command='], { maxBuffer: 1024 * 1024 });
    if (!start || !executable || executable.startsWith('(')) return null;
    return { pid, start, executable: fs.realpathSync(executable), command: hash(command) };
  } catch { return null; }
}
function sameProcess(record) {
  if (!record) return false;
  const current = identity(record.pid);
  return current && ['start', 'executable', 'command'].every(key => current[key] === record[key]);
}
function signal(record, signal, group = false) {
  const live = identity(record?.pid); if (!live) return;
  checked(sameProcess(record), 'process identity mismatch; record retained');
  process.kill(group ? -record.pid : record.pid, signal);
}
function serviceMembers(token) {
  checked(/^[a-f0-9]{32}$/u.test(token), 'invalid service ownership token');
  if (process.platform !== 'linux') {
    const processes = execFileSync('ps', ['eww', '-ax', '-o', 'pid=', '-o', 'command='], { encoding: 'utf8', timeout: 3000, maxBuffer: 8 * 1024 * 1024 });
    return processes.split('\n').filter(line => new RegExp(`(?:^|\\s)MOLT_DEVELOPMENT_SERVICE_TOKEN=${token}(?:\\s|$)`, 'u').test(line)).map(line => identity(Number(/^\s*(\d+)/u.exec(line)?.[1]))).filter(Boolean);
  }
  const pids = fs.readdirSync('/proc').filter(name => /^\d+$/u.test(name));
  checked(pids.length <= 8192, 'service process observation exceeds bound');
  const members = [];
  for (const value of pids) {
    const pid = Number(value); if (pid === process.pid) continue;
    try {
      const environment = fs.readFileSync(`/proc/${pid}/environ`, 'utf8');
      if (environment.split('\0').includes(`MOLT_DEVELOPMENT_SERVICE_TOKEN=${token}`)) { const processIdentity = identity(pid); if (processIdentity) members.push(processIdentity); }
    } catch {}
  }
  return members;
}
async function stopMembers(token) {
  let members = serviceMembers(token);
  for (const member of members) signal(member, 'SIGTERM');
  for (let attempt = 0; attempt < 20 && members.some(sameProcess); attempt++) await sleep(50);
  members = serviceMembers(token); for (const member of members) signal(member, 'SIGKILL');
}
async function lock(name, operation) {
  safePath(name); let acquired = false;
  for (let attempt = 0; attempt < 300; attempt++) {
    try { fs.mkdirSync(name, { mode: 0o700 }); writeJSON(path.join(name, 'owner.json'), identity(process.pid)); acquired = true; break; }
    catch (e) {
      if (e.code !== 'EEXIST') throw e;
      const previous = readJSON(path.join(name, 'owner.json'));
      if (previous && Number.isInteger(previous.pid) && typeof previous.start === 'string' && digestPattern.test(previous.command) && !sameProcess(previous)) { fs.unlinkSync(path.join(name, 'owner.json')); fs.rmdirSync(name); }
      else await sleep(50);
    }
  }
  checked(acquired, 'development resource is locked; retry shortly');
  try { return await operation(); }
  finally { fs.unlinkSync(path.join(name, 'owner.json')); fs.rmdirSync(name); }
}

async function runtime(args) {
  checked(args.length >= 7 && args[0] === '--root' && args[2] === '--state' && args[4] === '--profile', 'usage: development.mjs --root <repo> --state <state> --profile <profile> <list|run|start|stop|status|logs> [action-id]', 2);
  const [root, state, profilePath, command, actionID, token] = [args[1], args[3], args[5], args[6], args[7], args[8]];
  safePath(root, false); safePath(state); safePath(profilePath, false);
  checked(fs.statSync(root).isDirectory(), 'workspace root must be a directory', 2);
  checked(state !== root && !state.startsWith(`${root}/`), 'runtime state must be outside source');
  checked(['list', 'run', 'start', 'stop', 'status', 'logs', 'restore', 'activity', '--supervise'].includes(command) && args.length <= (command === '--supervise' ? 9 : 8), 'invalid runner command', 2);
  const spec = profileAt(profilePath, root); const revision = hash(JSON.stringify(spec));
  const incarnation = process.platform === 'linux' ? hash(fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8') + fs.readlinkSync('/proc/self/ns/pid')) : hash(execFileSync('sysctl', ['-n', 'kern.boottime']));
  const ownerPath = path.join(state, 'runtime-owner.json');
  const owner = readJSON(ownerPath);
  if (owner) checked(owner.version === 1 && owner.root === root && owner.profile === profilePath, 'runtime state ownership mismatch');
  function claim() {
    directory(state);
    if (!owner && !readJSON(ownerPath)) writeJSON(ownerPath, { version: 1, root, profile: profilePath });
    for (const name of ['services', 'logs', 'tasks']) directory(path.join(state, name));
  }
  const recordPath = id => path.join(state, 'services', `${id}.json`);
  function recordFor(id) {
    const record = readJSON(recordPath(id));
    if (record) checked(record.version === 1 && record.id === id && /^[a-f0-9]{32}$/u.test(record.token) && typeof record.desired === 'boolean' && digestPattern.test(record.revision), 'invalid service ownership record');
    return record;
  }
  function selected(kind) {
    if (actionID) checked(idPattern.test(actionID) && spec.actions.some(action => action.id === actionID && (!kind || action.kind === kind)), 'unknown action or action kind', 2);
    return spec.actions.filter(action => (!kind || action.kind === kind) && (!actionID || action.id === actionID));
  }
  function observed(action) {
    try {
      const record = recordFor(action.id);
      if (!record) return { id: action.id, label: action.label, state: 'stopped', reason: '' };
      if (record.incarnation !== incarnation) return { id: action.id, label: action.label, state: record.desired ? 'failed' : 'stopped', reason: record.desired ? 'Service belongs to a previous container; reconnect to restore it' : '' };
      let state = record.state, reason = record.reason ?? '';
      if (identity(record.supervisor?.pid) && !sameProcess(record.supervisor)) { state = 'unknown'; reason = 'Service process identity mismatch'; }
      else if (sameProcess(record.supervisor) && sameProcess(record.child)) state = 'running';
      else if (record.desired && state !== 'failed') { state = 'failed'; reason = 'Service exited; start or reconnect to retry'; }
      else if (!record.desired) state = 'stopped';
      return { id: action.id, label: action.label, state, reason };
    } catch { return { id: action.id, label: action.label, state: 'unknown', reason: 'Service ownership record unavailable' }; }
  }
  async function start(action) {
    let record = recordFor(action.id);
    if (record && record.incarnation !== incarnation) {
      checked(!sameProcess(record.supervisor) && !sameProcess(record.child), 'live service incarnation mismatch');
      record = undefined;
    }
    if (identity(record?.supervisor?.pid)) {
      checked(sameProcess(record.supervisor), 'service process identity mismatch');
      checked(record.revision === revision, 'service configuration changed; explicitly stop before starting');
      if (sameProcess(record.child)) return;
      throw error('service is still starting; retry shortly');
    }
    const token = randomBytes(16).toString('hex');
    record = { version: 1, id: action.id, token, revision, incarnation, desired: true, state: 'starting', reason: '', supervisor: null, child: null };
    writeJSON(recordPath(action.id), record);
    const supervisor = spawn(process.execPath, [script, ...args.slice(0, 6), '--supervise', action.id, token], { detached: true, stdio: 'ignore' });
    await new Promise((resolve, reject) => { supervisor.once('spawn', resolve); supervisor.once('error', reject); }); supervisor.unref();
    for (let attempt = 0; attempt < 100; attempt++) {
      record = recordFor(action.id);
      if (record.state === 'failed') throw error('service could not start; inspect its logs');
      if (sameProcess(record.supervisor) && sameProcess(record.child)) return;
      await sleep(30);
    }
    throw error('service startup timed out; ownership record retained');
  }
  async function stop(id) {
    const record = recordFor(id); if (!record) return;
    if (record.incarnation !== incarnation) {
      checked(!sameProcess(record.supervisor) && !sameProcess(record.child), 'live service incarnation mismatch');
      record.desired = false; record.state = 'stopped'; record.reason = ''; writeJSON(recordPath(id), record); return;
    }
    if (identity(record.supervisor?.pid)) checked(sameProcess(record.supervisor), 'service process identity mismatch; record retained');
    if (identity(record.child?.pid)) checked(sameProcess(record.child), 'service child identity mismatch; record retained');
    record.desired = false; writeJSON(recordPath(id), record);
    signal(record.supervisor, 'SIGTERM');
    for (let attempt = 0; attempt < 100 && sameProcess(record.supervisor); attempt++) await sleep(30);
    if (sameProcess(record.child)) signal(record.child, 'SIGKILL', true);
    if (sameProcess(record.supervisor)) signal(record.supervisor, 'SIGKILL');
    await stopMembers(record.token);
    checked(!sameProcess(record.child) && !sameProcess(record.supervisor), 'service did not stop; retry records retained');
    const final = recordFor(id); final.state = 'stopped'; final.reason = ''; writeJSON(recordPath(id), final);
  }
  async function supervise(action) {
    let record = recordFor(action.id);
    checked(record?.token === token && record.desired && record.revision === revision, 'stale supervisor intent');
    record.supervisor = identity(process.pid); writeJSON(recordPath(action.id), record);
    const logPath = safePath(path.join(state, 'logs', `${action.id}.log`));
    let size = fs.existsSync(logPath) ? fs.statSync(logPath).size : 0;
    const child = spawn(action.argv[0], action.argv.slice(1), { cwd: fs.realpathSync(path.resolve(root, action.cwd)), detached: true, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, MOLT_DEVELOPMENT_SERVICE_TOKEN: token } });
    function append(bytes) {
      const data = bytes.subarray(Math.max(0, bytes.length - 1024 * 1024));
      safePath(logPath); if (size + data.length > 1024 * 1024) { fs.writeFileSync(logPath, '', { mode: 0o600 }); size = 0; }
      fs.appendFileSync(logPath, data, { mode: 0o600 }); size += data.length;
    }
    child.stdout.on('data', append); child.stderr.on('data', append);
    const result = new Promise(resolve => {
      child.once('error', () => resolve({ code: 1, reason: 'Executable unavailable; check declared toolchain and argv' }));
      child.once('exit', (code, signal) => resolve({ code, reason: signal ? `Service exited with ${signal}` : `Service exited with code ${code}` }));
    });
    child.once('spawn', () => { record = recordFor(action.id); record.child = identity(child.pid); record.state = record.child ? 'running' : 'starting'; writeJSON(recordPath(action.id), record); });
    for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sig, () => {
      if (sameProcess(record.child)) {
        signal(record.child, 'SIGTERM', true);
        const timer = setTimeout(() => { if (sameProcess(record.child)) signal(record.child, 'SIGKILL', true); }, 1500); timer.unref();
      }
    });
    const exit = await result; await stopMembers(token); record = recordFor(action.id);
    if (record.token === token) { record.state = record.desired ? 'failed' : 'stopped'; record.reason = record.desired ? exit.reason : ''; writeJSON(recordPath(action.id), record); }
  }
  if (command === 'list') { checked(!actionID, 'list takes no action', 2); for (const action of spec.actions) process.stdout.write(`${action.id}\t${action.label}\t${action.kind}\n`); return; }
  if (command === 'status') { json(selected('service').map(observed)); return; }
  if (command === 'activity') {
    const tasks = safePath(path.join(state, 'tasks'));
    let busy = selected('service').some(action => ['starting', 'running', 'unknown'].includes(observed(action).state));
    if (fs.existsSync(tasks)) for (const file of fs.readdirSync(tasks)) { const task = readJSON(path.join(tasks, file)); if (task?.incarnation === incarnation && identity(task?.child?.pid)) busy = true; }
    json({ busy }); return;
  }
  if (command === 'logs') {
    for (const action of selected('service')) {
      const name = safePath(path.join(state, 'logs', `${action.id}.log`));
      if (fs.existsSync(name)) { const fd = fs.openSync(name, 'r'); try { const size = fs.fstatSync(fd).size; const bytes = Buffer.alloc(Math.min(size, 65536)); fs.readSync(fd, bytes, 0, bytes.length, Math.max(0, size - bytes.length)); process.stdout.write(bytes); } finally { fs.closeSync(fd); } }
    }
    return;
  }
  if (command === '--supervise') { await supervise(selected('service')[0]); return; }
  if (command === 'stop' && !fs.existsSync(state)) { selected('service'); return; }
  claim();
  if (command === 'run') {
    checked(actionID, 'run requires an action id', 2); const action = selected()[0];
    if (action.kind === 'service') { await lock(path.join(state, 'runtime.lock'), () => start(action)); return; }
    const child = spawn(action.argv[0], action.argv.slice(1), { cwd: fs.realpathSync(path.resolve(root, action.cwd)), detached: true, stdio: 'inherit' });
    let childIdentity, taskPath;
    const result = new Promise(resolve => {
      child.once('spawn', () => { childIdentity = identity(child.pid); taskPath = path.join(state, 'tasks', `${randomBytes(16).toString('hex')}.json`); writeJSON(taskPath, { version: 1, incarnation, child: childIdentity }); });
      child.once('error', () => resolve(1)); child.once('exit', (code, signal) => resolve(signal === 'SIGINT' ? 130 : signal === 'SIGTERM' ? 143 : code ?? 1));
    });
    for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sig, () => { if (sameProcess(childIdentity)) signal(childIdentity, sig, true); });
    process.exitCode = await result; if (taskPath) fs.unlinkSync(taskPath); return;
  }
  await lock(path.join(state, 'runtime.lock'), async () => {
    if (command === 'stop') {
      const ids = actionID ? selected('service').map(action => action.id) : [...new Set([...spec.actions.filter(action => action.kind === 'service').map(action => action.id), ...fs.readdirSync(path.join(state, 'services')).map(name => name.replace(/\.json$/u, ''))])];
      for (const id of ids) { checked(idPattern.test(id), 'invalid service state path'); await stop(id); }
    } else for (const action of selected('service')) { if (command !== 'restore' || recordFor(action.id)?.desired) await start(action); }
  });
}

const sourceExclusions = new Set(['.git', '.ssh', '.aws', '.kube', '.npmrc', '.pypirc', '.netrc', 'node_modules', '.devenv', '.next', 'dist', 'build', 'target', '.venv', 'venv', '__pycache__', '.DS_Store']);
const generationFiles = ['.molt/development.json', 'devenv.nix', 'devenv.yaml', 'devenv.lock', 'menu'];
function sourceInventory(root, destination, filtered = true) {
  const files = [];
  function visit(relative) {
    const directoryPath = path.join(root, relative);
    for (const name of fs.readdirSync(directoryPath).sort()) {
      if (filtered && (sourceExclusions.has(name) || /^(?:\.env(?:\..*)?|.*\.(?:pem|key|p12|pfx|db|sqlite|sqlite3)|auth\.json|credentials(?:\..*)?|secrets?(?:\..*)?)$/iu.test(name))) continue;
      const rel = path.join(relative, name), file = safePath(path.join(root, rel), false), stat = fs.lstatSync(file);
      checked(!stat.isSymbolicLink() && (stat.isFile() || stat.isDirectory()), 'unsupported source entry in development snapshot');
      if (stat.isDirectory()) { if (destination) directory(path.join(destination, rel)); visit(rel); }
      else {
        const digest = hash(fs.readFileSync(file)); files.push({ path: rel, digest, mode: stat.mode & 0o777 });
        if (destination) { const target = safePath(path.join(destination, rel)); fs.copyFileSync(file, target, fs.constants.COPYFILE_EXCL); fs.chmodSync(target, stat.mode & 0o777); }
      }
    }
  }
  visit(''); return files;
}
function bytesAt(name) {
  safePath(name); if (!fs.existsSync(name)) return 0;
  const stat = fs.lstatSync(name);
  if (stat.isDirectory()) return fs.readdirSync(name).reduce((sum, child) => sum + bytesAt(path.join(name, child)), 0);
  checked(stat.isFile(), 'redirected cache content'); return stat.size;
}
function docker(args, timeout = 10000) {
  return execFileSync('docker', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout, stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}
function inspect(name, image = false) {
  try { return JSON.parse(docker(image ? ['image', 'inspect', name] : ['inspect', name]))[0]; }
  catch (e) { if (e.status === 1) return null; throw e; }
}
function containerList() {
  const ids = docker(['container', 'ls', '--all', '--quiet']).split('\n').filter(Boolean);
  checked(ids.length <= 4096, 'too many Docker containers for bounded observation');
  return ids.length ? JSON.parse(docker(['inspect', ...ids])) : [];
}
async function longDocker(args, timeout, name, verify) {
  const child = spawn('docker', args, { stdio: ['ignore', 'pipe', 'pipe'] });
  let interrupted = 0;
  // Progress is bounded per chunk; generated candidates and provider output are never logged.
  child.stdout.on('data', bytes => process.stderr.write(bytes.subarray(0, 16384)));
  child.stderr.on('data', bytes => process.stderr.write(bytes.subarray(0, 16384)));
  const cancel = signal => { interrupted = signal === 'SIGINT' ? 130 : 143; child.kill('SIGTERM'); };
  const interrupt = () => cancel('SIGINT'), terminate = () => cancel('SIGTERM');
  process.on('SIGINT', interrupt); process.on('SIGTERM', terminate);
  const timer = setTimeout(terminate, timeout);
  try {
    const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', resolve); });
    if (interrupted && name) { const object = inspect(name); if (object) { verify(object); docker(['rm', '--force', name]); } }
    checked(!interrupted && code === 0, interrupted ? 'development build cancelled; retry records retained' : 'development build failed; working runtime retained', interrupted || 1);
  } finally { clearTimeout(timer); process.removeListener('SIGINT', interrupt); process.removeListener('SIGTERM', terminate); }
}

async function control(args) {
  checked(args.length >= 8 && args[0] === '--control' && args[2] === '--root' && args[4] === '--owner' && args[6] === '--project', 'invalid development control arguments', 2);
  const [command, root, owner, project, argument] = [args[1], args[3], args[5], args[7], args[8]];
  checked(/^[a-f0-9]{32}$/u.test(owner) && /^[a-f0-9]{12}$/u.test(project) && args.length <= 9, 'invalid development control identity', 2);
  safePath(root, false); checked(fs.readFileSync(safePath(path.join(root, '.install-manifest'), false), 'utf8').trim() === owner, 'remote root ownership mismatch');
  const source = safePath(path.join(root, 'projects', project));
  const meta = safePath(path.join(root, 'meta', project, 'development'));
  const state = safePath(path.join(root, 'state', 'development', project));
  const cache = safePath(path.join(root, 'cache', project, 'development'));
  const shared = safePath(path.join(root, 'cache', 'development'));
  const store = safePath(path.join(shared, 'nix'));
  const workspace = `molt-${owner.slice(0, 8)}-${project}`;
  const ledgerPath = path.join(state, 'resources.json');
  let ledger = readJSON(ledgerPath, { version: 1, owner, project, stages: {}, active: null, previous: null });
  checked(ledger.version === 1 && ledger.owner === owner && ledger.project === project && ledger.stages && typeof ledger.stages === 'object', 'development ledger ownership mismatch');
  function claim() {
    for (const directoryPath of [state, meta, cache, path.join(cache, 'staging')]) directory(directoryPath);
    writeJSON(ledgerPath, ledger);
  }
  function ownedObject(object, role, pin) {
    const actualRole = object?.Config?.Labels?.['io.molt.role'];
    checked(object?.Config?.Labels?.['io.molt.installation'] === owner && object.Config.Labels['io.molt.project'] === project && (!role || actualRole === role || role === 'workspace' && !actualRole), 'Docker ownership mismatch');
    if (pin) checked(object.Config.Image === pin, 'builder image pin mismatch');
  }
  function workspaceObject() { const object = inspect(workspace); if (object) ownedObject(object, 'workspace'); return object; }
  function stageFor(token) {
    checked(/^[a-f0-9]{32}$/u.test(token ?? ''), 'invalid preparation token', 2);
    const stage = ledger.stages[token]; checked(stage && stage.path === path.join(cache, 'staging', token), 'unknown preparation token');
    safePath(stage.path);
    if (fs.existsSync(stage.path)) { const marker = readJSON(path.join(stage.path, 'owner.json')); checked(marker?.owner === owner && marker.project === project && marker.token === token, 'staging ownership mismatch'); }
    checked(['generating', 'candidate', 'building', 'failed', 'built'].includes(stage.state) && (!stage.revision || digestPattern.test(stage.revision)), 'invalid preparation state');
    const prefix = `molt-builder-${owner.slice(0, 8)}-${project}-${token.slice(0, 8)}`;
    checked(!stage.builder || stage.builder === prefix, 'invalid builder reference');
    checked(!stage.initializer || stage.initializer === `${prefix}-nix`, 'invalid initializer reference');
    checked(!stage.smoke || stage.smoke === `${prefix}-smoke`, 'invalid smoke reference');
    checked(!stage.image || stage.image === `molt-development-${owner.slice(0, 8)}-${project}:${stage.revision}`, 'invalid image reference');
    checked(!stage.raw_image || stage.raw_image === `molt-development-export-${owner.slice(0, 8)}-${project}:${stage.revision}`, 'invalid export reference');
    checked(!stage.base_alias || stage.base_alias === `molt-development-base-${owner.slice(0, 8)}-${project}:${stage.base.slice(7)}`, 'invalid base image alias');
    checked(!stage.nix_root || stage.nix_root === path.join(store, 'var/nix/gcroots/molt', project, stage.revision), 'invalid Nix root reference');
    return stage;
  }
  function verifiedImage(active) {
    checked(active && digestPattern.test(active.revision) && active.image === `molt-development-${owner.slice(0, 8)}-${project}:${active.revision}` && /^sha256:[a-f0-9]{64}$/u.test(active.image_id), 'invalid prepared image record');
    const object = inspect(active.image, true); ownedObject(object, 'workspace');
    checked(object.Id === active.image_id && object.Config.Labels['io.molt.development'] === active.revision && object.Config.Labels['io.molt.role'] === 'workspace', 'prepared image identity changed'); return object;
  }
  function activeProfile() {
    if (ledger.active) { verifiedImage(ledger.active); return profileAt(path.join(meta, 'profile.json'), source); }
    const profilePath = path.join(source, '.molt', 'development.json');
    return fs.existsSync(profilePath) ? profileAt(profilePath, source) : { version: 1, name: 'Development workspace', actions: [], ports: [], android: { enabled: false } };
  }
  const labels = role => ['--label', `io.molt.installation=${owner}`, '--label', `io.molt.project=${project}`, '--label', `io.molt.role=${role}`];
  const mount = (src, target, readonly = false) => { safePath(src); checked(!src.includes(','), 'Docker bind path contains an unsupported comma'); return ['--mount', `type=bind,source=${src},target=${target}${readonly ? ',readonly' : ''}`]; };
  function pinPath(pin) {
    const lock = readJSON(path.join(root, 'state/development/development-tools.lock.json'), readJSON(path.join(meta, 'development-tools.lock.json')));
    checked(lock?.artifacts?.some(artifact => ['builder', 'android'].includes(artifact.role) && `${artifact.image}@${artifact.digest}` === pin), 'unlocked shared image reference');
    return path.join(root, 'state/development/images', `${pin.slice(pin.lastIndexOf(':') + 1)}.json`);
  }
  function imageIntent(pin) {
    const file = pinPath(pin); directory(path.dirname(file));
    let record = readJSON(file);
    if (record) checked(record.version === 1 && record.owner === owner && record.pin === pin && typeof record.created === 'boolean', 'shared image ownership mismatch');
    else { const existing = inspect(pin, true); record = { version: 1, owner, pin, created: !existing, image_id: existing?.Id ?? '' }; writeJSON(file, record); }
    return record;
  }
  function imageAcquired(pin) {
    const record = imageIntent(pin), object = inspect(pin, true);
    checked(object?.Id && object.RepoDigests?.some(digest => digest.endsWith(pin.slice(pin.indexOf('@')))), 'shared image digest identity unavailable');
    checked(!record.image_id || record.image_id === object.Id, 'shared image changed since acquisition');
    record.image_id = object.Id; writeJSON(pinPath(pin), record);
  }
  function templateIdentity() {
    return ['molt.nix', 'menu.mjs', 'GUIDELINE.md', 'generation.md', 'BUILD.md'].map(name => ({ name, hash: hash(fs.readFileSync(safePath(path.join(meta, 'templates', name), false))) }));
  }
  function revisionFor(files, spec, object) {
    const base = inspect(`molt-env-${owner.slice(0, 8)}-${project}:latest`, true); ownedObject(base);
    return jsonHash({ files, spec, templates: templateIdentity(), runner: hash(fs.readFileSync(script)), lock: hash(fs.readFileSync(safePath(path.join(meta, 'development-tools.lock.json'), false))), arch: architecture, opencode: base.Config.Labels['io.molt.opencode'] ?? object?.Config?.Labels?.['io.molt.opencode'] ?? '', base: base.Id });
  }
  function runnerArgs(operation) { return ['exec', workspace, '/opt/molt/workspace-entrypoint', '/opt/node/bin/node', '/opt/molt/development.mjs', '--root', '/workspace', '--state', '/molt-cache/development', '--profile', '/molt-meta/development/profile.json', operation]; }
  function busy() {
    const object = workspaceObject(); if (!object?.State?.Running) return false;
    if (ledger.active && object.Image === ledger.active.image_id) {
      if (JSON.parse(docker(runnerArgs('activity'))).busy !== false) return true;
    }
    return false;
  }
  async function candidate() {
    claim(); const object = workspaceObject(); checked(object?.State?.Running, 'start the ordinary OpenCode workspace before preparation');
    const files = sourceInventory(source); const missing = generationFiles.filter(name => !fs.existsSync(safePath(path.join(source, name))));
    const existingProfile = !missing.includes('.molt/development.json') ? profileAt(path.join(source, '.molt/development.json'), source) : null;
    if (existingProfile && !missing.includes('devenv.nix') && !missing.includes('devenv.yaml') && ledger.active) {
      const revision = revisionFor(files, existingProfile, object);
      if (revision === ledger.active.revision) { verifiedImage(ledger.active); json({ reused: true, ...ledger.active, profile: existingProfile }); return; }
    }
    const requiresAI = missing.some(name => ['.molt/development.json', 'devenv.nix', 'devenv.yaml'].includes(name));
    if (requiresAI) {
      const auth = readJSON(path.join(root, 'auth', 'auth.json'), {});
      let configured = Object.values(auth).some(value => value && ['api', 'oauth'].includes(value.type));
      for (const name of ['config.json', 'opencode.json', 'opencode.jsonc']) {
        const file = safePath(path.join(root, 'config/opencode', name)); if (!fs.existsSync(file)) continue;
        // Match the existing JSONC loader while keeping provider values out of output.
        let text = fs.readFileSync(file, 'utf8').replace(/("(?:[^"\\]|\\.)*")|\/\/[^\r\n]*|\/\*[\s\S]*?\*\//gu, (match, string) => string || ' ');
        text = text.replace(/("(?:[^"\\]|\\.)*")|,(?=\s*[}\]])/gu, (match, string) => string || '');
        const config = JSON.parse(text);
        configured ||= Object.values(config.provider ?? {}).some(provider => typeof provider?.options?.apiKey === 'string' && provider.options.apiKey.trim() !== '');
      }
      checked(configured, 'No VM provider configured; authenticate with opencode auth login, then retry molt dev prepare');
    }
    const token = randomBytes(16).toString('hex'), stagePath = path.join(cache, 'staging', token);
    ledger.stages[token] = { path: stagePath, state: 'generating', worker: identity(process.pid), source: files, missing, image: '', image_id: '', raw_image: '', raw_id: '', builder: '', pin: '', revision: '', base: inspect(`molt-env-${owner.slice(0, 8)}-${project}:latest`, true).Id };
    writeJSON(ledgerPath, ledger); directory(stagePath); writeJSON(path.join(stagePath, 'owner.json'), { owner, project, token });
    const snapshot = path.join(stagePath, 'repo'); directory(snapshot); sourceInventory(source, snapshot);
    try {
      if (requiresAI) {
        const containerDirectory = `/molt-cache/development/staging/${token}/repo`;
        const permissions = { '*': 'deny', read: { '*': 'deny', [`${containerDirectory}/**`]: 'allow' }, edit: { '*': 'deny' }, glob: 'allow', grep: 'allow', list: 'allow', bash: 'deny', task: 'deny', external_directory: 'deny', question: 'deny' };
        for (const name of missing) permissions.edit[`${containerDirectory}/${name}`] = 'allow';
        const prompt = `${fs.readFileSync(path.join(meta, 'templates', 'generation.md'), 'utf8')}\n${fs.readFileSync(path.join(meta, 'templates', 'GUIDELINE.md'), 'utf8')}\nThe ONLY eligible files are: ${missing.join(', ')}. Existing files must stay byte-identical. Write in this staging repository.`;
        // No shell execution, real source mount, provider contents or output log in the AI boundary.
        execFileSync('docker', ['exec', '--workdir', containerDirectory, '--env', 'OPENCODE_DISABLE_PROJECT_CONFIG=1', '--env', `OPENCODE_CONFIG_CONTENT=${JSON.stringify({ permission: permissions, agent: { build: { permission: permissions } } })}`, workspace, '/opt/opencode/opencode', 'run', '--agent', 'build', prompt], { timeout: 300000, maxBuffer: 1024 * 1024, stdio: ['ignore', 'ignore', 'ignore'] });
      }
      if (missing.includes('menu') && !fs.existsSync(path.join(snapshot, 'menu'))) fs.copyFileSync(path.join(meta, 'templates', 'menu.mjs'), path.join(snapshot, 'menu'));
      const after = sourceInventory(snapshot, undefined, false);
      for (const before of files) checked(after.some(file => file.path === before.path && file.digest === before.digest && file.mode === before.mode), 'generation changed an existing file; candidate retained');
      for (const added of after.filter(file => !files.some(before => before.path === file.path))) checked(missing.includes(added.path), 'generation added an unexpected file; candidate retained');
      const spec = profileAt(path.join(snapshot, '.molt/development.json'), snapshot);
      checked(fs.existsSync(path.join(snapshot, 'devenv.nix')) && fs.existsSync(path.join(snapshot, 'devenv.yaml')), 'missing generated devenv definition');
      checked(!spec.android.enabled || existingProfile?.android.enabled, 'generation cannot enable Android');
      const stage = ledger.stages[token]; stage.state = 'candidate'; stage.candidate = after; stage.profile = spec;
      stage.revision = revisionFor(after, spec, object); writeJSON(ledgerPath, ledger); json({ token, profile: spec, revision: stage.revision, reused: false });
    } catch (e) { ledger.stages[token].state = 'failed'; writeJSON(ledgerPath, ledger); throw error(e.exitCode === 2 ? e.message : 'configuration generation failed; source and working runtime preserved', e.exitCode ?? 1); }
  }
  async function build() {
    const stage = stageFor(argument); checked(stage.state === 'candidate', 'candidate not ready for build');
    const normalized = strictJSON(fs.readFileSync(0)); checked(jsonHash(normalized) === jsonHash(stage.profile), 'validated profile changed before build', 2);
    checked(JSON.stringify(sourceInventory(path.join(stage.path, 'repo'), undefined, false)) === JSON.stringify(stage.candidate), 'candidate changed before build');
    const lock = readJSON(path.join(meta, 'development-tools.lock.json'), undefined, false);
    const artifact = lock.artifacts?.find(artifact => artifact.role === 'builder' && artifact.os === 'linux' && artifact.arch === architecture);
    checked(artifact && /^sha256:[a-f0-9]{64}$/u.test(artifact.digest) && /^[a-z0-9][a-z0-9._:/-]*$/u.test(artifact.image), 'locked native builder unavailable');
    const pin = `${artifact.image}@${artifact.digest}`;
    directory(shared);
    const sharedMarker = path.join(shared, 'owner.json'), sharedOwner = readJSON(sharedMarker);
    if (sharedOwner) checked(sharedOwner.owner === owner, 'shared Nix store ownership mismatch');
    else { checked(!fs.existsSync(store), 'unrecorded shared Nix store'); writeJSON(sharedMarker, { version: 1, owner, pin }); }
    await lockStore(async () => {
      directory(store);
      const snapshot = path.join(stage.path, 'repo'), output = path.join(stage.path, 'output'), buildCache = path.join(stage.path, 'build-cache');
      directory(output); directory(buildCache);
      const imageName = `molt-development-export-${owner.slice(0, 8)}-${project}`;
      stage.raw_image = `${imageName}:${stage.revision}`; stage.image = `molt-development-${owner.slice(0, 8)}-${project}:${stage.revision}`;
      stage.builder = `molt-builder-${owner.slice(0, 8)}-${project}-${argument.slice(0, 8)}`; stage.pin = pin; stage.state = 'building'; stage.worker = identity(process.pid); writeJSON(ledgerPath, ledger);
      checked(!inspect(stage.builder) && !inspect(stage.raw_image, true) && !inspect(stage.image, true), 'existing build resource; retry with a fresh candidate');
      fs.copyFileSync(path.join(snapshot, 'devenv.nix'), path.join(snapshot, 'devenv.original.nix'));
      directory(path.join(stage.path, 'originals'));
      for (const name of ['devenv.yaml', 'devenv.lock']) if (fs.existsSync(path.join(snapshot, name))) fs.copyFileSync(path.join(snapshot, name), path.join(stage.path, 'originals', name));
      for (const file of ['molt.nix', 'menu.mjs']) fs.copyFileSync(path.join(meta, 'templates', file), path.join(snapshot, file));
      fs.writeFileSync(path.join(snapshot, 'devenv.nix'), '{ imports = [ ./devenv.original.nix ./molt.nix ]; }\n');
      writeJSON(path.join(snapshot, 'molt-build.json'), { image: imageName, revision: stage.revision });
      stage.nix_root = path.join(store, 'var/nix/gcroots/molt', project, stage.revision);
      stage.base_alias = `molt-development-base-${owner.slice(0, 8)}-${project}:${stage.base.slice(7)}`;
      writeJSON(ledgerPath, ledger);
      if (fs.existsSync(safePath(stage.nix_root))) checkedNixRoot(stage);
      try {
        imageIntent(pin);
        if (!inspect(pin, true)) await longDocker(['pull', pin], 300000);
        imageAcquired(pin);
        if (!fs.existsSync(path.join(store, 'var/nix/db/db.sqlite'))) {
          const initializer = `${stage.builder}-nix`;
          stage.initializer = initializer; writeJSON(ledgerPath, ledger);
          checked(!inspect(initializer), 'existing shared-store initializer');
          await longDocker(['run', '--name', initializer, ...labels('builder'), ...mount(store, '/store'), pin, '/bin/sh', '-eu', '-c', 'cp -a /nix/. /store/'], 120000, initializer, object => ownedObject(object, 'builder', pin));
          const initialized = inspect(initializer); ownedObject(initialized, 'builder', pin); docker(['rm', initializer]);
        }
        const yaml = fs.readFileSync(path.join(snapshot, 'devenv.yaml'), 'utf8');
        const hasInput = name => new RegExp(`(?:^|[\\s{,])["']?${name}["']?\\s*:`, 'mu').test(yaml);
        const buildScript = `ref=github:cachix/devenv/b904dcb51fe48c30db250038241507f60752f222#devenv
devenv() { nix --extra-experimental-features 'nix-command flakes' run "$ref" -- "$@"; }
if [ '${hasInput('nix2container')}' = false ]; then devenv inputs add nix2container github:nlewo/nix2container/4e83e6724dcb9eb1b3e855426fa4c8cd19f5ce5a --follows nixpkgs; fi
if [ '${hasInput('mk-shell-bin')}' = false ]; then devenv inputs add mk-shell-bin github:rrbutani/nix-mk-shell-bin/ff5d8bd4d68a347be5042e2f16caee391cd75887; fi
devenv container build molt
devenv container copy --registry docker-archive:/output/environment.tar: molt
mkdir -p /nix/var/nix/gcroots/molt/${project}/${stage.revision}
printf '%s\\n' '${JSON.stringify({ owner, project, revision: stage.revision })}' > /nix/var/nix/gcroots/molt/${project}/${stage.revision}/owner.json
find /molt-cache/development -type l -print | while IFS= read -r link; do target=$(readlink -f "$link") || continue; case "$target" in /nix/store/*) relative=$(printf '%s' "$target" | cut -d / -f 4); target=/nix/store/$relative; root=/nix/var/nix/gcroots/molt/${project}/${stage.revision}/$(printf %s "$link" | sha256sum | cut -c1-32); if [ -L "$root" ]; then test "$(readlink "$root")" = "$target"; else ln -s "$target" "$root"; fi ;; esac; done
chown -R ${process.getuid()}:${process.getgid()} /output /workspace /molt-cache/development
`;
        await longDocker(['run', '--name', stage.builder, ...labels('builder'), '--env', 'NIX_CONFIG=extra-substituters = https://devenv.cachix.org\nextra-trusted-public-keys = devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=', ...mount(store, '/nix'), ...mount(snapshot, '/workspace'), ...mount(output, '/output'), ...mount(buildCache, '/molt-cache/development'), '--workdir', '/workspace', pin, '/bin/sh', '-eu', '-c', buildScript], 1800000, stage.builder, object => ownedObject(object, 'builder', pin));
        const built = inspect(stage.builder); ownedObject(built, 'builder', pin); checked(!built.State.Running, 'builder still running'); docker(['rm', stage.builder]);
        const archive = safePath(path.join(output, 'environment.tar'), false); checked(fs.statSync(archive).isFile(), 'environment export missing');
        docker(['load', '--input', archive], 120000); const exported = inspect(stage.raw_image, true);
        checked(exported && exported.Architecture === architecture, 'exported architecture mismatch'); stage.raw_id = exported.Id; writeJSON(ledgerPath, ledger);
        const layer = path.join(stage.path, 'layer'); directory(layer);
        fs.copyFileSync(script, path.join(layer, 'development.mjs'));
        fs.writeFileSync(path.join(layer, 'workspace-entrypoint'), '#!/bin/bash\nset -e\nsource /opt/molt/activate\nexport PATH="/opt/opencode:$PATH"\ncd /workspace\nexec "$@"\n', { mode: 0o755 });
        const base = inspect(stage.base, true); ownedObject(base);
        const alias = inspect(stage.base_alias, true); checked(!alias || alias.Id === stage.base, 'base alias identity changed');
        if (!alias) docker(['tag', stage.base, stage.base_alias]);
        const dockerfile = `FROM ${stage.base_alias}\nCOPY --from=${stage.raw_image} / /\nCOPY development.mjs workspace-entrypoint /opt/molt/\nENTRYPOINT ["/opt/molt/workspace-entrypoint"]\nCMD ["/bin/sh","-c","export OPENCODE_SERVER_PASSWORD=$(cat /molt-meta/opencode.password); exec /opt/opencode/opencode serve --hostname 0.0.0.0 --port 4096"]\n`;
        fs.writeFileSync(path.join(layer, 'Dockerfile'), dockerfile);
        await longDocker(['build', ...labels('workspace'), '--label', `io.molt.development=${stage.revision}`, '--tag', stage.image, layer], 300000);
        stage.image_id = inspect(stage.image, true)?.Id; verifiedImage(stage);
        // No source/auth/device mounts in the builder or pre-promotion smoke container.
        const smoke = `${stage.builder}-smoke`; stage.smoke = smoke; writeJSON(ledgerPath, ledger);
        await longDocker(['run', '--name', smoke, ...labels('builder'), '--network', 'none', '--user', `${process.getuid()}:${process.getgid()}`, ...mount(snapshot, '/workspace'), ...mount(buildCache, '/molt-cache/development'), stage.image, '/opt/molt/workspace-entrypoint', '/opt/node/bin/node', '--check', '/opt/molt/development.mjs'], 60000, smoke, object => ownedObject(object, 'builder'));
        const smoked = inspect(smoke); ownedObject(smoked, 'builder'); docker(['rm', smoke]);
        stage.state = 'built'; writeJSON(ledgerPath, ledger); json({ revision: stage.revision, image: stage.image, image_id: stage.image_id, profile: stage.profile });
      } catch (e) { stage.state = 'failed'; writeJSON(ledgerPath, ledger); throw e; }
    });
  }
  function lockStore(operation) { return lock(path.join(root, 'state', 'development', 'nix.lock'), operation); }
  function checkedNixRoot(stage) {
    safePath(stage.nix_root);
    if (!fs.existsSync(stage.nix_root)) return 0;
    const marker = readJSON(path.join(stage.nix_root, 'owner.json'));
    checked(marker?.owner === owner && marker.project === project && marker.revision === stage.revision, 'private Nix root ownership mismatch');
    let bytes = 0;
    for (const name of fs.readdirSync(stage.nix_root)) {
      const file = path.join(stage.nix_root, name); const stat = fs.lstatSync(file);
      if (name === 'owner.json') { checked(stat.isFile(), 'invalid Nix root marker'); bytes += stat.size; continue; }
      checked(/^[a-f0-9]{32}$/u.test(name) && stat.isSymbolicLink(), 'unexpected private Nix root entry');
      const target = fs.readlinkSync(file); checked(/^\/nix\/store\/[a-z0-9]{32}-[^/\x00-\x1f]+$/u.test(target), 'Nix root outside private store');
      safePath(path.join(store, target.slice(5)), false); bytes += stat.size;
    }
    return bytes;
  }
  function cachePreview() {
    docker(['info']); const containers = containerList(); const items = [];
    const identities = containers.map(object => ({ id: object.Id, image: object.Image, running: object.State.Running, mounts: object.Mounts, labels: object.Config.Labels })).sort((a, b) => a.id.localeCompare(b.id));
    for (const [token, stage] of Object.entries(ledger.stages)) {
      stageFor(token);
      const active = [ledger.active, ledger.previous].filter(Boolean).some(active => active.revision === stage.revision);
      const writers = containers.some(object => [stage.builder, stage.initializer, stage.smoke].includes(object.Name?.slice(1)) && object.State.Running || object.State.Running && object.Mounts?.some(mount => mount.Source === stage.path || mount.Source.startsWith(`${stage.path}/`)));
      if (writers || ['building', 'generating'].includes(stage.state) && sameProcess(stage.worker)) continue;
      if (fs.existsSync(stage.path)) items.push({ id: `build-${token.slice(0, 16)}`, kind: 'build-output', path: stage.path, bytes: bytesAt(stage.path) });
      if (!active && stage.image_id && !containers.some(object => object.Image === stage.image_id)) {
        if (inspect(stage.image, true)) { verifiedImage(stage); items.push({ id: `image-${token.slice(0, 16)}`, kind: 'image', path: stage.image, bytes: 0 }); }
      }
      if (!active && stage.nix_root && fs.existsSync(safePath(stage.nix_root)) && !containers.some(object => object.State.Running && object.Mounts?.some(mount => mount.Source === store))) {
        items.push({ id: `root-${token.slice(0, 16)}`, kind: 'nix-root', path: stage.nix_root, bytes: checkedNixRoot(stage) });
      }
    }
    items.sort((a, b) => a.id.localeCompare(b.id));
    checked(items.length <= 4096, 'cache preview exceeds the v1 item limit');
    return { version: 1, project_id: project, revision: hash(JSON.stringify({ items, identities, ledger })), reclaimable_bytes: items.reduce((sum, item) => sum + item.bytes, 0), items, reason: 'Image storage shares layers; byte estimate includes build outputs and roots. The private Nix store is retained until installation cleanup.' };
  }
  function removeDirectory(name) {
    safePath(name); if (!fs.existsSync(name)) return;
    checked(name.startsWith(`${cache}/`) || name === cache || name === meta || name === shared || name.startsWith(`${store}/var/nix/gcroots/molt/${project}/`), 'cleanup outside owned development resources');
    try { fs.rmSync(name, { recursive: true }); }
    catch {
      // Nix/Android writers can leave root-owned files. Mount only this checked owned path.
      const lockPath = fs.existsSync(path.join(meta, 'development-tools.lock.json')) ? path.join(meta, 'development-tools.lock.json') : path.join(root, 'state/development/development-tools.lock.json');
      const artifact = readJSON(lockPath)?.artifacts?.find(artifact => artifact.role === 'builder' && artifact.arch === architecture && artifact.os === 'linux');
      checked(artifact?.digest && artifact?.image, 'pinned cleanup helper unavailable');
      docker(['run', '--rm', '--network', 'none', ...labels('builder'), ...mount(name, '/cleanup'), `${artifact.image}@${artifact.digest}`, '/bin/sh', '-eu', '-c', 'rm -rf /cleanup/* /cleanup/.[!.]* /cleanup/..?*'], 60000); fs.rmdirSync(name);
    }
  }
  async function observe() {
    docker(['info']); const spec = activeProfile(); const object = workspaceObject();
    let services = spec.actions.filter(action => action.kind === 'service').map(action => ({ id: action.id, label: action.label, state: object?.State?.Running ? 'unknown' : 'stopped', reason: object?.State?.Running ? 'Prepared runtime is not active' : '' }));
    if (ledger.active && object?.State?.Running && object.Image === ledger.active.image_id) services = JSON.parse(docker(runnerArgs('status')));
    const ports = spec.ports.map(port => {
      const binding = object?.NetworkSettings?.Ports?.[`${port.container_port}/tcp`]?.[0];
      checked(!binding || binding.HostIp === '127.0.0.1' && /^\d+$/u.test(binding.HostPort), 'application publication is not VM loopback');
      return { ...port, vm_port: binding ? Number(binding.HostPort) : 0, local_port: 0, url: '', state: 'inactive', reason: '' };
    });
    const android = { enabled: spec.android.enabled, state: spec.android.enabled ? 'unknown' : 'disabled', reason: spec.android.enabled ? 'Run Android check for host capability' : '', container: '', adb_vm_port: 0, adb_local_port: 0, adb_server_local_port: 0, viewer_state: 'closed' };
    const androidHelper = path.join(root, 'state', 'development', 'android.sh');
    if (fs.existsSync(safePath(androidHelper))) {
      try { Object.assign(android, JSON.parse(execFileSync('bash', [androidHelper, 'status', root, owner, project], { encoding: 'utf8', timeout: 10000 }))); }
      catch { if (spec.android.enabled) { android.state = 'unknown'; android.reason = 'Android observation unavailable'; } }
    }
    const preview = cachePreview();
    const environment = { state: ledger.active ? object?.Image === ledger.active.image_id ? 'ready' : 'blocked' : 'absent', revision: ledger.active?.revision ?? '', reason: ledger.active && object?.Image !== ledger.active.image_id ? 'Prepared image awaits a safe workspace restart' : '' };
    json({ version: 1, project_id: project, name: spec.name, environment, services, ports, android, cache: { reclaimable_bytes: preview.reclaimable_bytes, reason: preview.reason }, cleanup: { state: ledger.cleanup?.state ?? 'clean', remaining: ledger.cleanup?.remaining ?? [], reason: ledger.cleanup?.reason ?? '' } });
  }
  if (command === 'status') { await observe(); return; }
  if (command === 'cache') { json(cachePreview()); return; }
  if (command === 'inventory') { json(Object.entries(ledger.stages).flatMap(([, stage]) => [stage.path, stage.builder, stage.initializer, stage.smoke, stage.image, stage.raw_image, stage.base_alias, stage.nix_root].filter(Boolean)).concat(fs.existsSync(cache) ? [cache] : [], fs.existsSync(meta) ? [meta] : [])); return; }
  if (command === 'runtime') { if (!ledger.active) { json({}); return; } verifiedImage(ledger.active); json({ ...ledger.active, profile: activeProfile() }); return; }
  if (command === 'activity') { json({ busy: busy() }); return; }
  if (command === 'cleanup-shared') {
    for (const directoryPath of [path.join(root, 'projects'), path.join(root, 'meta')]) {
      safePath(directoryPath); checked(!fs.existsSync(directoryPath) || fs.readdirSync(directoryPath).length === 0, 'remove projects before shared development cleanup');
    }
    await lockStore(async () => {
      const states = path.join(root, 'state', 'development');
      for (const name of fs.readdirSync(states)) if (/^[a-f0-9]{12}$/u.test(name)) checked(!fs.existsSync(path.join(states, name, 'resources.json')), 'project development references remain');
      checked(!containerList().some(object => object.Mounts?.some(mount => mount.Source === store || mount.Source?.startsWith(`${shared}/`))), 'shared store remains referenced by a container');
      const marker = readJSON(path.join(shared, 'owner.json')); if (fs.existsSync(shared)) checked(marker?.owner === owner, 'unowned shared store');
      if (process.platform === 'linux') for (const pid of fs.readdirSync('/proc').filter(name => /^\d+$/u.test(name))) {
        if (Number(pid) === process.pid) continue;
        const processIdentity = identity(Number(pid)); checked(processIdentity?.executable !== path.join(states, 'node/bin/node'), 'private VM tooling is still in use');
      }
      const imageDirectory = safePath(path.join(states, 'images'));
      if (fs.existsSync(imageDirectory)) for (const name of fs.readdirSync(imageDirectory)) {
        checked(/^[a-f0-9]{64}\.json$/u.test(name), 'unrecorded shared image ledger');
        const file = path.join(imageDirectory, name), record = readJSON(file);
        checked(record?.owner === owner && pinPath(record.pin) === file, 'shared image ledger ownership mismatch');
        const object = inspect(record.pin, true);
        if (object && record.created) {
          checked(record.image_id && object.Id === record.image_id && object.RepoDigests?.some(digest => digest.endsWith(record.pin.slice(record.pin.indexOf('@')))), 'shared image identity changed; retained');
          checked(!containerList().some(container => container.Image === object.Id), 'shared image remains referenced by a container');
          checked(!object.RepoTags?.length, 'shared image gained tags; preserve those references before cleanup');
          docker(['image', 'rm', record.pin]);
        }
        fs.unlinkSync(file);
      }
      if (fs.existsSync(imageDirectory)) fs.rmdirSync(imageDirectory);
      removeDirectory(shared);
      for (const name of ['node', 'node.identity', 'development.mjs', 'android.sh', 'development-tools.lock.json', 'tools.lock']) {
        const resource = safePath(path.join(states, name)); if (fs.existsSync(resource)) fs.rmSync(resource, { recursive: true });
      }
    });
    return;
  }
  claim();
  await lock(path.join(state, 'project.lock'), async () => {
    if (command === 'candidate') await candidate();
    else if (command === 'build') await build();
    else if (command === 'image-intent') { imageIntent(argument); json({}); }
    else if (command === 'image-acquired') { imageAcquired(argument); json({}); }
    else if (command === 'promote') {
      const stage = stageFor(argument); checked(stage.state === 'built', 'environment build has not passed'); verifiedImage(stage);
      checked(!busy(), 'workspace has active development work; stop it before preparing a new revision');
      checked(JSON.stringify(sourceInventory(source)) === JSON.stringify(stage.source), 'source changed before promotion; inspect synchronization and retry');
      const snapshot = path.join(stage.path, 'repo');
      for (const name of stage.missing) {
        const candidate = safePath(path.join(snapshot, name)); if (!fs.existsSync(candidate)) continue;
        // The Nix snapshot wrapper and lock are build inputs, never repository replacements.
        const content = name === 'devenv.nix' ? path.join(snapshot, 'devenv.original.nix') : name === 'devenv.yaml' || name === 'devenv.lock' ? path.join(stage.path, 'originals', name) : candidate;
        if (!fs.existsSync(content)) continue;
        const target = safePath(path.join(source, name)); checked(!fs.existsSync(target), 'missing source file appeared before promotion');
        directory(path.dirname(target)); fs.copyFileSync(content, target, fs.constants.COPYFILE_EXCL);
      }
      ledger.previous = ledger.active; ledger.active = { revision: stage.revision, image: stage.image, image_id: stage.image_id, base: stage.base };
      const oldProfile = readJSON(path.join(meta, 'profile.json')); if (oldProfile) writeJSON(path.join(meta, 'profile.previous.json'), oldProfile);
      writeJSON(path.join(meta, 'profile.json'), stage.profile); writeJSON(ledgerPath, ledger); json({ ...ledger.active, profile: stage.profile });
    } else if (command === 'rollback') {
      ledger.active = ledger.previous; ledger.previous = null;
      const previousProfile = readJSON(path.join(meta, 'profile.previous.json')); if (previousProfile) writeJSON(path.join(meta, 'profile.json'), previousProfile);
      writeJSON(ledgerPath, ledger); json(ledger.active ?? {});
    } else if (command === 'clean-cache') {
      checked(digestPattern.test(argument ?? ''), 'clean-cache requires a displayed SHA-256 revision', 2);
      await lockStore(async () => {
        const preview = cachePreview(); checked(preview.revision === argument, 'cache inventory changed; display a fresh preview');
        for (const item of preview.items) {
          if (item.kind === 'image') docker(['image', 'rm', item.path]); else removeDirectory(item.path);
        }
        writeJSON(ledgerPath, ledger); json({ removed: preview.items.length });
      });
    } else if (command === 'cleanup') {
      const workspaceResource = workspaceObject();
      checked(!workspaceResource?.State?.Running, 'stop and synchronize the workspace writer before cleanup');
      if (workspaceResource) docker(['rm', workspace]);
      await lockStore(async () => {
        const remaining = [];
        for (const [token, stage] of Object.entries(ledger.stages)) {
          stageFor(token);
          for (const name of [stage.builder, stage.initializer, stage.smoke].filter(Boolean)) {
            try { const object = inspect(name); if (object) { ownedObject(object, 'builder', name === stage.smoke ? undefined : stage.pin); docker(['rm', '--force', name]); } } catch { remaining.push(name); }
          }
          if (!remaining.length) {
            for (const [name, id] of [[stage.image, stage.image_id], [stage.raw_image, stage.raw_id], [stage.base_alias, stage.base]]) {
              if (!name) continue;
              try { const object = inspect(name, true); if (object) { checked(id && object.Id === id, 'image creation identity unavailable'); if (name === stage.image || name === stage.base_alias) ownedObject(object, 'workspace'); checked(!containerList().some(container => container.Image === id), 'image is referenced by a container'); docker(['image', 'rm', name]); } } catch { remaining.push(name); }
            }
            if (stage.nix_root) { try { checkedNixRoot(stage); removeDirectory(stage.nix_root); } catch { remaining.push(stage.nix_root); } }
          }
        }
        ledger.cleanup = { state: remaining.length ? 'failed' : 'pending', remaining, reason: remaining.length ? 'Owned resource removal failed; retry records retained' : '' }; writeJSON(ledgerPath, ledger);
        checked(!remaining.length, ledger.cleanup.reason);
        removeDirectory(cache); removeDirectory(meta);
        fs.unlinkSync(ledgerPath);
      });
    } else throw error('unknown development control operation', 2);
  });
}

try {
  const args = process.argv.slice(2);
  if (args[0] === '--control') await control(args); else await runtime(args);
} catch (e) {
  console.error(`development: ${e.message}`); process.exitCode = e.exitCode ?? 1;
}
