#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-lifecycle.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/zsh"
export HOME="$TMP/home" ZDOTDIR="$TMP/zsh" PATH="$TMP/bin:/usr/bin:/bin"
export MOLT_MUTAGEN_BINARY="$TMP/bin/mutagen" MOLT_OPENCODE_BINARY="$TMP/bin/opencode"

cat >"$TMP/bin/mutagen" <<'TOOL'
#!/usr/bin/env bash
MUTAGEN_DATA_DIRECTORY="${MUTAGEN_DATA_DIRECTORY:-$HOME/.mutagen}"
case "$*" in
  version) printf '0.18.1\n' ;;
  'sync create'*)
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --name ]]; then mkdir -p "$MUTAGEN_DATA_DIRECTORY/sessions"; printf '%s\n' "$2" >"$MUTAGEN_DATA_DIRECTORY/sessions/$$.name"; fi
      shift
    done ;;
  'sync list'*)
    [[ "${FAIL_SYNC:-0}" == 0 ]] || exit 1
    for file in "$MUTAGEN_DATA_DIRECTORY/sessions/"*.name; do [[ ! -f "$file" ]] || cat "$file"; done ;;
  'sync terminate'*)
    [[ "${FAIL_SYNC:-0}" == 0 ]] || exit 1
    for file in "$MUTAGEN_DATA_DIRECTORY/sessions/"*.name; do
      [[ ! -f "$file" || "$(<"$file")" != "${3:-}" ]] || rm "$file"
    done ;;
  'sync flush'*)
    count=0
    for file in "$MUTAGEN_DATA_DIRECTORY/sessions/"*.name; do
      [[ ! -f "$file" || "$(<"$file")" != "${3:-}" ]] || count=$((count+1))
    done
    [[ "$count" -le 1 ]] || { printf 'duplicate project sessions\n' >&2; exit 1; } ;;
  'daemon stop') [[ "${FAIL_STOP:-0}" == 0 ]] || exit 1 ;;
