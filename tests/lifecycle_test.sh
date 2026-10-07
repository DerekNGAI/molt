#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-lifecycle.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'chmod -R u+rwX "$TMP"; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/zsh"
export HOME="$TMP/home" ZDOTDIR="$TMP/zsh" PATH="$TMP/bin:/usr/bin:/bin"
export MOLT_MUTAGEN_BINARY="$TMP/bin/mutagen" MOLT_OPENCODE_BINARY="$TMP/bin/opencode"
export MOLT_GUM_BINARY="$TMP/bin/gum"

cat >"$TMP/bin/mutagen" <<'TOOL'
#!/usr/bin/env bash
MUTAGEN_DATA_DIRECTORY="${MUTAGEN_DATA_DIRECTORY:-$HOME/.mutagen}"
[[ -z "${TEST_EVENTS:-}" ]] || printf 'mutagen %s\n' "$*" >>"$TEST_EVENTS"
case "$*" in
  version) printf '0.18.1\n' ;;
  'sync create'*)
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --name ]]; then mkdir -p "$MUTAGEN_DATA_DIRECTORY/sessions"; printf '%s\n' "$2" >"$MUTAGEN_DATA_DIRECTORY/sessions/$$.name"; fi
      shift
    done ;;
  'sync list'*)
    [[ "${FAIL_SYNC:-0}" == 0 ]] || exit 1
    if [[ "$*" == *SessionState* ]]; then
      [[ "${TEST_SYNC_CONFLICTS:-0}" == 0 ]] || printf 'blocked\n'
      exit 0
    fi
    for file in "$MUTAGEN_DATA_DIRECTORY/sessions/"*.name; do [[ ! -f "$file" ]] || cat "$file"; done ;;
  'sync terminate'*)
    [[ "${FAIL_SYNC:-0}" == 0 ]] || exit 1
    for file in "$MUTAGEN_DATA_DIRECTORY/sessions/"*.name; do
      [[ ! -f "$file" || "$(<"$file")" != "${3:-}" ]] || rm "$file"
    done
    rm -f "$MUTAGEN_DATA_DIRECTORY/paused-${3:-}" ;;
  'sync pause'*) : >"$MUTAGEN_DATA_DIRECTORY/paused-${3:-}" ;;
  'sync resume'*) rm -f "$MUTAGEN_DATA_DIRECTORY/paused-${3:-}" ;;
  'sync flush'*)
    [[ ! -f "$MUTAGEN_DATA_DIRECTORY/paused-${3:-}" ]] || { printf 'cannot flush a paused session\n' >&2; exit 1; }
    count=0
    for file in "$MUTAGEN_DATA_DIRECTORY/sessions/"*.name; do
      [[ ! -f "$file" || "$(<"$file")" != "${3:-}" ]] || count=$((count+1))
    done
    [[ "$count" -le 1 ]] || { printf 'duplicate project sessions\n' >&2; exit 1; } ;;
  'daemon stop')
    [[ "${FAIL_STOP:-0}" == 0 ]] || exit 1
    rm -f "$MUTAGEN_DATA_DIRECTORY/daemon/daemon.sock" ;;
esac
TOOL
cat >"$TMP/bin/opencode" <<'TOOL'
#!/usr/bin/env bash
if [[ "$*" == --version ]]; then printf '1.18.34\n';
elif [[ "$*" == --hold ]]; then sleep 60 & wait;
elif [[ "${!#}" == --diagnostic-state ]]; then
  [[ -f "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json" ]] || exit 3
  [[ -f "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/account.json" ]] || exit 4
  grep -Fq '"openai/gpt-6.1-sol":"xhigh"' "${XDG_STATE_HOME:-$HOME/.local/state}/opencode/model.json" || exit 5
else
  [[ -z "${TEST_CLIENT_ARGS:-}" ]] || printf '%s\n' "$@" >"$TEST_CLIENT_ARGS"
  env
fi
TOOL
cat >"$TMP/bin/gum" <<'TOOL'
#!/usr/bin/env bash
printf 'gum version v2.0.2 (test)\n'
TOOL
cat >"$TMP/bin/ssh" <<'TOOL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HOME/ssh.log"
exit 255
TOOL
cat >"$TMP/bin/curl" <<'TOOL'
#!/usr/bin/env bash
case "$*" in
  *http://127.0.0.1:*/global/health*) [[ "${FAIL_TUNNEL:-0}" == 0 ]] || exit 56; printf '401' ;;
  *) exit 22 ;;
