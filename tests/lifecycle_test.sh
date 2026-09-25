#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-lifecycle.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAKE_BIN="$TMP/bin"
TEST_HOME="$TMP/home"
ZDOTDIR="$TMP/zsh"
mkdir -p "$FAKE_BIN" "$TEST_HOME" "$ZDOTDIR"

cat >"$FAKE_BIN/brew" <<'BREW'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  install) touch "$TEST_BIN/mutagen"; chmod +x "$TEST_BIN/mutagen" ;;
  uninstall) rm -f "$TEST_BIN/mutagen" ;;
  list|tap) exit 1 ;;
  untap) ;;
esac
BREW
chmod +x "$FAKE_BIN/brew"

cat >"$FAKE_BIN/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${CURL_COUNT_FILE:-}" ]]; then
  printf '1\n' >>"$CURL_COUNT_FILE"
fi
cat <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/.opencode/bin"
printf '#!/usr/bin/env bash\n' >"$HOME/.opencode/bin/opencode"
chmod +x "$HOME/.opencode/bin/opencode"
INSTALLER
CURL
chmod +x "$FAKE_BIN/curl"

cat >"$FAKE_BIN/ssh" <<'SSH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${SSH_LOG:-/dev/null}"
SSH
chmod +x "$FAKE_BIN/ssh"

assert_file() {
  [[ -e "$1" ]] || { printf 'missing file: %s\n' "$1" >&2; exit 1; }
}

assert_absent() {
  [[ ! -e "$1" ]] || { printf 'unexpected file: %s\n' "$1" >&2; exit 1; }
}

assert_contains() {
  grep -Fq -- "$1" "$2" || { printf 'missing %s in %s\n' "$1" "$2" >&2; exit 1; }
}

test_install_and_uninstall_custom_home() {
  local molt_home="$TMP/custom-molt" molt_path
  molt_path="$(cd "$molt_home" 2>/dev/null && pwd -P || true)"

  export HOME="$TEST_HOME"
  export ZDOTDIR
  export MOLT_HOME="$molt_home"
  export TEST_BIN="$FAKE_BIN"
  export CURL_COUNT_FILE="$TMP/curl.count"
  export PATH="$FAKE_BIN:/usr/bin:/bin"

  bash "$ROOT/install.sh"
  [[ "$(wc -l <"$CURL_COUNT_FILE" | tr -d ' ')" == 1 ]]
  molt_path="$(cd "$molt_home" && pwd -P)"

  assert_file "$molt_home/bin/molt"
  assert_file "$molt_home/shims/pnpm"
  assert_contains 'MOLT_OPENCODE_PASSWORD_FILE="${MOLT_OPENCODE_PASSWORD_FILE:-$MOLT_HOME/opencode.password}"' "$molt_home/config"
  assert_contains "export MOLT_HOME=\"$molt_path\"" "$ZDOTDIR/.zshrc"
  assert_contains "export PATH=\"$molt_path/shims:$molt_path/bin:$HOME/.opencode/bin:\$PATH\"" "$ZDOTDIR/.zshrc"
  assert_contains 'MUTAGEN_INSTALLED=1' "$molt_home/.install-manifest"
  assert_contains 'OPENCODE_INSTALLED=1' "$molt_home/.install-manifest"
  assert_file "$molt_home/bin/molt-uninstall"

  touch "$molt_home/shims/stale"
  bash "$ROOT/install.sh"
  [[ "$(wc -l <"$CURL_COUNT_FILE" | tr -d ' ')" == 1 ]]
  assert_absent "$molt_home/shims/stale"

  bash "$molt_home/bin/molt-uninstall" --yes
  assert_absent "$molt_home"
  assert_absent "$TEST_HOME/.opencode"
  assert_absent "$FAKE_BIN/mutagen"
  assert_absent "$ZDOTDIR/.zshrc"
}

test_uninstall_preserves_existing_zshrc() {
  local molt_home="$TMP/preserved-molt" original_zshrc

  printf 'export KEEP_ME=1\n\n' >"$ZDOTDIR/.zshrc"
  original_zshrc="$TMP/original.zshrc"
  cp "$ZDOTDIR/.zshrc" "$original_zshrc"

  export HOME="$TEST_HOME"
  export ZDOTDIR
  export MOLT_HOME="$molt_home"
  export TEST_BIN="$FAKE_BIN"
  export PATH="$FAKE_BIN:/usr/bin:/bin"

  bash "$ROOT/install.sh"
  bash "$molt_home/bin/molt-uninstall" --yes
  cmp -s "$original_zshrc" "$ZDOTDIR/.zshrc" || {
    diff -u "$original_zshrc" "$ZDOTDIR/.zshrc" || true
    exit 1
  }
}

test_install_fails_without_mutagen() {
  local molt_home="$TMP/failing-molt" home="$TMP/failing-home"

  mkdir -p "$home"
  export HOME="$home"
  export ZDOTDIR="$TMP/failing-zsh"
  export MOLT_HOME="$molt_home"
  export PATH="/usr/bin:/bin"

  if bash "$ROOT/install.sh" >"$TMP/install-failure.log" 2>&1; then
    printf 'install unexpectedly succeeded without Mutagen\n' >&2
    exit 1
  fi
  assert_contains 'Mutagen is required' "$TMP/install-failure.log"
  assert_absent "$ZDOTDIR/.zshrc"
}

test_reset_removes_remote_project_artifacts() {
  local molt_home="$TMP/project-molt" repo="$TMP/repo" ssh_log="$TMP/ssh.log"
  local project_id state

  mkdir -p "$repo"
  git -C "$repo" init -q
  : >"$FAKE_BIN/mutagen"
  chmod +x "$FAKE_BIN/mutagen"

  export HOME="$TEST_HOME"
  export MOLT_HOME="$molt_home"
  export SSH_LOG="$ssh_log"
  export PATH="$FAKE_BIN:/usr/bin:/bin"

  "$ROOT/bin/molt" register "$repo" >/dev/null
  project_id="$("$ROOT/bin/molt" project-id "$repo")"
  state="$molt_home/projects/$project_id"
  printf '/remote/molt/projects/%s\n' "$project_id" >"$state/remote_path"
  printf '/remote/molt/meta/%s\n' "$project_id" >"$state/remote_meta"
  printf '/remote/.config/opencode\n' >"$state/remote_opencode_config"

  printf 'y\n' | "$ROOT/bin/molt" reset "$repo" >/dev/null
  assert_contains "docker volume rm -f molt-cache-$project_id" "$ssh_log"
  assert_contains "rm -rf -- /remote/molt/projects/$project_id /remote/molt/meta/$project_id" "$ssh_log"
  assert_absent "$state"
}

test_install_and_uninstall_custom_home
test_uninstall_preserves_existing_zshrc
test_install_fails_without_mutagen
test_reset_removes_remote_project_artifacts
printf 'molt lifecycle tests: ok\n'
