#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-viewer.XXXXXX")"; TMP="$(cd "$TMP" && pwd -P)"
export ROOT TMP MOLT_HOME="$TMP/home"
cleanup() {
  local pid executable
  for pid in $(pgrep -f "$MOLT_HOME/tools/development/darwin-fixture" || true); do
    executable="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
    if [[ "$executable" == "$MOLT_HOME/tools/development/darwin-fixture/adb" || "$executable" == "$MOLT_HOME/tools/development/darwin-fixture/scrcpy" ]]; then kill -TERM "$pid" 2>/dev/null || true; fi
  done
  [[ -z "${NORMAL_PID:-}" ]] || kill -TERM "$NORMAL_PID" 2>/dev/null || true
  rm -rf -- "$TMP"
}
trap cleanup EXIT
mkdir -p "$MOLT_HOME/projects/aaaaaaaaaaaa" "$MOLT_HOME/state/ssh" "$MOLT_HOME/state/tmp" "$MOLT_HOME/tools/development/darwin-fixture"
printf 'FORMAT=2\nROOT=%s\nINSTALL_ID=0123456789abcdef0123456789abcdef\nSTATUS=ready\n' "$MOLT_HOME" >"$MOLT_HOME/.install-manifest"
go build -o "$MOLT_HOME/tools/development/darwin-fixture/adb" "$ROOT/tests/fixtures/android-runtime/helper.go"
cp "$MOLT_HOME/tools/development/darwin-fixture/adb" "$MOLT_HOME/tools/development/darwin-fixture/scrcpy"
cp "$MOLT_HOME/tools/development/darwin-fixture/adb" "$TMP/normal"
"$TMP/normal" >/dev/null & NORMAL_PID=$!; export NORMAL_PID
checks() {
  source "$ROOT/bin/molt" help >/dev/null
  source "$ROOT/bin/_development.sh"
  source "$ROOT/bin/_android.sh"
  PROJECT_STATE="$MOLT_HOME/projects/aaaaaaaaaaaa" PROJECT_ID=aaaaaaaaaaaa MOLT_HOST=fixture-vm PROJECT_REMOTE_HOME="$TMP/vm"
  local root="$MOLT_HOME/tools/development/darwin-fixture" record original pid server
  fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
  development_rpc() { printf '{"android":{"state":"ready","adb_vm_port":33333}}'; }
  development_tools() { printf '{}' | development_json 'return {adb:args[0]+"/adb",scrcpy:args[0]+"/scrcpy",version:"fixture",owned_root:args[0]}' "$root"; }
  ssh() { [[ "$*" != *'-O check'* ]] || printf 'Master running (pid=%s)\n' "$$" >&2; }
  with_molt_forward_lock android_view_locked
  record="$(development_local_read)"; original="$record"
  server="$(printf '%s' "$record" | development_json 'return String(value.viewer_intent.server_port)')"
  [[ "$server" != 5037 ]] || fail 'used normal ADB server'
  [[ "$(<"$PROJECT_STATE/android-viewer.log")" == *'--force-adb-forward --serial=127.0.0.1:'* ]] || fail 'viewer omitted forward/serial'
  printf '%s' "$record" | development_json 'value.viewer.pid=Number(args[0]);return value' "$NORMAL_PID" | development_local_write
  if android_stop_viewer; then fail 'foreign PID was accepted'; fi
  kill -0 "$NORMAL_PID" || fail 'normal helper was killed'
  printf '%s' "$original" | development_local_write
  pid="$(printf '%s' "$original" | development_json 'return String(value.viewer.pid)')"
  android_stop_viewer
  kill -0 "$NORMAL_PID" || fail 'private stop killed the normal helper'
  if kill -0 "$pid" 2>/dev/null; then fail 'private viewer still alive'; fi
  record="$(development_local_read)"
  [[ "$(printf '%s' "$record" | development_json 'return String(!value.viewer&&!value.adb_server)')" == true ]] || fail 'helper cleanup lost isolation'
  development_tools() { return 1; }
  if with_molt_forward_lock android_view_locked; then fail 'failed acquisition appeared successful'; fi
  printf 'PASS: real owned helper processes/private ports with SDK/ADB protocol doubles; no GUI/Redroid proof\n'
}
bash -c "$(declare -f checks); checks" "$ROOT/bin/molt"