esac
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
  for shim in "$MOLT_HOME/shims/"*; do
    [[ "${shim##*/}" == opencode ]] || fail "installed development command shim: $shim"
  done
  contains 'FORMAT=2' "$MOLT_HOME/.install-manifest"
  printf 'keep password\n' >"$MOLT_HOME/opencode.password"
  printf '\n# keep config\n' >>"$MOLT_HOME/config"
  install
  contains 'keep password' "$MOLT_HOME/opencode.password"
  contains '# keep config' "$MOLT_HOME/config"
  /bin/zsh -f -c 'source "$MOLT_HOME/activate.zsh"; before="$PATH"; source "$MOLT_HOME/activate.zsh"; [[ "$before" == "$PATH" ]]' || fail 'activation is not idempotent'
  local native="$TMP/native client"
  export XDG_DATA_HOME="$native/data" XDG_CONFIG_HOME="$native/config" XDG_STATE_HOME="$native/state" XDG_CACHE_HOME="$native/cache" TMPDIR="$native/tmp"
  mkdir -p "$XDG_DATA_HOME/opencode" "$XDG_STATE_HOME/opencode" "$XDG_CONFIG_HOME/opencode" "$XDG_CACHE_HOME" "$TMPDIR"
  printf '{"test-provider":{"type":"api","key":"fixture"}}\n' >"$XDG_DATA_HOME/opencode/auth.json"
  printf '{"accounts":[],"active":null}\n' >"$XDG_DATA_HOME/opencode/account.json"
  printf '{"variant":{"openai/gpt-6.1-sol":"xhigh"}}\n' >"$XDG_STATE_HOME/opencode/model.json"
  "$MOLT_HOME/bin/molt" client --diagnostic >"$TMP/client.env"
  contains "HOME=$HOME" "$TMP/client.env"
  contains "XDG_DATA_HOME=$XDG_DATA_HOME" "$TMP/client.env"
  contains "XDG_STATE_HOME=$XDG_STATE_HOME" "$TMP/client.env"
  contains "XDG_CONFIG_HOME=$XDG_CONFIG_HOME" "$TMP/client.env"
  contains "XDG_CACHE_HOME=$XDG_CACHE_HOME" "$TMP/client.env"
  contains "TMPDIR=$TMPDIR" "$TMP/client.env"
  if grep -Fq 'OPENCODE_DISABLE_PROJECT_CONFIG=1' "$TMP/client.env"; then fail 'local project configuration was disabled'; fi
  "$MOLT_HOME/bin/molt" client --diagnostic-state || fail 'Mac client lost its accounts or saved xhigh preference'
  MOLT_LOCAL=1 "$MOLT_HOME/shims/opencode" --diagnostic-state || fail 'MOLT_LOCAL lost normal OpenCode state'
  (cd "$TMP" && "$MOLT_HOME/shims/opencode" --diagnostic-state) || fail 'unregistered project lost normal OpenCode state'
  "$MOLT_HOME/bin/molt" client attach http://fixture --diagnostic-state || fail 'attached client lost normal OpenCode preferences'
  mkdir -p "$MOLT_HOME/state/home/.mutagen/daemon"
  export FAIL_STOP=1
  "$MOLT_HOME/bin/molt-uninstall" --yes || fail 'removal failed for an already-stopped daemon'
  absent "$MOLT_HOME"
  absent "$HOME/ssh.log"
  cmp -s "$TMP/original.zshrc" "$ZDOTDIR/.zshrc" || fail 'uninstallation changed .zshrc'
  [[ -x "$MOLT_MUTAGEN_BINARY" && -x "$MOLT_OPENCODE_BINARY" ]] || fail 'removed external dependency'
  [[ -f "$XDG_DATA_HOME/opencode/auth.json" && -f "$XDG_DATA_HOME/opencode/account.json" ]] || fail 'uninstall removed normal accounts'
  contains '"openai/gpt-6.1-sol":"xhigh"' "$XDG_STATE_HOME/opencode/model.json"
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
  "$MOLT_HOME/bin/molt" config set MOLT_HOST test-vm
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
  export MOLT_HOME="$HOME/remote-test" TEST_REMOTE_HOME="$TMP/vm-home" TEST_DOCKER="$TMP/docker-state" TEST_ROOT="$ROOT" TEST_CLIENT_ARGS="$TMP/client.args" TEST_EVENTS="$TMP/start-events"
  mkdir -p "$TEST_REMOTE_HOME" "$TEST_DOCKER" "$TMP/remote-bin" "$TMP/remote-repo"
  cp "$TMP/bin/mutagen" "$TMP/remote-bin/mutagen"
  cp "$TMP/bin/opencode" "$TMP/remote-bin/opencode"
  cp "$TMP/bin/curl" "$TMP/remote-bin/curl"
  cat >"$TMP/remote-bin/ssh" <<'SSH'
#!/usr/bin/env bash
[[ -z "${TEST_EVENTS:-}" ]] || printf 'ssh %s\n' "$*" >>"$TEST_EVENTS"
for arg in "$@"; do [[ "$arg" != -O ]] || exit 0; done
last="${!#}"
if [[ "${FAIL_CONFIG_UPLOAD:-0}" == 1 && "$last" == 'cat > '*'/config.tar.gz' ]]; then exit 1; fi
if [[ -n "${TEST_CLIENT_PID:-}" && "$last" == 'bash -s -- cleanup '* ]] && kill -0 "$TEST_CLIENT_PID" 2>/dev/null; then
  printf 'cleanup started before stopping the client\n' >&2; exit 1
fi
HOME="$TEST_REMOTE_HOME" /bin/bash -c "$last"
SSH
  cat >"$TMP/remote-bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -eu
