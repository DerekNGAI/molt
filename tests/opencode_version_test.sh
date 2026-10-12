#!/usr/bin/env bash
# Exercise version selection and restart protection without a live VM.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-opencode-version.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
source "$ROOT/bin/_molt.sh"
source "$ROOT/bin/_opencode.sh"
source "$ROOT/bin/_docker.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >>"$TMP/events"; }
die() { fail "$*"; }
managed_file() { [[ ! -L "$1" ]] || fail 'redirected state'; }
quote_remote() { printf '%q ' "$@"; }
read_value() { [[ ! -f "$1" ]] || /bin/cat "$1"; }
write_value() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" >"$1"; }
export MOLT_HOME="$TMP/home" MOLT_INSTALL_ID=0123456789abcdef0123456789abcdef
export PROJECT_ID=aaaaaaaaaaaa PROJECT_STATE="$TMP/project" PROJECT_CONTAINER=fixture
export PROJECT_OPENCODE_PORT=4100 PROJECT_OPENCODE_VERSION=1.18.34
export PROJECT_RUNTIME_VERSION=opencode-5 PROJECT_ACTIVE=1
export SCRIPT_DIR="$ROOT/bin"
mkdir -p "$MOLT_HOME/state/tmp" "$PROJECT_STATE"
printf 'OPENCODE_MANAGED=1\nOPENCODE_BINARY=/fixture/base-client\n' >"$MOLT_HOME/.install-manifest"
SERVER_VERSION=1.18.34 SERVER_ACTIVITY=idle SERVER_RUNNING=true FAIL_NEW_CLIENT=0
load_password() { :; }
forward_opencode_port() { :; }
remote_run() {
  case "$*" in
    *State.Running*) printf '%s\n' "$SERVER_RUNNING" ;;
    *io.molt.installation*) printf '%s\n' "$MOLT_INSTALL_ID" ;;
    *io.molt.opencode*) printf '%s\n' "$SERVER_VERSION" ;;
    *) fail "unexpected VM operation: $*" ;;
  esac
}
opencode_tools() {
  case "$1" in
    latest) printf '1.19.0\n' ;;
    server) printf '%s\n%s\n' "$SERVER_VERSION" "$SERVER_ACTIVITY" ;;
    client)
      if [[ "$2" == 1.19.0 && "$FAIL_NEW_CLIENT" == 1 ]]; then return 1; fi
      printf '/fixture/clients/%s/opencode\n' "$2" ;;
    *) fail "unexpected tool operation: $*" ;;
  esac
}
reset_selection() {
  PROJECT_OPENCODE_TARGET='' PROJECT_OPENCODE_DEFERRED=0
  rm -f "$PROJECT_STATE/opencode_pending"
}

for activity in busy unknown; do
  reset_selection
  SERVER_ACTIVITY="$activity"
  prepare_opencode_version
  [[ "$PROJECT_OPENCODE_TARGET" == 1.18.34 && "$PROJECT_OPENCODE_DEFERRED" == 1 ]] || fail "restart allowed with $activity work"
  [[ "$(<"$PROJECT_STATE/opencode_pending")" == 1.19.0 ]] || fail 'pending update was lost'
done

reset_selection
SERVER_ACTIVITY=idle
other="$MOLT_HOME/state/tmp/client.other"
mkdir "$other"
printf '%s\n' "$PROJECT_ID" >"$other/project"
printf '%s\n' "$$" >"$other/parent.pid"
prepare_opencode_version
[[ "$PROJECT_OPENCODE_TARGET" == 1.18.34 && "$PROJECT_OPENCODE_DEFERRED" == 1 ]] || fail 'attached terminal did not protect the server'
MOLT_CLIENT_WORK="$other"
reset_selection
prepare_opencode_version
[[ "$PROJECT_OPENCODE_TARGET" == 1.19.0 && "$PROJECT_OPENCODE_DEFERRED" == 0 ]] || fail 'launch blocked its own update'
unset MOLT_CLIENT_WORK
rm -rf "$other"

reset_selection
FAIL_NEW_CLIENT=1
prepare_opencode_version
[[ "$PROJECT_OPENCODE_TARGET" == 1.18.34 && "$PROJECT_OPENCODE_DEFERRED" == 1 ]] || fail 'failed client download prevented reuse of the working pair'
FAIL_NEW_CLIENT=0

reset_selection
SERVER_RUNNING=false
SERVER_ACTIVITY=unknown
prepare_opencode_version
[[ "$PROJECT_OPENCODE_TARGET" == 1.19.0 && "$PROJECT_OPENCODE_DEFERRED" == 0 ]] || fail 'stopped workspace did not select the new version'

reset_selection
SERVER_VERSION=1.19.0
PROJECT_OPENCODE_VERSION=1.18.34
prepare_opencode_version
[[ "$PROJECT_OPENCODE_VERSION" == 1.19.0 ]] || fail 'stopped server version was confused with old saved state'

reset_selection
SERVER_RUNNING=true SERVER_ACTIVITY=idle SERVER_VERSION=1.20.0
prepare_opencode_version
[[ "$PROJECT_OPENCODE_TARGET" == 1.20.0 ]] || fail 'release discovery downgraded a newer server'

outside="$TMP/outside-client"
mkdir "$outside"
printf 'keep user data\n' >"$outside/keep"
if (MOLT_CLIENT_WORK="$outside" cmd_client --version) >"$TMP/unsafe-client.log" 2>&1; then fail 'accepted external client worker directory'; fi
[[ -f "$outside/keep" ]] || fail 'client cleanup removed an external directory'

printf 'OPENCODE_MANAGED=0\nOPENCODE_BINARY=/fixture/base-client\n' >"$MOLT_HOME/.install-manifest"
PROJECT_OPENCODE_VERSION=1.19.0
prepare_opencode_version
[[ "$PROJECT_OPENCODE_TARGET" == 1.19.0 ]] || fail 'disabling automatic updates selected an older bundled VM version'

printf 'molt OpenCode version tests: ok\n'