esac
TOOL
cat >"$TMP/bin/opencode" <<'TOOL'
#!/usr/bin/env bash
if [[ "$*" == --version ]]; then printf '1.18.33\n';
elif [[ "$*" == --hold ]]; then sleep 60 & wait;
else env; fi
TOOL
cat >"$TMP/bin/ssh" <<'TOOL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HOME/ssh.log"
exit 255
TOOL
cat >"$TMP/bin/curl" <<'TOOL'
#!/usr/bin/env bash
exit 22
TOOL
chmod +x "$TMP/bin/"*

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
absent() { [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected $1"; }
contains() { grep -Fq -- "$1" "$2" || fail "missing $1 in $2"; }
install() { /bin/bash "$ROOT/install.sh" >"$TMP/install.log" 2>&1; }

test_contained_install() (
  export MOLT_HOME="$HOME/molt with spaces"
  printf 'export KEEP_ME=1\n' >"$ZDOTDIR/.zshrc"
  cp "$ZDOTDIR/.zshrc" "$TMP/original.zshrc"
  install
  cmp -s "$TMP/original.zshrc" "$ZDOTDIR/.zshrc" || fail 'installation changed .zshrc'
  [[ -x "$MOLT_HOME/bin/molt-uninstall" && -f "$MOLT_HOME/activate.zsh" ]] || fail 'missing installation files'
  contains 'FORMAT=2' "$MOLT_HOME/.install-manifest"
  printf 'keep password\n' >"$MOLT_HOME/opencode.password"
  printf '\n# keep config\n' >>"$MOLT_HOME/config"
  install
  contains 'keep password' "$MOLT_HOME/opencode.password"
  contains '# keep config' "$MOLT_HOME/config"
  /bin/zsh -f -c 'source "$MOLT_HOME/activate.zsh"; before="$PATH"; source "$MOLT_HOME/activate.zsh"; [[ "$before" == "$PATH" ]]' || fail 'activation is not idempotent'
  "$MOLT_HOME/bin/molt" client --diagnostic >"$TMP/client.env"
  contains "XDG_DATA_HOME=$MOLT_HOME/state/data" "$TMP/client.env"
  contains "TMPDIR=$MOLT_HOME/state/tmp" "$TMP/client.env"
  mkdir -p "$MOLT_HOME/state/home/.mutagen/daemon"
  export FAIL_STOP=1
  "$MOLT_HOME/bin/molt-uninstall" --yes || fail 'removal failed for an already-stopped daemon'
  absent "$MOLT_HOME"
  absent "$HOME/ssh.log"
  cmp -s "$TMP/original.zshrc" "$ZDOTDIR/.zshrc" || fail 'uninstallation changed .zshrc'
  [[ -x "$MOLT_MUTAGEN_BINARY" && -x "$MOLT_OPENCODE_BINARY" ]] || fail 'removed external dependency'
  /bin/bash "$ROOT/uninstall.sh" --yes
)

test_path_safety() (
  local candidate
  for candidate in "$HOME" "$HOME/" "$HOME/." / // "$ROOT" "$ROOT/child"; do
    export MOLT_HOME="$candidate"
    if install; then fail "accepted unsafe path $candidate"; fi
  done
  export MOLT_HOME="$HOME/unrelated"
  mkdir -p "$MOLT_HOME/bin"
  printf 'keep\n' >"$MOLT_HOME/bin/important"
  if install; then fail 'accepted unrelated directory'; fi
  if /bin/bash "$ROOT/uninstall.sh" --yes; then fail 'deleted unowned directory'; fi
  contains 'keep' "$MOLT_HOME/bin/important"
  ln -s "$HOME" "$TMP/home-link"
  export MOLT_HOME="$TMP/home-link/."
  if install; then fail 'accepted home symlink alias'; fi
)

test_failed_install_and_upgrade() (
  export MOLT_HOME="$HOME/failed-install"
  export MOLT_MUTAGEN_BINARY="" MOLT_OPENCODE_BINARY=""
  # Removing tools from PATH forces an actual download attempt through failing curl.
  mkdir -p "$TMP/download-bin"
  cp "$TMP/bin/curl" "$TMP/download-bin/curl"
  export PATH="$TMP/download-bin:/usr/bin:/bin"
  if install; then fail 'download failure succeeded'; fi
  absent "$MOLT_HOME"
  export PATH="$TMP/bin:/usr/bin:/bin"
  export MOLT_MUTAGEN_BINARY="$TMP/bin/mutagen" MOLT_OPENCODE_BINARY="$TMP/bin/opencode"
  install
  cp "$MOLT_HOME/.install-manifest" "$TMP/working.manifest"
  export MOLT_OPENCODE_BINARY="$TMP/missing-opencode"
  if install; then fail 'invalid executable accepted'; fi
  cmp -s "$TMP/working.manifest" "$MOLT_HOME/.install-manifest" || fail 'failed upgrade changed manifest'
  "$MOLT_HOME/bin/molt" help >/dev/null || fail 'failed upgrade broke installation'
  export MOLT_OPENCODE_BINARY="$TMP/bin/opencode"
  "$MOLT_HOME/bin/molt-uninstall" --yes
)

test_checksum_failure_and_interrupted_install() (
  export MOLT_HOME="$HOME/checksum-failure" MOLT_MUTAGEN_BINARY="" MOLT_OPENCODE_BINARY=""
  mkdir -p "$TMP/corrupt-download"
  cat >"$TMP/corrupt-download/curl" <<'CURL'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -o ]]; then printf 'corrupt archive\n' >"$2"; exit 0; fi
  shift
done
exit 1
CURL
  chmod +x "$TMP/corrupt-download/curl"
  export PATH="$TMP/corrupt-download:/usr/bin:/bin"
  if install; then fail 'checksum mismatch accepted'; fi
  contains 'checksum mismatch' "$TMP/install.log"
  absent "$MOLT_HOME"
  export PATH="$TMP/bin:/usr/bin:/bin" MOLT_MUTAGEN_BINARY="$TMP/bin/mutagen" MOLT_OPENCODE_BINARY="$TMP/bin/opencode"
  mkdir -p "$MOLT_HOME"
  printf 'FORMAT=2\nINSTALL_ID=0123456789abcdef0123456789abcdef\nROOT=%s\nSTATUS=installing\n' "$MOLT_HOME" >"$MOLT_HOME/.install-manifest"
  ln -s releases/interrupted "$MOLT_HOME/current.next"
  install
  "$MOLT_HOME/bin/molt" help >/dev/null
  "$MOLT_HOME/bin/molt-uninstall" --yes
)