printf 'docker %s\n' "$*" >>"$TEST_EVENTS"
case "$1 ${2:-}" in
  'info '*) exit 0 ;;
  'container ls'*) [[ ! -f "$TEST_DOCKER/container" ]] || cat "$TEST_DOCKER/container" ;;
  'image ls'*) [[ ! -f "$TEST_DOCKER/image" ]] || cat "$TEST_DOCKER/image" ;;
  'volume ls'*) ;;
  'inspect '*|'image inspect')
    if [[ "${FAIL_OWNER:-0}" == 1 ]]; then printf 'other-installation\n';
    elif [[ "$*" == *io.molt.runtime* ]]; then [[ ! -f "$TEST_DOCKER/runtime-version" ]] || cat "$TEST_DOCKER/runtime-version";
    elif [[ "$*" == *io.molt.config* ]]; then [[ ! -f "$TEST_DOCKER/config-version" ]] || cat "$TEST_DOCKER/config-version";
    elif [[ "$*" == *io.molt.auth* ]]; then [[ ! -f "$TEST_DOCKER/auth-version" ]] || cat "$TEST_DOCKER/auth-version";
    elif [[ "$*" == *State.Running* ]]; then [[ ! -f "$TEST_DOCKER/container" ]] || printf 'true\n';
    elif [[ "$*" == *io.molt.project* ]]; then last="${!#}"; last="${last%:latest}"; printf '%s\n' "${last##*-}";
    else printf '%s\n' "$MOLT_INSTALL_ID"; fi ;;
  'build '*)
    [[ "${HOLD_BUILD:-0}" == 0 ]] || sleep 60
    shift; while [[ $# -gt 0 ]]; do if [[ "$1" == --tag ]]; then printf '%s\n' "$2" >"$TEST_DOCKER/image"; fi; shift; done ;;
  'run '*)
    shift
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --name ]]; then printf '%s\n' "$2" >"$TEST_DOCKER/container"; fi
      if [[ "$1" == --label && "$2" == io.molt.runtime=* ]]; then printf '%s\n' "${2#io.molt.runtime=}" >"$TEST_DOCKER/runtime-version"; fi
      if [[ "$1" == --label && "$2" == io.molt.config=* ]]; then printf '%s\n' "${2#io.molt.config=}" >"$TEST_DOCKER/config-version"; fi
      if [[ "$1" == --label && "$2" == io.molt.auth=* ]]; then printf '%s\n' "${2#io.molt.auth=}" >"$TEST_DOCKER/auth-version"; fi
      if [[ "$1" == --mount && "$2" == type=bind,src=*,dst=/cleanup ]]; then
        path="${2#type=bind,src=}"; path="${path%,dst=/cleanup}"
        [[ "${FAIL_HELPER:-0}" == 0 && "$path" != "${FAIL_HELPER_PATH:-}" ]] || { printf 'Docker cleanup helper failed\n' >&2; exit 1; }
        printf '%s\n' "$path" >>"$TEST_DOCKER/helpers"
        # Restore test-user permissions to simulate the helper's root access.
        chmod -R u+rwX "$path"
        rm -rf -- "$path/"* "$path/".[!.]* "$path/"..?*
      fi
      shift
    done ;;
  'rm '*) [[ "${FAIL_DOCKER:-0}" == 0 ]] || exit 1; rm -f "$TEST_DOCKER/container" ;;
  'image rm') [[ "${FAIL_DOCKER:-0}" == 0 ]] || exit 1; rm -f "$TEST_DOCKER/image" ;;
  'exec '*) [[ "${FAIL_HEALTH:-0}" == 0 ]] || exit 1 ;;
  'logs '*) ;;
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
  cat >"$TMP/remote-bin/sha256sum" <<'SHA256SUM'
#!/usr/bin/env bash
exec /usr/bin/shasum -a 256 "$@"
SHA256SUM
  cat >"$TMP/remote-bin/flock" <<'FLOCK'
#!/usr/bin/env bash
# Linux integration uses the real flock; these tool doubles run sequentially.
exit 0
FLOCK
  cat >"$TMP/remote-bin/rmdir" <<'RMDIR'
