#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-ports.XXXXXX")"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf -- "$TMP"' EXIT
source "$ROOT/bin/_molt.sh"
source "$ROOT/bin/_opencode.sh"
source "$ROOT/bin/_manage.sh"
log() { printf '%s\n' "$*" >&2; }
die() { log "$*"; exit 1; }
startup_progress() { :; }
read_value() { [[ -f "$1" ]] && IFS= read -r REPLY <"$1" && printf '%s\n' "$REPLY"; }
write_value() { printf '%s\n' "$2" >"$1"; }
export MOLT_HOME="$TMP/home" PROJECT_STATE="$TMP/home/projects/aaaaaaaaaaaa" PROJECT_ID=aaaaaaaaaaaa MOLT_HOST=fixture-vm PROJECT_OPENCODE_PORT=4100
mkdir -p "$PROJECT_STATE" "$MOLT_HOME/state/ssh" "$MOLT_HOME/state/tmp"
# The double simulates SSH's bind result, including an external listener and an ambiguous failure.
ssh() {
  printf '%s\n' "$*" >>"$TMP/ssh.log"
  case "$*" in
    *'-O check'*) printf 'Master running (pid=%s)\n' "$$" >&2 ;;
    *'-O forward'*)
      if [[ "${TUNNEL_FAILURE:-0}" == 1 ]]; then printf 'Control socket disconnected\n' >&2; return 255; fi
      [[ "$*" != *'127.0.0.1:3000:'* ]] || { printf 'bind: Address already in use\n' >&2; return 255; } ;;
    *'-O cancel'*) [[ "${CANCEL_FAILURE:-0}" == 0 ]] || return 255 ;;
  esac
}
curl() { printf '401'; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
printf '4100\n' >"$PROJECT_STATE/forwards"
first="$(molt_forward_allocate app:web 3000 31000)"
[[ "$first" == 3001 ]] || fail "collision allocated $first"
forward_opencode_port
grep -Fq 'app:web' "$PROJECT_STATE/forwards" || fail 'OpenCode overwrote app forward'
grep -Fq 'opencode' "$PROJECT_STATE/forwards" || fail 'legacy integer did not migrate'
mkdir -p "$MOLT_HOME/projects/bbbbbbbbbbbb"
PROJECT_STATE="$MOLT_HOME/projects/bbbbbbbbbbbb" PROJECT_ID=bbbbbbbbbbbb
second="$(molt_forward_allocate app:web 3000 32000)"
[[ "$second" == 3002 ]] || fail "second repository allocated $second"
molt_forward_cancel app:
grep -Fq '127.0.0.1:3002:127.0.0.1:32000' "$TMP/ssh.log" || fail 'did not cancel exact mapping'
PROJECT_STATE="$MOLT_HOME/projects/aaaaaaaaaaaa" PROJECT_ID=aaaaaaaaaaaa
CANCEL_FAILURE=1
if molt_forward_cancel app:; then fail 'failed cancellation erased record'; fi
grep -Fq 'app:web' "$PROJECT_STATE/forwards" || fail 'cleanup retry record lost'
CANCEL_FAILURE=0
molt_forward_cancel app:
grep -Fq 'opencode' "$PROJECT_STATE/forwards" || fail 'app stop cancelled OpenCode'
TUNNEL_FAILURE=1
if molt_forward_allocate app:broken 33000 33001 >/dev/null; then fail 'disconnected tunnel succeeded'; fi
grep -Fq 'app:broken' "$PROJECT_STATE/forwards" || fail 'ambiguous bind lost intent'
TUNNEL_FAILURE=0
cancel_project_forwards
[[ ! -s "$PROJECT_STATE/forwards" ]] || fail 'forward cleanup left active records'
node --test "$ROOT/tests/fixtures/development-runtime/transport.test.mjs"
printf 'PASS: owned allocation/migration/cancellation; SSH/Docker are doubled above\n'
