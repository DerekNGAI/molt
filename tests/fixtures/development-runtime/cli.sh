#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-dev-cli.XXXXXX")"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf -- "$TMP"' EXIT
export MOLT_HOME="$TMP/home"
mkdir -p "$MOLT_HOME/projects/aaaaaaaaaaaa" "$TMP/repo/.molt"
printf 'FORMAT=2\nROOT=%s\nINSTALL_ID=0123456789abcdef0123456789abcdef\n' "$MOLT_HOME" >"$MOLT_HOME/.install-manifest"
export ROOT TMP
check_cli() {
source "$ROOT/bin/molt" help >/dev/null
source "$ROOT/bin/_development.sh"
source "$ROOT/bin/_android.sh"
PROJECT_STATE="$MOLT_HOME/projects/aaaaaaaaaaaa" PROJECT_PATH="$TMP/repo" PROJECT_ID=aaaaaaaaaaaa PROJECT_NAME=fixture PROJECT_HOST=fixture-vm MOLT_HOST=fixture-vm PROJECT_REMOTE_HOME=''
printf '{"version":1,"name":"Fixture","actions":[],"ports":[],"android":{"enabled":false}}\n' >"$PROJECT_PATH/.molt/development.json"
development_tools() { "$MOLT_DEVELOPMENT_TEST_BINARY" development-tools "$@"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
before="$(ls -A "$PROJECT_STATE")"
status="$(development_dispatch status --json)"
[[ "$(printf '%s' "$status" | development_json 'return value.environment.state')" == unknown ]] || fail 'unavailable VM inferred ready'
[[ "$(ls -A "$PROJECT_STATE")" == "$before" ]] || fail 'status created local state'
for arguments in 'status --json extra' 'ports' 'cache --json extra' 'run' 'stop extra' 'clean-cache --yes --revision bad' 'android reset' 'android check --json'; do
  rc=0
  # Test strings contain fixture literals only.
  development_dispatch $arguments >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 2 ]] || fail "invalid syntax $arguments returned $rc"
done
development_rpc() {
  case "$1" in
    runtime) printf '{"profile":{"ports":[{"id":"web","local_port":3000},{"id":"api","local_port":3001}]}}' ;;
    status) printf '{"services":[{"id":"web","state":"running"},{"id":"api","state":"%s"}],"ports":[{"id":"web","service":"web","vm_port":31000,"scheme":"http"},{"id":"api","service":"api","vm_port":31001,"scheme":"http"}]}' "$api_state" ;;
  esac
}
remote_run() { :; }
molt_forward_allocate() { printf '%s\n' "$1" >>"$TMP/allocated"; printf '%s\n' "$2"; }
development_exec() { [[ "$1" == restore ]]; }
api_state=stopped
development_restore_forwards >/dev/null 2>&1
[[ "$(<"$TMP/allocated")" == app:web ]] || fail 'forwarded a stopped service'
printf 'app:web\tfixture-vm\t3000\t31000\tactive\tunknown\n' >"$PROJECT_STATE/forwards"
printf '{"desired":true}' | development_local_write
: >"$TMP/allocated"
api_state=running
development_workspace_ready >/dev/null 2>&1
[[ "$(<"$TMP/allocated")" == app:web ]] || fail 'reconnect created an unrequested forward'
printf 'PASS: sourceable hooks and strict CLI/unknown/read-only status\n'
}
bash -c "$(declare -f check_cli); check_cli" "$ROOT/bin/molt"