#!/usr/bin/env bash
[[ "${FAIL_ROOT_RMDIR:-0}" != 1 || "${!#}" != "$TEST_REMOTE_HOME/molt" ]] || { printf 'injected root directory removal failure\n' >&2; exit 1; }
exec /bin/rmdir "$@"
RMDIR
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
  local shared_auth="$TEST_REMOTE_HOME/molt/auth/auth.json" auth_runs
  [[ -f "$shared_auth" ]] || fail 'VM provider credential store was not created'
  [[ "$(stat -f %Lp "$shared_auth")" == 600 ]] || fail 'shared credentials are not private'
  contains "type=bind,src=$shared_auth,dst=/molt-cache/data/opencode/auth.json" "$TEST_EVENTS"
  printf '{"openai":{"type":"api","key":"vm-fixture"}}\n' >"$shared_auth"
  auth_runs="$(grep -c '^docker run .*--name' "$TEST_EVENTS")"
  (cd "$TMP/remote-repo" && "$MOLT_HOME/shims/opencode" --continue >/dev/null)
  [[ "$(grep -c '^docker run .*--name' "$TEST_EVENTS")" == "$((auth_runs + 1))" ]] || fail 'credential changes did not reload the server on reconnect'
  contains 'vm-fixture' "$shared_auth"
  auth_runs="$((auth_runs + 1))"
  (cd "$TMP/remote-repo" && "$MOLT_HOME/shims/opencode" --continue >/dev/null)
  [[ "$(grep -c '^docker run .*--name' "$TEST_EVENTS")" == "$auth_runs" ]] || fail 'unchanged credentials restarted the server'
  MOLT_ASSUME_YES=1 "$MOLT_HOME/bin/molt" reset "$TMP/remote-repo"
  contains 'vm-fixture' "$shared_auth"
  "$MOLT_HOME/bin/molt" start "$TMP/remote-repo"
  contains 'vm-fixture' "$shared_auth"
  contains '--mode two-way-safe' "$TEST_EVENTS"
  if grep -Fq -- '--ignore-vcs' "$TEST_EVENTS"; then fail 'remote OpenCode lost Git metadata'; fi
  contains '--publish 127.0.0.1:' "$TEST_EVENTS"
  contains 'FROM ubuntu:22.04' "$TEST_REMOTE_HOME/molt/meta/$("$MOLT_HOME/bin/molt" project-id "$TMP/remote-repo")/Dockerfile"
  "$MOLT_HOME/bin/molt" stop "$TMP/remote-repo"
  "$MOLT_HOME/bin/molt" stop "$TMP/remote-repo" || fail 'stopping an already-stopped project failed'
  mkdir -p "$TMP/remote-repo/src"
  (cd "$TMP/remote-repo/src" && "$MOLT_HOME/shims/opencode" --continue >/dev/null)
  contains '/workspace/src' "$TEST_CLIENT_ARGS"
  contains '--continue' "$TEST_CLIENT_ARGS"
  absent "$TMP/remote-repo/devenv.nix"
  local id state
  id="$("$MOLT_HOME/bin/molt" project-id "$TMP/remote-repo")"
  state="$MOLT_HOME/projects/$id"
  export FAIL_HEALTH=1
  rm -f "$TEST_CLIENT_ARGS"
  if (cd "$TMP/remote-repo" && "$MOLT_HOME/shims/opencode" >/dev/null); then fail 'attached before the server was healthy'; fi
  absent "$TEST_CLIENT_ARGS"
  [[ -f "$state/path" ]] || fail 'health failure discarded retry records'
  export FAIL_HEALTH=0
  export FAIL_TUNNEL=1
  if (cd "$TMP/remote-repo" && "$MOLT_HOME/shims/opencode" >/dev/null); then fail 'attached through a broken SSH tunnel'; fi
  absent "$TEST_CLIENT_ARGS"
  export FAIL_TUNNEL=0
  (cd "$TMP/remote-repo" && MOLT_LOCAL=1 "$MOLT_HOME/shims/opencode" --version >/dev/null)
  rm -f "$TEST_CLIENT_ARGS"
  (cd "$TMP" && "$MOLT_HOME/shims/opencode" --diagnostic >/dev/null)
  contains '--diagnostic' "$TEST_CLIENT_ARGS"
  (cd "$TMP/remote-repo" && "$MOLT_HOME/shims/opencode" --version >/dev/null)
  contains '--diagnostic' "$TEST_CLIENT_ARGS"
  local run target machine expected actual rc
  run="$(awk '/^RUN arch=/ {sub(/^RUN /, ""); print}' "$TEST_REMOTE_HOME/molt/meta/$id/Dockerfile")"
  # Execute the generated install step, stopping at curl before any file changes.
  while read -r target machine expected; do
    rc=0
    actual="$(/bin/sh -c '
      case "$1" in unset) unset TARGETARCH ;; empty) TARGETARCH= ;; *) TARGETARCH="$1" ;; esac
      machine="$2"
      uname() { printf "%s\n" "$machine"; }
      curl() { printf "%s\n" "$2"; return 99; }
      eval "$3"
    ' sh "$target" "$machine" "$run" 2>"$TMP/architecture.err")" || rc=$?
    if [[ "$expected" == unsupported ]]; then
      [[ "$rc" == 1 && -z "$actual" ]] || fail "accepted unsupported architecture: TARGETARCH=$target uname=$machine"
      contains 'unsupported container architecture: riscv64' "$TMP/architecture.err"
    else
      [[ "$rc" == 99 && "$actual" == "https://github.com/anomalyco/opencode/releases/download/v1.18.34/$expected" ]] || fail "wrong OpenCode asset: TARGETARCH=$target uname=$machine exit=$rc URL=$actual"
    fi
  done <<'CASES'
