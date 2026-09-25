#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOLT="$ROOT/bin/molt"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export MOLT_HOME="$TMP/home"
export PATH="$ROOT/bin:$PATH"
mkdir -p "$MOLT_HOME" "$TMP/repos/app"
git -C "$TMP/repos/app" init -q
printf '{"name":"app","packageManager":"pnpm@9.0.0"}\n' >"$TMP/repos/app/package.json"
touch "$TMP/repos/app/pnpm-lock.yaml"
printf 'ports:\n  - 3000\n  - 4173\n' >"$TMP/repos/app/.molt.yml"

expected_repo="$(git -C "$TMP/repos/app" rev-parse --show-toplevel)"
[[ "$($MOLT scan "$TMP/repos" | sort)" == "$expected_repo" ]]
inspection="$($MOLT inspect "$TMP/repos/app")"
[[ "$inspection" == *"runtime: node"* ]]
[[ "$inspection" == *"package manager: pnpm"* ]]
[[ "$inspection" == *"devenv: missing"* ]]

$MOLT generate-env "$TMP/repos/app"
[[ -f "$TMP/repos/app/devenv.nix" ]]
grep -q 'languages.javascript.enable = true;' "$TMP/repos/app/devenv.nix"
grep -q 'pkgs.pnpm' "$TMP/repos/app/devenv.nix"

project_id="$($MOLT project-id "$TMP/repos/app")"
[[ "$project_id" =~ ^[a-f0-9]{12}$ ]]
$MOLT register "$TMP/repos/app" >/dev/null
printf '1\n' >"$MOLT_HOME/projects/$project_id/active"
grep -qx '3000' "$MOLT_HOME/projects/$project_id/ports"
grep -qx '4173' "$MOLT_HOME/projects/$project_id/ports"
[[ "$($MOLT route "$TMP/repos/app" pnpm dev)" == remote ]]
[[ "$($MOLT route "$TMP/repos/app" git status)" == local ]]

printf 'molt tests: ok\n'