test_literal_paths() (
  export MOLT_HOME="$HOME/molt \"\$literal\`backtick\`"
  install
  /bin/zsh -f -c 'source "$MOLT_HOME/activate.zsh"; [[ -x "$MOLT_HOME/bin/molt" ]]'
  "$MOLT_HOME/bin/molt" client --version >/dev/null
  "$MOLT_HOME/bin/molt-uninstall" --yes
  absent "$MOLT_HOME"
)

test_install_lock_and_tool_repair() (
  export MOLT_HOME="$HOME/repair"
  cp "$TMP/bin/mutagen" "$TMP/repair-mutagen"
  export MOLT_MUTAGEN_BINARY="$TMP/repair-mutagen"
  install
  mkdir -p "$MOLT_HOME/state/install.lock"
  printf '%s\n' "$$" >"$MOLT_HOME/state/install.lock/pid"
  if install; then fail 'concurrent installer was accepted'; fi
  printf '99999999\n' >"$MOLT_HOME/state/install.lock/pid"
  install
  rm "$TMP/repair-mutagen"
  mkdir -p "$MOLT_HOME/state/home/.mutagen/daemon"
  export MOLT_MUTAGEN_BINARY="$TMP/bin/mutagen"
  install || { fail 'could not repair a removed Mutagen executable'; }
  "$MOLT_HOME/bin/molt-uninstall" --yes
)

test_failed_commit_restores_release() (
  export MOLT_HOME="$HOME/commit-failure"
  install
  local original
  original="$(readlink "$MOLT_HOME/current")"
  mkdir -p "$TMP/failing-mv"
  cat >"$TMP/failing-mv/mv" <<'MV'
#!/usr/bin/env bash
if [[ "${!#}" == "$MOLT_HOME/.install-manifest" && "$1" == */manifest ]]; then exit 1; fi
exec /bin/mv "$@"
MV
  chmod +x "$TMP/failing-mv/mv"
  export PATH="$TMP/failing-mv:$PATH"
  if install; then fail 'failed manifest commit succeeded'; fi
  [[ "$(readlink "$MOLT_HOME/current")" == "$original" ]] || fail 'failed commit replaced the working release'
  "$MOLT_HOME/bin/molt" help >/dev/null
  "$MOLT_HOME/bin/molt-uninstall" --yes
)

test_containment_rejects_symlinks() (
  export MOLT_HOME="$HOME/symlink-state"
  install
  mkdir -p "$TMP/outside"
  rmdir "$MOLT_HOME/state/cache"
  ln -s "$TMP/outside" "$MOLT_HOME/state/cache"
  if "$MOLT_HOME/bin/molt" client --version; then fail 'accepted state directory outside installation'; fi
  rm "$MOLT_HOME/state/cache"
  mkdir -p "$MOLT_HOME/state/cache"
  ln -s "$TMP/outside" "$MOLT_HOME/state/config/opencode"
  if "$MOLT_HOME/bin/molt" client --version; then fail 'accepted external tool configuration symlink'; fi
  rm "$MOLT_HOME/state/config/opencode"
  ln -s "$TMP/outside/password" "$MOLT_HOME/opencode.password.next"
  rm "$MOLT_HOME/opencode.password"
  mv "$MOLT_HOME/opencode.password.next" "$MOLT_HOME/opencode.password"
  if install; then fail 'accepted password symlink outside installation'; fi
)