unset aarch64 opencode-linux-arm64.tar.gz
unset x86_64 opencode-linux-x64-baseline.tar.gz
empty aarch64 opencode-linux-arm64.tar.gz
arm64 riscv64 opencode-linux-arm64.tar.gz
amd64 riscv64 opencode-linux-x64-baseline.tar.gz
unset riscv64 unsupported
riscv64 x86_64 unsupported
CASES
  "$MOLT_HOME/bin/molt" remote-oc "@$id" auth list
  [[ "$("$MOLT_HOME/bin/molt" server-config "@$id" get)" == '{}' ]] || fail 'server configuration could not be read'
  printf '{"model":"provider/test-model"}\n' >"$TMP/server.json"
  "$MOLT_HOME/bin/molt" server-config "@$id" set "$TMP/server.json"
  cmp -s "$TMP/server.json" "$TEST_REMOTE_HOME/molt/config/opencode/opencode.json" || fail 'server configuration was not uploaded'
  printf 'invalid JSON\n' >"$TMP/server-invalid.json"
  if "$MOLT_HOME/bin/molt" server-config "@$id" set "$TMP/server-invalid.json"; then fail 'accepted invalid server configuration'; fi
  cmp -s "$TMP/server.json" "$TEST_REMOTE_HOME/molt/config/opencode/opencode.json" || fail 'invalid server configuration replaced the working file'
  # Local configuration is authoritative; dependencies stay specific to the VM.
  export OPENCODE_CONFIG_DIR="$TMP/mac opencode"
  local config="$TEST_REMOTE_HOME/molt/config/opencode" runs config_record leftover
  mkdir -p "$OPENCODE_CONFIG_DIR/commands" "$OPENCODE_CONFIG_DIR/node_modules" "$config/node_modules"
  printf '{\n  // Local JSONC settings\n  "model": "provider/local-model",\n}\n' >"$OPENCODE_CONFIG_DIR/opencode.json"
  printf 'Local instructions\n' >"$OPENCODE_CONFIG_DIR/AGENTS.md"
  printf 'Custom command\n' >"$OPENCODE_CONFIG_DIR/commands/check.md"
  printf 'Mac dependency\n' >"$OPENCODE_CONFIG_DIR/node_modules/mac-only"
  printf 'Mac lockfile\n' >"$OPENCODE_CONFIG_DIR/package-lock.json"
  printf 'VM dependency\n' >"$config/node_modules/vm-only"
  (cd "$TMP/remote-repo" && "$MOLT_HOME/shims/opencode" --continue >/dev/null)
  cmp -s "$OPENCODE_CONFIG_DIR/opencode.json" "$config/opencode.json" || fail 'local JSONC configuration did not synchronize'
  cmp -s "$OPENCODE_CONFIG_DIR/AGENTS.md" "$config/AGENTS.md" || fail 'global instructions did not synchronize'
  cmp -s "$OPENCODE_CONFIG_DIR/commands/check.md" "$config/commands/check.md" || fail 'custom commands did not synchronize'
  absent "$config/node_modules/mac-only"
  absent "$config/package-lock.json"
  contains 'VM dependency' "$config/node_modules/vm-only"
  contains 'https://nodejs.org/dist/v24.21.0/' "$TEST_REMOTE_HOME/molt/meta/$id/Dockerfile"
  runs="$(grep -c '^docker run .*--name' "$TEST_EVENTS")"
  config_record="$(<"$TEST_REMOTE_HOME/molt/state/opencode-config")"
  (cd "$TMP/remote-repo" && "$MOLT_HOME/shims/opencode" --continue >/dev/null)
  [[ "$(grep -c '^docker run .*--name' "$TEST_EVENTS")" == "$runs" ]] || fail "unchanged configuration restarted the server: $config_record -> $(<"$TEST_REMOTE_HOME/molt/state/opencode-config")"
  rm "$OPENCODE_CONFIG_DIR/commands/check.md"
  printf 'Updated instructions\n' >"$OPENCODE_CONFIG_DIR/AGENTS.md"
  (cd "$TMP/remote-repo" && "$MOLT_HOME/shims/opencode" --continue >/dev/null)
  absent "$config/commands/check.md"
  contains 'Updated instructions' "$config/AGENTS.md"
  [[ "$(grep -c '^docker run .*--name' "$TEST_EVENTS")" == "$((runs + 1))" ]] || fail 'configuration changes did not reload the server'
  runs="$((runs + 1))"
  printf '{"model":"provider/vm-edit"}\n' >"$config/opencode.json"
  (cd "$TMP/remote-repo" && "$MOLT_HOME/shims/opencode" --continue >/dev/null)
  cmp -s "$OPENCODE_CONFIG_DIR/opencode.json" "$config/opencode.json" || fail 'VM edits overrode the local configuration'
  [[ "$(grep -c '^docker run .*--name' "$TEST_EVENTS")" == "$((runs + 1))" ]] || fail 'restoring local configuration did not reload the server'
  cp "$OPENCODE_CONFIG_DIR/opencode.json" "$TMP/local-valid.json"
  printf 'invalid JSONC\n' >"$OPENCODE_CONFIG_DIR/opencode.json"
  if (cd "$TMP/remote-repo" && "$MOLT_HOME/shims/opencode" >/dev/null); then fail 'accepted invalid local configuration'; fi
  cmp -s "$TMP/local-valid.json" "$config/opencode.json" || fail 'invalid local configuration replaced the working settings'
  cp "$TMP/local-valid.json" "$OPENCODE_CONFIG_DIR/opencode.json"
  export FAIL_CONFIG_UPLOAD=1
  if (cd "$TMP/remote-repo" && "$MOLT_HOME/shims/opencode" >/dev/null); then fail 'attached after a failed configuration upload'; fi
  cmp -s "$TMP/local-valid.json" "$config/opencode.json" || fail 'failed upload replaced the working settings'
  export FAIL_CONFIG_UPLOAD=0
  for leftover in "$MOLT_HOME/state/tmp"/config.*; do absent "$leftover"; done
  unset OPENCODE_CONFIG_DIR
  absent "$TEST_REMOTE_HOME/molt/meta/$id/env/devenv.nix"
  export TEST_SYNC_CONFLICTS=1
  if MOLT_ASSUME_YES=1 "$MOLT_HOME/bin/molt" reset "@$id"; then fail 'deleted unsynchronized conflicting edits'; fi
  [[ -f "$state/path" && -f "$TEST_DOCKER/container" ]] || fail 'conflict discarded the workspace or retry record'
  export TEST_SYNC_CONFLICTS=0
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
  if (cd "$TMP/remote-repo" && "$MOLT_HOME/shims/opencode" >/dev/null); then fail 'accepted a remote cache symlink outside the owned root'; fi
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
  # Real directory permissions exercise the unprivileged rm on the test Mac.
  # The Docker integration test covers files actually owned by root on Linux.
  local protected daemon client
  for protected in "$TEST_REMOTE_HOME/molt/meta/$id/env/.devenv" "$TEST_REMOTE_HOME/molt/cache/$id/data/opencode" "$TEST_REMOTE_HOME/molt/config/opencode/node_modules/@opencode-ai/plugin"; do
    mkdir -p "$protected"
    printf 'protected\n' >"$protected/file"
    chmod 500 "$protected"
  done
  "$MOLT_HOME/bin/molt" client --hold &
  client=$!
  ready=0
  for attempt in {1..50}; do
    for file in "$MOLT_HOME/state/tmp"/client.*/parent.pid; do [[ ! -f "$file" ]] || ready=1; done
    [[ "$ready" == 0 ]] || break
    sleep 0.05
  done
  [[ "$ready" == 1 ]] || { kill "$client"; fail 'client did not start'; }
  export TEST_CLIENT_PID="$client"
  daemon="$MOLT_HOME/state/home/.mutagen/daemon/daemon.sock"
  mkdir -p "${daemon%/*}"
  (cd "$MOLT_HOME/state/home" && /usr/bin/python3 -c 'import socket; s = socket.socket(socket.AF_UNIX); s.bind(".mutagen/daemon/daemon.sock")')
  export TEST_EVENTS="$TMP/uninstall-events" FAIL_HELPER=1
  if "$MOLT_HOME/bin/molt-uninstall" --yes >"$TMP/helper-failure.log" 2>&1; then fail 'helper failure succeeded'; fi
  if kill -0 "$client" 2>/dev/null; then kill "$client"; fail 'uninstall left a client running'; fi
  wait "$client" 2>/dev/null || true
  unset TEST_CLIENT_PID
  contains 'using Docker to remove protected files' "$TMP/helper-failure.log"
  contains 'Permission denied' "$TMP/helper-failure.log"
  contains 'Docker cleanup helper failed' "$TMP/helper-failure.log"
  contains 'cleanup failed; installation and retry records preserved' "$TMP/helper-failure.log"
  [[ -f "$state/path" && -f "$MOLT_HOME/.install-manifest" && -f "$TEST_REMOTE_HOME/molt/.install-manifest" ]] || fail 'helper failure lost retry records'
  [[ -S "$daemon" ]] || fail 'uninstall stopped Mutagen before resource cleanup'
  printf 'DOCKER_INSTALLED=1\nDOCKER_GROUP_ADDED=1\n' >"$TEST_REMOTE_HOME/molt/state/bootstrap.manifest"
  cp "$TEST_REMOTE_HOME/molt/state/bootstrap.manifest" "$TMP/bootstrap.expected"
  cp "$TEST_REMOTE_HOME/molt/state/docker-resources" "$TMP/resources.expected"
  cp "$TEST_REMOTE_HOME/molt/.install-manifest" "$TMP/owner.expected"
  export FAIL_HELPER=0 FAIL_HELPER_PATH="$TEST_REMOTE_HOME/molt/config"
  if "$MOLT_HOME/bin/molt-uninstall" --yes >"$TMP/shared-failure.log" 2>&1; then fail 'shared helper failure succeeded'; fi
  cmp -s "$TMP/owner.expected" "$TEST_REMOTE_HOME/molt/.install-manifest" || fail 'shared cleanup lost the remote ownership marker'
  cmp -s "$TMP/bootstrap.expected" "$TEST_REMOTE_HOME/molt/state/bootstrap.manifest" || fail 'shared cleanup lost VM preparation records'
  cmp -s "$TMP/resources.expected" "$TEST_REMOTE_HOME/molt/state/docker-resources" || fail 'shared cleanup lost Docker resource records'
  contains 'Docker cleanup helper failed' "$TMP/shared-failure.log"
  contains 'remote root cleanup failed; retry records preserved' "$TMP/shared-failure.log"
  [[ -f "$MOLT_HOME/state/remotes/$(printf test-vm | shasum -a 256 | cut -c1-20)/root" ]] || fail 'shared cleanup lost the saved remote root'
  [[ -S "$daemon" ]] || fail 'shared cleanup stopped Mutagen before recovery'
  # Older failed removals may already have deleted empty project directories.
  for directory in projects meta cache; do
    [[ ! -d "$TEST_REMOTE_HOME/molt/$directory" ]] || rmdir "$TEST_REMOTE_HOME/molt/$directory"
  done
  unset FAIL_HELPER_PATH
  export FAIL_ROOT_RMDIR=1
  if "$MOLT_HOME/bin/molt-uninstall" --yes >"$TMP/root-removal-failure.log" 2>&1; then fail 'root removal failure succeeded'; fi
  cmp -s "$TMP/owner.expected" "$TEST_REMOTE_HOME/molt/.install-manifest" || fail 'final directory removal lost ownership'
  cmp -s "$TMP/bootstrap.expected" "$TEST_REMOTE_HOME/molt/state/bootstrap.manifest" || fail 'final directory removal lost preparation records'
  cmp -s "$TMP/resources.expected" "$TEST_REMOTE_HOME/molt/state/docker-resources" || fail 'final directory removal lost Docker records'
  contains 'using Docker to remove protected files' "$TMP/root-removal-failure.log"
  export FAIL_ROOT_RMDIR=0
  : >"$TEST_EVENTS"
  "$MOLT_HOME/bin/molt-uninstall" --yes >"$TMP/helper-success.log" 2>&1
  if grep -Fq 'Permission denied' "$TMP/helper-success.log"; then fail 'successful recovery printed deletion errors'; fi
  contains "$TEST_REMOTE_HOME/molt/meta/$id" "$TEST_DOCKER/helpers"
  contains "$TEST_REMOTE_HOME/molt/cache/$id" "$TEST_DOCKER/helpers"
  contains "$TEST_REMOTE_HOME/molt/config" "$TEST_DOCKER/helpers"
  if grep -Fq -- '-O exit' "$TEST_EVENTS"; then fail 'uninstall closed SSH between cleanup steps'; fi
  awk '/^mutagen daemon stop$/ {stopped++; next} stopped {exit 1} END {if (stopped != 1) exit 1}' "$TEST_EVENTS" || fail 'daemon shutdown did not follow resource cleanup'
  absent "$MOLT_HOME"
  absent "$TEST_REMOTE_HOME/molt"
  absent "$TEST_DOCKER/container"
  absent "$TEST_DOCKER/image"
)

