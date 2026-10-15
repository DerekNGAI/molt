#!/usr/bin/env bash
# A real isolated SSH master and device/app TCP tunnel on a disposable Docker daemon.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
JOB=molt-remote-development-20261013-c8e72a-02-runtime
NAME="$JOB-ssh" IMAGE="$JOB-ssh:fixture"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-private-ssh.XXXXXX")"; TMP="$(cd "$TMP" && pwd -P)"
MOLT_HOME="$TMP/home" MOLT_HOST=fixture-ssh PROJECT_ID=aaaaaaaaaaaa PROJECT_STATE="$MOLT_HOME/projects/$PROJECT_ID"
source "$ROOT/bin/_molt.sh"
source "$ROOT/bin/_manage.sh"
source "$ROOT/bin/_opencode.sh"
log() { printf '%s\n' "$*" >&2; }
die() { log "$*"; exit 1; }
read_value() { [[ -f "$1" ]] && IFS= read -r REPLY <"$1" && printf '%s\n' "$REPLY"; }
cleanup() {
  local rc=$?; trap - EXIT
  if [[ -d "$MOLT_HOME/state/ssh" ]]; then molt_ssh -O exit "$MOLT_HOST" >/dev/null 2>&1 || true; fi
  if [[ "$(docker inspect -f '{{index .Config.Labels "io.molt.job"}}' "$NAME" 2>/dev/null || true)" == "$JOB" ]]; then docker rm --force "$NAME" >/dev/null || rc=1; fi
  if [[ "$(docker image inspect -f '{{index .Config.Labels "io.molt.job"}}' "$IMAGE" 2>/dev/null || true)" == "$JOB" ]]; then docker image rm "$IMAGE" >/dev/null || rc=1; fi
  rm -rf -- "$TMP"
  exit "$rc"
}
trap cleanup EXIT
[[ "${MOLT_DEVELOPMENT_DISPOSABLE_DOCKER:-}" == 1 ]] || { printf 'SKIP: real private SSH requires a designated disposable Docker daemon\n'; exit 0; }
docker info >/dev/null
if docker inspect "$NAME" >/dev/null 2>&1 || docker image inspect "$IMAGE" >/dev/null 2>&1; then printf 'BLOCKED: existing SSH fixture identity\n' >&2; exit 1; fi
mkdir -p "$TMP/context" "$PROJECT_STATE" "$MOLT_HOME/state/ssh"
ssh-keygen -q -t ed25519 -N '' -f "$TMP/key"
cp "$TMP/key.pub" "$TMP/context/authorized_keys"
cp "$ROOT/tests/fixtures/development-runtime/ssh.Dockerfile" "$TMP/context/Dockerfile"
cat >"$TMP/context/server.mjs" <<'JS'
import http from 'node:http';
const server = http.createServer((_request, response) => response.end('private-ssh-application'));
server.on('upgrade', (_request, socket) => { socket.write('HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n'); socket.on('data', bytes => socket.write(bytes)); });
server.listen(3000, '127.0.0.1');
JS
docker build --label "io.molt.job=$JOB" --tag "$IMAGE" "$TMP/context" >&2
docker run --detach --init --name "$NAME" --label "io.molt.job=$JOB" --publish 127.0.0.1::22 --mount "type=bind,source=$ROOT,target=/workspace,readonly" --mount "type=bind,source=$ROOT/artifacts/02-runtime,target=/workspace/artifacts/02-runtime" "$IMAGE" >/dev/null
mapping="$(docker port "$NAME" 22/tcp)"; port="${mapping##*:}"
for attempt in {1..60}; do ssh-keyscan -p "$port" 127.0.0.1 >"$MOLT_HOME/state/ssh/known_hosts" 2>/dev/null && break; sleep 0.1; done
cat >"$TMP/ssh.config" <<EOF
Host fixture-ssh
  HostName 127.0.0.1
  Port $port
  User root
  IdentityFile "$TMP/key"
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking yes
EOF
MOLT_SSH_CONFIG="$TMP/ssh.config"
ssh() { molt_ssh "$@"; }
ssh -fN "$MOLT_HOST"
first="$(molt_forward_allocate app:web 3000 3000)"
[[ "$(curl -q --noproxy '*' --fail --max-time 3 "http://127.0.0.1:$first/")" == private-ssh-application ]]
mkdir -p "$MOLT_HOME/projects/bbbbbbbbbbbb"
PROJECT_ID=bbbbbbbbbbbb PROJECT_STATE="$MOLT_HOME/projects/bbbbbbbbbbbb"
second="$(molt_forward_allocate app:web 3000 3000)"
[[ "$first" != "$second" ]]
node - "$second" <<'JS'
const net = require('node:net'), assert = require('node:assert/strict');
const socket = net.connect(Number(process.argv[2]), '127.0.0.1');
socket.setTimeout(3000, () => { socket.destroy(); process.exitCode = 1; });
socket.write('GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n');
socket.once('data', header => { assert.match(header.toString(), /101 Switching Protocols/); const frame=Buffer.from([0x81,0x82,1,2,3,4,0x69,0x6b]);socket.write(frame);socket.once('data',data=>{assert.deepEqual(data,frame);socket.destroy();}); });
JS
molt_forward_cancel app:
PROJECT_STATE="$MOLT_HOME/projects/aaaaaaaaaaaa" PROJECT_ID=aaaaaaaaaaaa
molt_forward_cancel app:
docker exec --user "$(id -u):$(id -g)" --env TMPDIR=/workspace/artifacts/02-runtime/tmp "$NAME" node --test /workspace/tests/fixtures/development-runtime/runner.test.mjs
printf 'PASS: real private SSH, two projects, HTTP and WebSocket data; owned server/master/container/image stopped by trap\n'
