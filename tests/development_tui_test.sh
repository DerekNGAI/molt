#!/usr/bin/env bash
# Portable live terminal checks through the public CLI ABI; no installer or VM.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ARTIFACTS="${MOLT_DEVELOPMENT_TEST_ARTIFACTS:-$ROOT/artifacts/03-dashboard}"
BINARY=${MOLT_DEVELOPMENT_TEST_BINARY:?Supply the compiled current UI}
[[ -x "$BINARY" ]] || { printf 'BLOCKED: compiled UI unavailable\n' >&2; exit 1; }
EXPECT_BIN=$(command -v expect) || { printf 'BLOCKED: Expect unavailable\n' >&2; exit 1; }
[[ ! -L "$ROOT/artifacts" && ! -L "$ARTIFACTS" ]] || exit 1
mkdir -p "$ARTIFACTS/tmp" "$ARTIFACTS/logs"
FIXTURE=$(mktemp -d "$ARTIFACTS/tmp/development-tui.XXXXXX")
trap '[[ ! -f "$FIXTURE/commands" ]] || cp "$FIXTURE/commands" "$ARTIFACTS/logs/$(basename "$FIXTURE")-commands.log"; rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/home/state/tmp" "$FIXTURE/bin" "$FIXTURE/repos/one/.molt" "$FIXTURE/repos/two/.molt"
cp "$ROOT/tui/testdata/development/cli.sh" "$FIXTURE/bin/molt"
chmod +x "$FIXTURE/bin/molt"
cat >"$FIXTURE/bin/pbcopy" <<'CLIPBOARD'
#!/bin/sh
/bin/cat >"$MOLT_DEVELOPMENT_FIXTURE/clipboard"
CLIPBOARD
chmod +x "$FIXTURE/bin/pbcopy"
for entry in 'aaaaaaaaaaaa one App-One' 'bbbbbbbbbbbb two App-Two'; do
  read -r id directory name <<<"$entry"
  state="$FIXTURE/home/projects/$id"
  mkdir -p "$state"
  printf '%s\n' "$name" >"$state/name"
  printf '%s\n' "$FIXTURE/repos/$directory" >"$state/path"
  printf 'fixture-vm\n' >"$state/host"
  printf '1\n' >"$state/active"
  cp "$ROOT/tui/testdata/development/profile.json" "$FIXTURE/repos/$directory/.molt/development.json"
done
export MOLT_HOME="$FIXTURE/home" MOLT_DEVELOPMENT_FIXTURE="$FIXTURE" MOLT_DEVELOPMENT_TEST_BINARY="$BINARY"
export PATH="$FIXTURE/bin:$PATH" TERM=xterm-256color NO_COLOR=1
export MOLT_DEVELOPMENT_TUI_LOG="$ARTIFACTS/logs/$(basename "$FIXTURE").log"
"$EXPECT_BIN" "$ROOT/tests/development_tui_test.exp"
cp "$FIXTURE/commands" "$ARTIFACTS/logs/development-cli-commands.log"
printf 'molt development terminal tests: ok\n'