test_managed_access() (
  export MOLT_HOME="$HOME/managed-access" TEST_REMOTE_HOME="$TMP/access-vm"
  mkdir -p "$TEST_REMOTE_HOME/.ssh" "$TMP/access-bin"
  printf 'external-key\n' >"$TEST_REMOTE_HOME/.ssh/authorized_keys"
  cat >"$TMP/access-bin/ssh" <<'SSH'
#!/usr/bin/env bash
[[ "${FAIL_ACCESS:-0}" == 0 ]] || exit 255
for arg in "$@"; do [[ "$arg" != -O ]] || exit 0; done
HOME="$TEST_REMOTE_HOME" /bin/bash -c "${!#}"
SSH
  chmod +x "$TMP/access-bin/ssh"
  export PATH="$TMP/access-bin:$PATH"
  install
  "$MOLT_HOME/bin/molt" connection add dev vm.example ubuntu 22 ''
  printf '\n\n' | "$MOLT_HOME/bin/molt" connection keygen dev >/dev/null
  "$MOLT_HOME/bin/molt" connection authorize dev
  "$MOLT_HOME/bin/molt" connection authorize dev
  [[ "$(wc -l <"$TEST_REMOTE_HOME/.ssh/authorized_keys" | tr -d ' ')" == 2 ]] || fail 'key authorization is not idempotent'
  contains "molt:$(molt_id_from_manifest):dev" "$TEST_REMOTE_HOME/.ssh/authorized_keys"
  rm -f "$MOLT_HOME/state/ssh/keys/dev.pub"
  export FAIL_ACCESS=1
  if "$MOLT_HOME/bin/molt-uninstall" --yes; then fail 'offline key cleanup discarded its credentials'; fi
  [[ -f "$MOLT_HOME/state/ssh/profiles/dev/authorized" ]] || fail 'lost key cleanup records'
  "$MOLT_HOME/bin/molt" cleanup-inventory >"$TMP/access-inventory"
  contains vm.example "$TMP/access-inventory"
  export FAIL_ACCESS=0
  "$MOLT_HOME/bin/molt-uninstall" --yes
  [[ "$(cat "$TEST_REMOTE_HOME/.ssh/authorized_keys")" == external-key ]] || fail 'key cleanup changed external authorization'
)