test_local_down_stops_clients() (
  export MOLT_HOME="$HOME/client-stop"
  install
  "$MOLT_HOME/bin/molt" client --hold &
  local client=$! attempt ready=0
  for attempt in {1..50}; do
    for file in "$MOLT_HOME/state/tmp"/client.*/parent.pid; do [[ ! -f "$file" ]] || ready=1; done
    [[ "$ready" == 0 ]] || break
    sleep 0.05
  done
  "$MOLT_HOME/bin/molt" local-down
  if kill -0 "$client" 2>/dev/null; then kill "$client"; fail 'local-down left a client process'; fi
  wait "$client" 2>/dev/null || true
  "$MOLT_HOME/bin/molt-uninstall" --yes
)

test_legacy_shell_migration() (
  export MOLT_HOME="$HOME/legacy"
  mkdir -p "$MOLT_HOME/bin" "$MOLT_HOME/shims" "$TMP/dotfiles"
  printf 'export KEEP=1\n\n# molt\nexport MOLT_HOME="%s"\nexport PATH="%s/shims:%s/bin:%s/.opencode/bin:$PATH"\n' "$MOLT_HOME" "$MOLT_HOME" "$MOLT_HOME" "$HOME" >"$TMP/dotfiles/zshrc"
  rm -f "$ZDOTDIR/.zshrc"
  ln -s "$TMP/dotfiles/zshrc" "$ZDOTDIR/.zshrc"
  cat >"$MOLT_HOME/.install-manifest" <<EOF
ZSHRC=$ZDOTDIR/.zshrc
MOLT_HOME_LINE=export MOLT_HOME="$MOLT_HOME"
PATH_LINE=export PATH="$MOLT_HOME/shims:$MOLT_HOME/bin:$HOME/.opencode/bin:\$PATH"
ZSHRC_CREATED=0
PATH_ADDED=1
MUTAGEN_INSTALLED=1
OPENCODE_INSTALLED=1
EOF
  install
  [[ -L "$ZDOTDIR/.zshrc" ]] || fail 'migration replaced shell symlink'
  [[ "$(<"$TMP/dotfiles/zshrc")" == 'export KEEP=1' ]] || fail 'legacy shell entries remain'
  [[ -f "$MOLT_HOME/legacy-install-manifest" ]] || fail 'legacy ownership record lost'
  "$MOLT_HOME/bin/molt-uninstall" --yes
)

test_offline_uninstall() (
  export MOLT_HOME="$HOME/offline"
  install
  mkdir -p "$TMP/repo"
  git -C "$TMP/repo" init -q
  "$MOLT_HOME/bin/molt" register "$TMP/repo" >/dev/null
  local id state
  id="$("$MOLT_HOME/bin/molt" project-id "$TMP/repo")"
  state="$MOLT_HOME/projects/$id"
  printf '/remote/molt/projects/%s\n' "$id" >"$state/remote_path"
  printf '/remote/molt/meta/%s\n' "$id" >"$state/remote_meta"
  printf 'recorded-host\n' >"$state/host"
  printf '\nMOLT_HOST=changed-host\n' >>"$MOLT_HOME/config"
  if "$MOLT_HOME/bin/molt-uninstall" --yes; then fail 'offline uninstall discarded state'; fi
  [[ -f "$state/path" && -f "$MOLT_HOME/.install-manifest" ]] || fail 'cleanup failure lost retry records'
  contains 'recorded-host' "$HOME/ssh.log"
  "$MOLT_HOME/bin/molt-uninstall" --yes --local-only >"$TMP/local-only.log" 2>&1
  contains 'recorded-host' "$TMP/local-only.log"
  contains "/remote/molt/projects/$id" "$TMP/local-only.log"
  absent "$MOLT_HOME"
)

