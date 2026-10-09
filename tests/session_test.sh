#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-sessions.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
source "$ROOT/bin/_molt.sh"
source "$ROOT/bin/_opencode.sh"
source "$ROOT/bin/_docker.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log() { :; }
die() { fail "$*"; }
managed_file() { [[ ! -L "$1" ]] || fail 'symlinked state'; }
write_value() { printf '%s\n' "$2" >"$1"; }
read_value() { [[ ! -f "$1" ]] || IFS= read -r REPLY <"$1"; printf '%s\n' "${REPLY:-}"; }
export MOLT_HOME="$TMP/home" PROJECT_STATE="$TMP/project" PROJECT_ID=aaaaaaaaaaaa PROJECT_NAME=app
export PROJECT_OPENCODE_PORT=4100 MOLT_HOST=test-vm
mkdir -p "$PROJECT_STATE" "$MOLT_HOME/state/tmp"
ssh() { printf '%s\n' "$*" >>"$TMP/ssh.log"; }
curl() { printf '401'; }
forward_opencode_port
forward_opencode_port
if grep -q -- '-O cancel' "$TMP/ssh.log"; then fail 'second attachment cancelled the shared tunnel'; fi
[[ "$(<"$PROJECT_STATE/forwards")" == 4100 ]] || fail 'forward ownership was not recorded'
printf 'PASS: attachments reuse their SSH forward\n'

load_project_state() {
  PROJECT_ACTIVE=1
  PROJECT_RUNTIME_VERSION="$MOLT_RUNTIME_VERSION"
}
load_project() { load_project_state "$PROJECT_STATE"; }
ssh_up() { :; }
prepare_project_dirs() {
  mkdir "$TMP/setup-active" || fail 'simultaneous attachments raced project setup'
  sleep 0.1
  rmdir "$TMP/setup-active"
}
start_sync() { :; }
sync_opencode_config() { :; }
sync_password() { :; }
ensure_container() { :; }
wait_opencode_ready() { :; }
load_project_state "$PROJECT_STATE"
ensure_project_container & first=$!
ensure_project_container & second=$!
wait "$first"
wait "$second"
[[ ! -e "$PROJECT_STATE/start.lock" ]] || fail 'setup lock was not released before attachment'
printf 'PASS: concurrent attachment setup is serialized\n'
