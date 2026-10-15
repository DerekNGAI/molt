#!/usr/bin/env node
import { spawn } from 'node:child_process';

const args = process.argv.slice(2);
if (args.length > 1 || (args.length === 1 && args[0] !== '--list' && !/^[a-z][a-z0-9-]{0,31}$/.test(args[0]))) {
  console.error('Usage: menu --list | menu <action-id>');
  process.exit(2);
}
const operation = args.length === 0 || args[0] === '--list' ? ['list'] : ['run', args[0]];
const child = spawn(process.execPath, [
  '/opt/molt/development.mjs', '--root', '/workspace', '--state', '/molt-cache/development',
  '--profile', '/molt-meta/development/profile.json', ...operation,
], { stdio: 'inherit' });
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => child.kill(signal));
}
child.on('error', (error) => {
  console.error(`menu: ${error.message}`);
  process.exitCode = 1;
});
child.on('exit', (code, signal) => {
  process.exitCode = signal === 'SIGINT' ? 130 : signal === 'SIGTERM' ? 143 : code ?? 1;
});