test_remote_lifecycle() (
  export MOLT_HOME="$HOME/remote-test" TEST_REMOTE_HOME="$TMP/vm-home" TEST_DOCKER="$TMP/docker-state" TEST_ROOT="$ROOT"
  mkdir -p "$TEST_REMOTE_HOME" "$TEST_DOCKER" "$TMP/remote-bin" "$TMP/remote-repo"
  cp "$TMP/bin/mutagen" "$TMP/remote-bin/mutagen"
  cp "$TMP/bin/opencode" "$TMP/remote-bin/opencode"
  cat >"$TMP/remote-bin/ssh" <<'SSH'
#!/usr/bin/env bash
for arg in "$@"; do [[ "$arg" != -O ]] || exit 0; done
last="${!#}"
HOME="$TEST_REMOTE_HOME" /bin/bash -c "$last"
SSH
  cat >"$TMP/remote-bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -eu
case "$1 ${2:-}" in
  'info '*) exit 0 ;;
  'container ls'*) [[ ! -f "$TEST_DOCKER/container" ]] || cat "$TEST_DOCKER/container" ;;
  'image ls'*) [[ ! -f "$TEST_DOCKER/image" ]] || cat "$TEST_DOCKER/image" ;;
  'volume ls'*) ;;
  'inspect '*|'image inspect')
    if [[ "${FAIL_OWNER:-0}" == 1 ]]; then printf 'other-installation\n';
    elif [[ "$*" == *io.molt.project* ]]; then last="${!#}"; last="${last%:latest}"; printf '%s\n' "${last##*-}";
    else printf '%s\n' "$MOLT_INSTALL_ID"; fi ;;
  'build '*)
    [[ "${HOLD_BUILD:-0}" == 0 ]] || sleep 60
    shift; while [[ $# -gt 0 ]]; do if [[ "$1" == --tag ]]; then printf '%s\n' "$2" >"$TEST_DOCKER/image"; fi; shift; done ;;
  'run '*) shift; while [[ $# -gt 0 ]]; do if [[ "$1" == --name ]]; then printf '%s\n' "$2" >"$TEST_DOCKER/container"; fi; shift; done ;;
  'rm '*) [[ "${FAIL_DOCKER:-0}" == 0 ]] || exit 1; rm -f "$TEST_DOCKER/container" ;;
  'image rm') [[ "${FAIL_DOCKER:-0}" == 0 ]] || exit 1; rm -f "$TEST_DOCKER/image" ;;
  'exec '*) ;;
  'stop '*) ;;
  *) printf 'unexpected docker: %s\n' "$*" >&2; exit 2 ;;
esac
DOCKER
  # The remote contract is Linux; provide GNU realpath semantics on the test Mac.
  cat >"$TMP/remote-bin/realpath" <<'REALPATH'