molt_id_from_manifest() { awk -F= '$1=="INSTALL_ID" {print $2}' "$MOLT_HOME/.install-manifest"; }

test_vm_preparation() (
  export MOLT_HOME="$HOME/preparation" TEST_REMOTE_HOME="$TMP/prepared-vm" TEST_ROOT="$ROOT" TEST_VM_BIN="$TMP/prepare-bin"
  mkdir -p "$TEST_REMOTE_HOME" "$TEST_VM_BIN"
  cat >"$TEST_VM_BIN/ssh" <<'SSH'
#!/usr/bin/env bash
for arg in "$@"; do [[ "$arg" != -O ]] || exit 0; done
HOME="$TEST_REMOTE_HOME" /bin/bash -c "${!#}"
SSH
  cat >"$TEST_VM_BIN/realpath" <<'REALPATH'
#!/usr/bin/env bash
source "$TEST_ROOT/bin/_molt.sh"
[[ "${1:-}" != -m ]] || shift
[[ "${1:-}" != -- ]] || shift
molt_canonical "$1"
REALPATH
  cat >"$TEST_VM_BIN/awk" <<'AWK'
#!/usr/bin/env bash
if [[ "${!#}" == /etc/os-release ]]; then printf 'ubuntu\n'; else exec /usr/bin/awk "$@"; fi
AWK
  cat >"$TEST_VM_BIN/id" <<'ID'
#!/usr/bin/env bash
case "$*" in
  -u) printf '501\n' ;;
  -un) printf 'ubuntu\n' ;;
  '-nG ubuntu') if [[ -f "$TEST_REMOTE_HOME/group" ]]; then printf 'staff docker\n'; else printf 'staff\n'; fi ;;
  *) exec /usr/bin/id "$@" ;;
esac
ID
  cat >"$TEST_VM_BIN/sudo" <<'SUDO'
