#!/usr/bin/env bash
# Real CLI and remote helpers, with isolated SSH/Mutagen/Docker transports.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-permissions.XXXXXX")"
real_started=0
trap 'if [[ "$real_started" == 1 ]]; then real_mutagen daemon stop >/dev/null 2>&1 || true; fi; rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export TEST_TMP="$TMP" MOLT_HOME="$TMP/local" TEST_VM="$TMP/vm" TEST_REMOTE_BIN="$TMP/remote-bin"
mkdir -p "$MOLT_HOME" "$TMP/bin" "$TEST_REMOTE_BIN" "$TEST_VM" "$TMP/repo"
export MOLT_MUTAGEN_BINARY="$TMP/bin/mutagen"
owner=0123456789abcdef0123456789abcdef
printf 'FORMAT=2\nINSTALL_ID=%s\nROOT=%s\n' "$owner" "$MOLT_HOME" >"$MOLT_HOME/.install-manifest"
printf 'MOLT_HOST=test-vm\n' >"$MOLT_HOME/config"
cat >"$TMP/bin/ssh" <<'SSH'
#!/usr/bin/env bash
for arg in "$@"; do [[ "$arg" != -O && "$arg" != -fN ]] || exit 0; done
HOME="$TEST_VM" PATH="$TEST_REMOTE_BIN:/usr/bin:/bin" /bin/bash -c "${!#}"
SSH
cat >"$TMP/bin/mutagen" <<'MUTAGEN'
#!/usr/bin/env bash
printf 'mutagen %s\n' "$*" >>"$TEST_TMP/events"
case "$*" in
  'sync list'*)
    if [[ "$*" == *'json .'* ]]; then
      python3 - "$TEST_SESSION" "$TEST_TMP/blocked" <<'PY'
import json, os, sys
problem = dict(path='test/committer.test.js', error='unable to remove file: permission denied')
print(json.dumps([dict(name=sys.argv[1], status='watching', alpha=dict(connected=True), beta=dict(connected=True, transitionProblems=[problem] if os.path.exists(sys.argv[2]) else []))]))
PY
    elif [[ "$*" == *SessionState* ]]; then [[ ! -f "$TEST_TMP/blocked" ]] || printf blocked;
    elif [[ "$*" == *--long* ]]; then printf 'VM test/committer.test.js: unable to remove file: permission denied\n';
    else printf '%s\n' "$TEST_SESSION"; fi ;;
  'sync pause'*) touch "$TEST_TMP/paused" ;;
  'sync resume'*) rm -f "$TEST_TMP/paused" ;;
  'sync terminate'*) touch "$TEST_TMP/terminated" ;;
  'sync flush'*) [[ ! -f "$TEST_TMP/paused" ]] ;;
esac
MUTAGEN
cat >"$TEST_REMOTE_BIN/id" <<'ID'
#!/usr/bin/env bash
case "$1" in -u|-g) printf '1001\n' ;; *) exec /usr/bin/id "$@" ;; esac
ID
if [[ "$(/usr/bin/id -u)" != 0 ]]; then
  cat >"$TEST_REMOTE_BIN/find" <<'FIND'
#!/usr/bin/env bash
# An unprivileged host cannot create root-owned fixtures; simulate the probe.
if [[ "$*" == *'-print -quit'* ]]; then printf '%s\n' "$1";
else exec /usr/bin/find "$@"; fi
FIND
fi
cat >"$TEST_REMOTE_BIN/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"$TEST_TMP/events"
case "$1 ${2:-}" in
  'inspect '*)
    if [[ "$*" == *State.Running* ]]; then [[ ! -f "$TEST_TMP/running" ]] || printf true;
    elif [[ "$*" == *io.molt.installation* ]]; then printf '%s\n' "$MOLT_INSTALL_ID";
    elif [[ "$*" == *io.molt.runtime* ]]; then printf 'opencode-4\n';
    else printf fixture; fi ;;
  'stop '*) rm -f "$TEST_TMP/running"; touch "$TEST_TMP/stopped" ;;
  'image inspect'|'rm '*|'info '|'container ls'|'image ls') ;;
  'run '*)
    if [[ "$*" == *dst=/repair* ]]; then
      [[ -f "$TEST_TMP/stopped" && ( -f "$TEST_TMP/paused" || -f "$TEST_TMP/terminated" ) && ! -f "$TEST_TMP/fail-repair" ]] || exit 1
      mount=''
      for arg in "$@"; do
        if [[ "$arg" == type=bind,src=*,dst=/repair ]]; then mount="${arg#type=bind,src=}"; mount="${mount%,dst=/repair}"; fi
      done
      while [[ "$1" != sh ]]; do shift; done
      # Execute the actual container payload against its disposable bind source.
      /bin/sh -c "$3" "$4" "$mount" "$6"
      rm -f "$TEST_TMP/blocked"
    fi ;;
  *) exit 1 ;;