#!/usr/bin/env bash
source "$TEST_ROOT/bin/_molt.sh"
[[ "${1:-}" != -m ]] || shift
[[ "${1:-}" != -- ]] || shift
molt_canonical "$1"
REALPATH
  chmod +x "$TMP/remote-bin/"*
  export PATH="$TMP/remote-bin:/usr/bin:/bin"
  install
  printf '\nMOLT_HOST=test-vm\n' >>"$MOLT_HOME/config"
  "$MOLT_HOME/bin/molt" setup
  absent "$TEST_REMOTE_HOME/.molt"
  absent "$TEST_REMOTE_HOME/.config/opencode"
  [[ -f "$TEST_REMOTE_HOME/molt/.install-manifest" ]] || fail 'missing remote ownership marker'
  git -C "$TMP/remote-repo" init -q
  printf '{"name":"test"}\n' >"$TMP/remote-repo/package.json"
  "$MOLT_HOME/bin/molt" start "$TMP/remote-repo"
  (cd "$TMP/remote-repo" && "$MOLT_HOME/bin/molt" run true)
  "$MOLT_HOME/bin/molt" stop "$TMP/remote-repo"
  "$MOLT_HOME/bin/molt" start "$TMP/remote-repo"
  absent "$TMP/remote-repo/devenv.nix"
  local id state
  id="$("$MOLT_HOME/bin/molt" project-id "$TMP/remote-repo")"
  state="$MOLT_HOME/projects/$id"
  [[ -f "$TEST_REMOTE_HOME/molt/meta/$id/env/devenv.nix" ]] || fail 'generated environment is not contained'
  export FAIL_SYNC=1
  if MOLT_ASSUME_YES=1 "$MOLT_HOME/bin/molt" reset --all; then fail 'sync failure succeeded'; fi
  [[ -f "$state/path" ]] || fail 'lost sync cleanup records'
  export FAIL_SYNC=0 FAIL_DOCKER=1
  if MOLT_ASSUME_YES=1 "$MOLT_HOME/bin/molt" reset --all; then fail 'cleanup failure succeeded'; fi
  [[ -f "$state/path" ]] || fail 'lost cleanup records'
  export FAIL_DOCKER=0 FAIL_OWNER=1
  if MOLT_ASSUME_YES=1 "$MOLT_HOME/bin/molt" reset --all; then fail 'removed a resource with different ownership'; fi
  [[ -f "$state/path" && -f "$TEST_DOCKER/container" ]] || fail 'ownership failure discarded resource or record'
  export FAIL_OWNER=0
  mkdir -p "$TMP/outside-vm"
  rmdir "$TEST_REMOTE_HOME/molt/cache/$id/home"
  ln -s "$TMP/outside-vm" "$TEST_REMOTE_HOME/molt/cache/$id/home"
  if (cd "$TMP/remote-repo" && "$MOLT_HOME/bin/molt" run true); then fail 'accepted a remote cache symlink outside the owned root'; fi
  rm "$TEST_REMOTE_HOME/molt/cache/$id/home"
  mkdir "$TEST_REMOTE_HOME/molt/cache/$id/home"
  export HOLD_BUILD=1
  "$MOLT_HOME/bin/molt" start "$TMP/remote-repo" >"$TMP/held-start.log" 2>&1 &
  local starter=$! attempt ready=0
  for attempt in {1..50}; do
    for file in "$MOLT_HOME/state/tmp"/start.*/parent.pid; do [[ ! -f "$file" ]] || ready=1; done
    [[ "$ready" == 0 ]] || break
    sleep 0.05
  done
  "$MOLT_HOME/bin/molt" local-down
  if kill -0 "$starter" 2>/dev/null; then
    source "$ROOT/bin/_molt.sh"
    molt_kill_tree "$starter"
    wait "$starter" 2>/dev/null || true
    fail 'local-down left a startup process'
  fi
  wait "$starter" 2>/dev/null || true
  export HOLD_BUILD=0
  rm -rf "$TMP/remote-repo"
  "$MOLT_HOME/bin/molt-uninstall" --yes
  absent "$MOLT_HOME"
  absent "$TEST_REMOTE_HOME/molt"
  absent "$TEST_DOCKER/container"
  absent "$TEST_DOCKER/image"
)

for test in ${*:-test_contained_install test_path_safety test_failed_install_and_upgrade test_checksum_failure_and_interrupted_install test_literal_paths test_install_lock_and_tool_repair test_failed_commit_restores_release test_containment_rejects_symlinks test_local_down_stops_clients test_legacy_shell_migration test_offline_uninstall test_remote_lifecycle}; do
  "$test"
  printf 'PASS: %s\n' "$test"
done
printf 'molt lifecycle tests: ok\n'