#!/usr/bin/env bash
[[ "$1" != -- ]] || shift
exec "$@"
SUDO
  cat >"$TEST_VM_BIN/apt-get" <<'APT'
#!/usr/bin/env bash
[[ "${FAIL_APT:-0}" == 0 ]] || exit 1
printf '%s\n' "$*" >>"$TEST_REMOTE_HOME/packages.log"
if [[ "$1" == install ]]; then cp "$TEST_VM_BIN/docker.template" "$TEST_VM_BIN/docker";
elif [[ "$1" == remove ]]; then
  [[ ! -e "$TEST_REMOTE_HOME/molt/config/opencode/node_modules" && -f "$TEST_REMOTE_HOME/molt/.install-manifest" && -f "$TEST_REMOTE_HOME/molt/state/bootstrap.manifest" ]] || { printf 'shared cleanup must precede Docker removal and retain preparation records\n' >&2; exit 1; }
  rm -f "$TEST_VM_BIN/docker"
fi
APT
  cat >"$TEST_VM_BIN/docker.template" <<'DOCKER'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  'info '*) [[ -f "$TEST_REMOTE_HOME/group" ]] ;;
  'container ls'*) [[ "${FOREIGN_CONTAINER:-0}" == 0 ]] || printf 'external-container\n' ;;
  'volume ls'*) ;;
  'run '*)
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --mount && "$2" == type=bind,src=*,dst=/cleanup ]]; then
        path="${2#type=bind,src=}"; path="${path%,dst=/cleanup}"
        chmod -R u+rwX "$path"
        rm -rf -- "$path/"* "$path/".[!.]* "$path/"..?*
      fi
      shift
    done ;;
  *) exit 2 ;;
esac
DOCKER
  cat >"$TEST_VM_BIN/systemctl" <<'SERVICE'
#!/usr/bin/env bash
if [[ "$1" == is-active ]]; then exit 1; fi
SERVICE
  cat >"$TEST_VM_BIN/usermod" <<'GROUP'
#!/usr/bin/env bash
touch "$TEST_REMOTE_HOME/group"
GROUP
  cat >"$TEST_VM_BIN/gpasswd" <<'GROUP'
#!/usr/bin/env bash
rm -f "$TEST_REMOTE_HOME/group"
GROUP
  chmod +x "$TEST_VM_BIN/"*
  export PATH="$TEST_VM_BIN:$PATH"
  install
  "$MOLT_HOME/bin/molt" config set MOLT_HOST test-vm
  "$MOLT_HOME/bin/molt" config set MOLT_REMOTE_HOME "$TEST_REMOTE_HOME"
  if "$MOLT_HOME/bin/molt" bootstrap; then fail 'accepted the VM home as the workspace'; fi
  for record in "$MOLT_HOME/state/remotes"/*/host; do [[ ! -f "$record" ]] || fail 'invalid workspace stranded a cleanup record'; done
  "$MOLT_HOME/bin/molt" config set MOLT_REMOTE_HOME '$HOME/molt'
  export FAIL_APT=1
  if "$MOLT_HOME/bin/molt" bootstrap; then fail 'failed package installation succeeded'; fi
  "$MOLT_HOME/bin/molt-uninstall" --yes || fail 'could not uninstall after failed Docker preparation'
  absent "$TEST_REMOTE_HOME/molt"
  export FAIL_APT=0
  install
  "$MOLT_HOME/bin/molt" config set MOLT_HOST test-vm
  "$MOLT_HOME/bin/molt" bootstrap
  [[ -f "$TEST_REMOTE_HOME/molt/.install-manifest" && -f "$TEST_REMOTE_HOME/group" ]] || fail 'VM was not prepared'
  "$MOLT_HOME/bin/molt" bootstrap
  [[ "$(grep -c '^install ' "$TEST_REMOTE_HOME/packages.log")" == 1 ]] || fail 'Docker preparation reinstalled existing packages'
  export FOREIGN_CONTAINER=1
  if "$MOLT_HOME/bin/molt" unprepare-vm; then fail 'removed Docker while external containers remained'; fi
  [[ -x "$TEST_VM_BIN/docker" && -f "$TEST_REMOTE_HOME/group" ]] || fail 'failed VM cleanup removed dependencies'
  export FOREIGN_CONTAINER=0
  mkdir -p "$TEST_REMOTE_HOME/molt/config/opencode/node_modules/plugin"
  printf 'protected\n' >"$TEST_REMOTE_HOME/molt/config/opencode/node_modules/plugin/file"
  chmod 500 "$TEST_REMOTE_HOME/molt/config/opencode/node_modules/plugin"
  "$MOLT_HOME/bin/molt-uninstall" --yes --undo-vm
  absent "$TEST_REMOTE_HOME/molt"
  absent "$TEST_REMOTE_HOME/group"
  absent "$TEST_VM_BIN/docker"
)

for test in ${*:-test_contained_install test_path_safety test_failed_install_and_upgrade test_checksum_failure_and_interrupted_install test_literal_paths test_install_lock_and_tool_repair test_failed_commit_restores_release test_containment_rejects_symlinks test_local_down_stops_clients test_legacy_shell_migration test_offline_uninstall test_remote_lifecycle test_managed_access test_vm_preparation}; do
  "$test"
  printf 'PASS: %s\n' "$test"
done
printf 'molt lifecycle tests: ok\n'
