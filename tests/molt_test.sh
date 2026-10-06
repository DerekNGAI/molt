#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOLT="$ROOT/bin/molt"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export MOLT_HOME="$TMP/home"
mkdir -p "$MOLT_HOME" "$TMP/repos/app/src" "$TMP/repos/app-extra"
printf 'MOLT_HOST=test-vm\n' >"$MOLT_HOME/config"
git -C "$TMP/repos/app" init -q
git -C "$TMP/repos/app-extra" init -q
expected_repo="$(git -C "$TMP/repos/app" rev-parse --show-toplevel)"
project_id="$("$MOLT" project-id "$TMP/repos/app")"
[[ "$project_id" =~ ^[a-f0-9]{12}$ ]] || fail 'project identity'
"$MOLT" register "$TMP/repos/app" >/dev/null
[[ "$("$MOLT" project-find "$TMP/repos/app/src")" == "$project_id" ]] || fail 'detect a stopped project from its subdirectory'
if "$MOLT" project-find "$TMP/repos/app-extra"; then fail 'matched a sibling checkout'; fi
mkdir -p "$TMP/repos/app/nested/src"
git -C "$TMP/repos/app/nested" init -q
"$MOLT" register "$TMP/repos/app/nested" >/dev/null
nested_id="$("$MOLT" project-id "$TMP/repos/app/nested")"
[[ "$("$MOLT" project-find "$TMP/repos/app/nested/src")" == "$nested_id" ]] || fail 'use the closest registered repository'
ln -s "$TMP/repos/app" "$TMP/alias"
[[ "$("$MOLT" project-find "$TMP/alias/src")" == "$project_id" ]] || fail 'canonicalize checkout aliases'
[[ "$("$MOLT" scan "$TMP/repos/app")" == "$expected_repo" ]] || fail 'repository scan'
for file in devenv.nix .molt.yml; do [[ ! -e "$TMP/repos/app/$file" ]] || fail "created $file in checkout"; done
for field in runtime package_manager generated_env ports; do [[ ! -e "$MOLT_HOME/projects/$project_id/$field" ]] || fail "retained unused $field"; done
printf 'molt tests: ok\n'