esac
DOCKER
chmod +x "$TMP/bin/"* "$TEST_REMOTE_BIN/"*
export PATH="$TMP/bin:$PATH"
git -C "$TMP/repo" init -q
"$ROOT/bin/molt" register "$TMP/repo" >/dev/null
id="$("$ROOT/bin/molt" project-id "$TMP/repo")"
state="$MOLT_HOME/projects/$id"
export TEST_SESSION="$(<"$state/sync")"
remote="$TEST_VM/molt"
mkdir -p "$remote/projects/$id/test" "$remote/cache/$id/home" "$remote/config/opencode" "$remote/auth"
printf '%s\n' "$owner" >"$remote/.install-manifest"
printf '{}\n' >"$remote/auth/auth.json"
printf 'VM content\n' >"$remote/projects/$id/test/committer.test.js"
printf 'Mac content\n' >"$TMP/repo/preserved.txt"
printf '%s\n' "$remote" >"$state/remote_home"
printf '%s\n' "$remote/projects/$id" >"$state/remote_path"
printf 'complete\n' >"$state/setup_state"
printf '1\n' >"$state/sync_created"
printf 'two-way-safe\n' >"$state/sync_mode"
touch "$TMP/blocked"
"$ROOT/bin/molt" sync "@$id" >"$TMP/details"
grep -q 'test/committer.test.js.*permission denied' "$TMP/details" || fail 'sync details hid the filesystem error'
if "$ROOT/bin/molt" sync-cycle "@$id"; then fail 'recheck reported success with a transition problem'; fi
printf 'opencode-5\n' >"$state/runtime_version"
if MOLT_ASSUME_YES=1 "$ROOT/bin/molt" reset "@$id"; then fail 'removal ignored a transition problem'; fi
[[ -f "$state/path" && -f "$remote/projects/$id/test/committer.test.js" ]] || fail 'blocked removal lost VM edits or recovery records'
/bin/bash -c 'source "$0" help >/dev/null; load_project "$1"; OPENCODE_CONFIG_VERSION=fixture; ensure_container' "$ROOT/bin/molt" "@$id"
grep -q -- '--user 1001:1001' "$TMP/events" || fail 'container writes do not use the VM identity'
touch "$TMP/running" "$TMP/fail-repair"
if "$ROOT/bin/molt" sync-repair "@$id"; then fail 'failed repair succeeded'; fi
[[ ! -f "$TMP/paused" && -f "$state/path" && -f "$TMP/blocked" ]] || fail 'failed repair lost synchronization or recovery records'
rm "$TMP/fail-repair"
mkdir "$TMP/outside"
printf 'outside\n' >"$TMP/outside/file"
chmod 400 "$TMP/outside/file"
ln -s "$TMP/outside" "$remote/projects/$id/external"
if [[ "$(/usr/bin/id -u)" == 0 && "$(uname -s)" == Linux ]]; then
  printf 'other owner\n' >"$remote/projects/$id/other-owner"
  chown 1002:1002 "$remote/projects/$id/other-owner"
fi
"$ROOT/bin/molt" sync-repair "@$id"
[[ ! -f "$TMP/paused" && ! -f "$TMP/blocked" ]] || fail 'repair did not resume clear synchronization'
[[ "$(<"$remote/projects/$id/test/committer.test.js")" == 'VM content' && "$(<"$TMP/repo/preserved.txt")" == 'Mac content' ]] || fail 'permissions repair changed content'
if [[ "$(/usr/bin/id -u)" == 0 && "$(uname -s)" == Linux ]]; then
  [[ "$(stat -c %u:%g "$remote/projects/$id/test")" == 1001:1001 ]] || fail 'root-owned parent remained inaccessible'
  [[ "$(stat -c %u "$remote/projects/$id/other-owner")" == 1002 ]] || fail 'repair changed an unrelated owner'
  [[ "$(stat -c %u:%a "$TMP/outside/file")" == 0:400 ]] || fail 'repair followed an external symlink'
  chmod 755 "$TMP"
  setpriv --reuid=1001 --regid=1001 --clear-groups rm "$remote/projects/$id/test/committer.test.js"
  [[ ! -e "$remote/projects/$id/test/committer.test.js" ]] || fail 'VM user still cannot delete the repaired file'
  if [[ -n "${MOLT_SYNC_REAL_MUTAGEN:-}" ]]; then
    mkdir -p "$TMP/real-mac/test" "$TMP/real-mutagen" "$remote/projects/$id/real/test"
    printf 'preserve until synchronization\n' >"$TMP/real-mac/test/file"
    cp "$TMP/real-mac/test/file" "$remote/projects/$id/real/test/file"
    chown -R 1001:1001 "$TMP/real-mac" "$TMP/real-mutagen"
    real_mutagen() {
      setpriv --reuid=1001 --regid=1001 --clear-groups env MUTAGEN_DATA_DIRECTORY="$TMP/real-mutagen" "$MOLT_SYNC_REAL_MUTAGEN" "$@"
    }
    real_mutagen daemon start
    real_started=1
    real_mutagen sync create --name permissions --mode two-way-safe "$TMP/real-mac" "$remote/projects/$id/real"
    real_mutagen sync flush permissions
    setpriv --reuid=1001 --regid=1001 --clear-groups rm "$TMP/real-mac/test/file"
    real_mutagen sync flush permissions
    real_mutagen sync list permissions --template '{{json .}}' >"$TMP/real-status.json"
    python3 - "$TMP/real-status.json" <<'PY'
import json, sys
problems = json.load(open(sys.argv[1]))[0]['beta']['transitionProblems']
assert any(p['path'] == 'test/file' and 'permission denied' in p['error'] for p in problems), problems
PY
    real_mutagen sync pause permissions
    "$ROOT/bin/molt" sync-repair "@$id"
    real_mutagen sync resume permissions
    real_mutagen sync flush permissions
    real_mutagen sync list permissions --template '{{json .}}' >"$TMP/real-status.json"
    python3 - "$TMP/real-status.json" <<'PY'
import json, sys
session = json.load(open(sys.argv[1]))[0]
assert not session.get('conflicts') and not session['beta'].get('transitionProblems'), session
PY
    [[ ! -e "$remote/projects/$id/real/test/file" ]] || fail 'real synchronization did not apply the pending deletion'
  fi
fi
printf 'one-way-replica\n' >"$state/sync_mode"
before="$(wc -l <"$TMP/events")"
/bin/bash -c 'source "$0" help >/dev/null; load_project "$1"; repair_loaded_permissions' "$ROOT/bin/molt" "@$id"
python3 - "$TMP/events" "$before" <<'PY'
import sys
events = open(sys.argv[1]).read().splitlines()[int(sys.argv[2]):]
assert any(e.startswith('mutagen sync terminate') for e in events), events
assert not any(e.startswith('mutagen sync resume') for e in events), events
PY
rmdir "$remote/config/opencode"
ln -s "$TMP/outside" "$remote/config/opencode"
if HOME="$TEST_VM" PATH="$TEST_REMOTE_BIN:/usr/bin:/bin" /bin/bash "$ROOT/bin/_remote.sh" repair-permissions "$remote" "$owner" "$id"; then fail 'repair accepted a redirected mount'; fi
if [[ -n "${MOLT_TEST_TUI:-}" ]]; then
  rm "$remote/config/opencode"
  mkdir "$remote/config/opencode"
  printf 'two-way-safe\n' >"$state/sync_mode"
  printf '1\n' >"$state/sync_created"
  printf 'opencode-5\n' >"$state/runtime_version"
  printf 'VM content\n' >"$remote/projects/$id/test/committer.test.js"
  if [[ "$(/usr/bin/id -u)" == 0 ]]; then chown 0:0 "$remote/projects/$id/test"; fi
  touch "$TMP/blocked" "$TMP/running"
  export TEST_ROOT="$ROOT" TERM=xterm-256color
  "$ROOT/bin/molt" config set MOLT_ANIMATIONS 0
  /usr/bin/expect "$ROOT/tests/sync_permissions_test.exp"
  [[ ! -d "$state" && ! -d "$remote/projects/$id" && "$(<"$TMP/repo/preserved.txt")" == 'Mac content' ]] || fail 'recovery did not remove VM resources while keeping the checkout'
fi
printf 'molt synchronization permissions tests: ok\n'
