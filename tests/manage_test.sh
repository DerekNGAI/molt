#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-manage.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/bin" "$TMP/dotfiles"
unset MOLT_SSH_CONFIG MOLT_USER_HOME OPENCODE_CONFIG_DIR
export HOME="$TMP/home" ZDOTDIR="$TMP/dotfiles" PATH="$TMP/bin:/usr/bin:/bin"
export MOLT_MUTAGEN_BINARY="$TMP/bin/mutagen" MOLT_OPENCODE_BINARY="$TMP/bin/opencode" MOLT_TUI_BINARY="$TMP/bin/molt-tui"
for tool in mutagen opencode; do
  printf '#!/usr/bin/env bash\ncase "$*" in version) printf "0.18.1\\n" ;; --version) printf "2.0.2\\n" ;; esac\n' >"$TMP/bin/$tool"
done
printf '#!/usr/bin/env bash\nprintf "native TUI fixture\\n"\n' >"$TMP/bin/molt-tui"
chmod +x "$TMP/bin/"*
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
install() {
  export MOLT_HOME="$HOME/$1"
  /bin/bash "$ROOT/install.sh" --non-interactive >"$TMP/install.log" 2>&1
  MOLT="$MOLT_HOME/bin/molt"
}

test_config() (
  install config
  printf '\n# keep this customization\nCUSTOM_SETTING=keep\n' >>"$MOLT_HOME/config"
  local folder="$HOME/projects \"quotes\" \$(touch escaped)"
  mkdir -p "$folder"
  "$MOLT" config set MOLT_ROOT "$folder"
  [[ "$("$MOLT" config get MOLT_ROOT)" == "$folder" ]] || fail 'configuration did not preserve literal input'
  [[ ! -e "$MOLT_HOME/state/ssh/escaped" ]] || fail 'configuration evaluated user input'
  grep -Fq 'CUSTOM_SETTING=keep' "$MOLT_HOME/config" || fail 'configuration discarded custom settings'
  cp "$MOLT_HOME/config" "$TMP/config.before"
  if "$MOLT" config set PATH /tmp; then fail 'accepted an unmanaged setting'; fi
  if "$MOLT" config set MOLT_OPENCODE_BASE_PORT 65535; then fail 'accepted an overflowing port range'; fi
  if "$MOLT" config set MOLT_REMOTE_HOME /; then fail 'accepted an unsafe remote root'; fi
   if "$MOLT" config set MOLT_ANIMATIONS 2; then fail 'accepted an invalid animation preference'; fi
  cmp -s "$TMP/config.before" "$MOLT_HOME/config" || fail 'invalid setting changed configuration'
  "$MOLT" config set MOLT_ANIMATIONS 0
  [[ "$("$MOLT" config get MOLT_ANIMATIONS)" == 0 ]] || fail 'animation preference was not saved'
)

test_empty_connection() (
  install empty-connection
  [[ -z "$("$MOLT" config get MOLT_HOST)" ]] || fail 'fresh installation selected an example host'
  "$MOLT" config set MOLT_ROOT "$HOME"
  [[ -z "$("$MOLT" config get MOLT_HOST)" ]] || fail 'empty connection fell back to an example host'
  [[ -z "$("$MOLT" connection list)" ]] || fail 'fresh installation has saved connections'
  "$MOLT" connection cleanup
  "$MOLT" status | grep -Fq 'no connection configured' || fail 'status did not explain the empty connection'
  local output action
  for action in setup bootstrap ssh doctor 'connection login'; do
    if output="$("$MOLT" $action 2>&1)"; then fail "$action accepted an empty connection"; fi
    [[ "$output" == *'no connection configured'* ]] || fail "$action did not explain the missing connection"
  done
  mkdir -p "$TMP/unconnected-project"
  git -C "$TMP/unconnected-project" init -q
  if "$MOLT" register "$TMP/unconnected-project"; then fail 'registered a project without a connection'; fi
  local state
  for state in "$MOLT_HOME/projects"/*/path; do [[ ! -f "$state" ]] || fail 'missing connection left a project record'; done
  "$MOLT_HOME/bin/molt-uninstall" --yes
  [[ ! -e "$MOLT_HOME" ]] || fail 'fresh installation could not be removed without a connection'
)

test_connections() (
  install connections
  mkdir -p "$HOME/.ssh"
  printf 'Host external\n  HostName existing.example\n' >"$HOME/.ssh/config"
  cp "$HOME/.ssh/config" "$TMP/ssh.before"
  local key="$HOME/key with spaces"
  ssh-keygen -q -t ed25519 -N '' -f "$key"
  "$MOLT" connection add dev vm.example ubuntu 2222 "$key"
  "$MOLT" connection use dev
  [[ "$("$MOLT" config get MOLT_HOST)" == dev ]] || fail 'did not select the SSH profile'
  /bin/bash "$ROOT/install.sh" --non-interactive >"$TMP/upgrade.log" 2>&1
  [[ "$("$MOLT" config get MOLT_HOST)" == dev ]] || fail 'upgrade discarded the selected connection'
  local output
  output="$(/usr/bin/ssh -G -F "$MOLT_HOME/state/ssh/config" dev 2>/dev/null)"
  [[ "$output" == *'hostname vm.example'* && "$output" == *'port 2222'* && "$output" == *"identityfile $key"* ]] || fail 'invalid managed SSH configuration'
  /usr/bin/ssh -G -F "$MOLT_HOME/state/ssh/config" external 2>/dev/null | grep -qx 'hostname existing.example' || fail 'external hosts became inaccessible'
  cmp -s "$TMP/ssh.before" "$HOME/.ssh/config" || fail 'connection setup edited global SSH configuration'
  if "$MOLT" connection add bad $'vm.example\nProxyCommand touch bad' ubuntu 22 "$key"; then fail 'accepted SSH directive injection'; fi
  local record
  record="$MOLT_HOME/state/remotes/$(printf dev | shasum -a 256 | cut -c1-20)"
  mkdir -p "$record"
  printf 'dev\n' >"$record/host"
  printf '/remote/molt\n' >"$record/root"
  if "$MOLT" connection add dev replacement.example ubuntu 22 "$key"; then fail 'replaced a profile needed for cleanup'; fi
  if "$MOLT" connection remove dev; then fail 'removed a profile needed for cleanup'; fi
  "$MOLT" connection add other other.example ubuntu 22 "$key"
  "$MOLT" connection use other
  /usr/bin/ssh -G -F "$MOLT_HOME/state/ssh/config" dev 2>/dev/null | grep -qx 'hostname vm.example' || fail 'switching hosts lost the recorded connection'
  "$MOLT" connection remove other
  [[ "$("$MOLT" config get MOLT_HOST)" == dev ]] || fail 'removal did not select the remaining connection'
  rm -rf "$record"
  "$MOLT" connection remove dev
  [[ -z "$("$MOLT" config get MOLT_HOST)" ]] || fail 'removing the last connection left a stale selection'
  [[ -z "$("$MOLT" connection list)" ]] || fail 'could not list connections after removing the last profile'
)

test_connection_aliases() (
  export HOME="$TMP/aliases-home" MOLT_USER_HOME="$TMP/aliases-home"
  mkdir -p "$HOME"
  install aliases
  local output expected
  output="$("$MOLT" connection aliases)" || fail 'missing SSH configuration failed discovery'
  [[ -z "$output" ]] || fail 'missing SSH configuration produced aliases'
  mkdir -p "$HOME/.ssh/config.d with spaces"
  cat >"$HOME/.ssh/config" <<CONFIG
Host = "oracle-dev" oracle-short # same destination
  HostName oracle-dev
  User ubuntu
Host *
  Include "$HOME/.ssh/config.d with spaces/*.conf"
Host oracle-dev
  User ignored
Host * !blocked
  Port 2222
Host *.wild !negated
  User fallback
CONFIG
  printf 'Include "%s/.ssh/nested.conf"\nhOsT included\n  HostName included.example\n  User remote\n  Port 2200\n' "$HOME" >"$HOME/.ssh/config.d with spaces/dev.conf"
  printf 'Host nested\n  HostName nested.example\n  User nested-user\n' >"$HOME/.ssh/nested.conf"
  cp "$HOME/.ssh/config" "$TMP/aliases.before"
  expected=$'oracle-dev\tubuntu@oracle-dev:2222\noracle-short\tubuntu@oracle-dev:2222\nnested\tnested-user@nested.example:2222\nincluded\tremote@included.example:2200'
  output="$("$MOLT" connection aliases)" || fail 'could not discover SSH aliases'
  [[ "$output" == "$expected" ]] || fail "unexpected SSH aliases: $output"
  [[ -z "$("$MOLT" config get MOLT_HOST)" ]] || fail 'alias discovery selected a connection'
  "$MOLT" connection use oracle-dev
  [[ "$("$MOLT" connection aliases)" == "$expected" ]] || fail 'managed SSH configuration lost included aliases'
  cmp -s "$TMP/aliases.before" "$HOME/.ssh/config" || fail 'alias discovery modified external configuration'
  "$MOLT" config set MOLT_SSH_CONFIG "$HOME/.ssh/nested.conf"
  [[ "$("$MOLT" connection aliases)" == $'nested\tnested-user@nested.example:22' ]] || fail 'alias discovery ignored the configured SSH file'
  printf 'Include nested.conf "~/.ssh/config.d with spaces/*.conf"\n' >"$HOME/.ssh/relative.conf"
  "$MOLT" config set MOLT_SSH_CONFIG "$HOME/.ssh/relative.conf"
  output="$("$MOLT" connection aliases)" || fail 'relative/tilde include discovery failed'
  [[ "$output" == $'nested\tnested-user@nested.example:22\nincluded\tremote@included.example:2200' ]] || fail "relative/tilde includes did not follow OpenSSH home-directory semantics: $output"
  "$MOLT" config set MOLT_SSH_CONFIG "$HOME/.ssh/nested.conf"
  printf '\nInvalidMoltOption yes\n' >>"$HOME/.ssh/nested.conf"
  if "$MOLT" connection aliases; then fail 'invalid SSH configuration produced selectable aliases'; fi
  printf 'Host recursive\n  User ubuntu\nInclude "%s/.ssh/nested.conf"\n' "$HOME" >"$HOME/.ssh/nested.conf"
  if "$MOLT" connection aliases; then fail 'recursive SSH configuration produced selectable aliases'; fi
)

test_shell_integration() (
  install 'shell with spaces'
  printf 'export KEEP_ME=1\n' >"$TMP/dotfiles/real-zshrc"
  ln -s real-zshrc "$ZDOTDIR/.zshrc"
  cp "$ZDOTDIR/.zshrc" "$TMP/zsh.before"
  "$MOLT" shell enable
  cp "$ZDOTDIR/.zshrc" "$TMP/zsh.enabled"
  "$MOLT" shell enable
  cmp -s "$TMP/zsh.enabled" "$ZDOTDIR/.zshrc" || fail 'shell integration is not idempotent'
  /bin/zsh -f -c 'source "$ZDOTDIR/.zshrc"; [[ "$(command -v molt)" == "$MOLT_HOME/bin/molt" ]]' || fail 'shell integration did not activate MOLT'
  "$MOLT_HOME/bin/molt-uninstall" --yes
  [[ -L "$ZDOTDIR/.zshrc" ]] || fail 'uninstall replaced the shell symlink'
  cmp -s "$TMP/zsh.before" "$ZDOTDIR/.zshrc" || fail 'uninstall did not restore the shell file'
)

test_shell_edits() (
  install shell-edits
  printf 'export KEEP_ME=1\n' >"$ZDOTDIR/.zshrc"
  "$MOLT" shell enable
  printf 'export ADDED_LATER=1\n' >>"$ZDOTDIR/.zshrc"
  "$MOLT" shell enable
  "$MOLT" shell disable
  grep -qx 'export ADDED_LATER=1' "$ZDOTDIR/.zshrc" || fail 'repeated activation discarded later shell edits'
  "$MOLT" shell enable
  printf 'export USER_REMOVED_ACTIVATION=1\n' >"$ZDOTDIR/.zshrc"
  "$MOLT" shell disable || fail 'already-removed activation blocked cleanup'
  grep -qx 'export USER_REMOVED_ACTIVATION=1' "$ZDOTDIR/.zshrc" || fail 'cleanup overwrote the replacement shell file'
)

test_failed_shell_activation() (
  install shell-failure
  rm -f "$ZDOTDIR/.zshrc"
  cat >"$TMP/bin/cp" <<'CP'
#!/usr/bin/env bash
[[ "${!#}" != */state/shell/backup ]] || exit 1
exec /bin/cp "$@"
CP
  chmod +x "$TMP/bin/cp"
  if "$MOLT" shell enable; then fail 'failed shell backup succeeded'; fi
  "$MOLT_HOME/bin/molt-uninstall" --yes
  [[ ! -e "$ZDOTDIR/.zshrc" ]] || fail 'failed activation left an unrecorded shell file'
  rm -f "$TMP/bin/cp"
)

test_project_management() (
  install projects
  "$MOLT" config set MOLT_HOST test-vm
  mkdir -p "$TMP/project"
  git -C "$TMP/project" init -q
  "$MOLT" register "$TMP/project" >/dev/null
  local id
  id="$("$MOLT" project-id "$TMP/project")"
  printf 'name: keep\nports:\n  - 3000\nother: keep\n' >"$TMP/project/.molt.yml"
  cp "$TMP/project/.molt.yml" "$TMP/ports.before"
  if "$MOLT" ports "@$id" '4173 8080'; then fail 'kept application port management'; fi
  cmp -s "$TMP/ports.before" "$TMP/project/.molt.yml" || fail 'modified the checkout manifest'
  rm -rf "$TMP/project"
  "$MOLT" status | grep -Fq "$TMP/project" || fail 'status failed for a missing checkout'
  "$MOLT" stop "@$id"
  MOLT_ASSUME_YES=1 "$MOLT" reset "@$id"
  [[ ! -d "$MOLT_HOME/projects/$id" ]] || fail 'could not reset a missing checkout by its saved identity'
)

test_install_repair() (
  export MOLT_HOME="$HOME/private-tui"
  /bin/bash "$ROOT/install.sh" --non-interactive >"$TMP/install.log" 2>&1
  [[ -x "$MOLT_HOME/bin/molt-tui" ]] || fail 'native TUI was not installed privately'
  [[ -x "$MOLT_HOME/current/install.sh" && -f "$MOLT_HOME/current/config.example" ]] || fail 'installation cannot repair itself'
  [[ -x "$MOLT_HOME/MOLT.command" ]] || fail 'missing Finder launcher'
  /bin/bash "$MOLT_HOME/current/install.sh" --non-interactive >"$TMP/repair.log" 2>&1 || { cat "$TMP/repair.log" >&2; fail 'installation could not repair itself from its owned release'; }
)

test_native_install() (
  install native-ui
  [[ -x "$MOLT_HOME/bin/molt-tui" ]] || fail 'native TUI was not installed'
  [[ ! -e "$MOLT_HOME/bin/_tui.sh" ]] || fail 'legacy shell UI was installed'
  [[ "$("$MOLT" tools)" != *GUM* ]] || fail 'tool inspection still requires Gum'
)

test_install_options() (
  export MOLT_HOME="$HOME/invalid-option"
  if /bin/bash "$ROOT/install.sh" --invalid >"$TMP/install.log" 2>&1; then fail 'accepted an unknown installer option'; fi
  [[ ! -e "$MOLT_HOME" ]] || fail 'unknown installer option left an installation behind'
)

prepare_update() {
  install 'update with spaces'
  export UPDATE_SOURCE="$TMP/update-source" UPDATE_RECORD="$TMP/update-source-path" UPDATE_STARTED="$TMP/update-started"
  mkdir -p "$UPDATE_SOURCE"
  cp -R "$ROOT/bin" "$ROOT/shims" "$ROOT/remote" "$ROOT/tui" "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/config.example" "$ROOT/tools.lock" "$UPDATE_SOURCE/"
  printf '#!/usr/bin/env bash\nprintf "stale TUI fixture\\n"\n' >"$UPDATE_SOURCE/bin/molt-tui"
  chmod +x "$UPDATE_SOURCE/bin/molt-tui"
  cat >"$TMP/bin/git" <<'GIT'
#!/usr/bin/env bash
if [[ "$*" == '-c credential.interactive=false clone --depth 1 --single-branch --branch main https://github.com/DerekNGAI/molt.git '* ]]; then
  [[ "$GIT_TERMINAL_PROMPT" == 0 ]] || exit 3
  printf '%s\n' "${!#}" >"$UPDATE_RECORD"
  mkdir -p "${!#}"
  case "${UPDATE_MODE:-}" in
    download-failure) exit 22 ;;
    invalid-source) exit 0 ;;
    cancel-download) touch "$UPDATE_STARTED"; sleep 60 & wait; exit ;;
  esac
  cp -R "$UPDATE_SOURCE/." "${!#}/"
elif [[ "$*" == '-C '*' rev-parse --short HEAD' ]]; then printf 'abcdef0\n'
else exec /usr/bin/git "$@"; fi
GIT
  cat >"$TMP/bin/go" <<'GO'
#!/usr/bin/env bash
[[ -z "${MOLT_TUI_BINARY:-}" ]] || exit 3
case "${UPDATE_MODE:-}" in
  build-failure) exit 42 ;;
  cancel-build) touch "$UPDATE_STARTED"; sleep 60 & wait; exit ;;
esac
printf '#!/usr/bin/env bash\nprintf "updated TUI fixture\\n"\n' >../bin/molt-tui
chmod +x ../bin/molt-tui
GO
  chmod +x "$TMP/bin/git" "$TMP/bin/go"
}

test_source_install_rebuilds_tui() (
  prepare_update
  unset MOLT_TUI_BINARY
  /bin/bash "$UPDATE_SOURCE/install.sh" --non-interactive >"$TMP/source-install.log" 2>&1 || { cat "$TMP/source-install.log"; fail 'source installation failed'; }
  [[ "$("$MOLT_HOME/bin/molt-tui")" == 'updated TUI fixture' ]] || fail 'source installer reused a stale executable instead of building current sources'
  local original="$(readlink "$MOLT_HOME/current")"
  mkdir "$UPDATE_SOURCE/.git"
  if PATH=/usr/bin:/bin /bin/bash "$UPDATE_SOURCE/install.sh" --non-interactive >"$TMP/source-install.log" 2>&1; then fail 'Git checkout without Go silently reused a stale executable'; fi
  [[ "$(readlink "$MOLT_HOME/current")" == "$original" ]] || fail 'missing compiler replaced the working installation'
  grep -Fq 'install Go 1.26 or supply MOLT_TUI_BINARY' "$TMP/source-install.log" || fail 'missing compiler was not explained'
  rmdir "$UPDATE_SOURCE/.git"
  PATH=/usr/bin:/bin /bin/bash "$UPDATE_SOURCE/install.sh" --non-interactive >"$TMP/source-install.log" 2>&1 || fail 'packaged executable unnecessarily required Go'
  [[ "$("$MOLT_HOME/bin/molt-tui")" == 'stale TUI fixture' ]] || fail 'package installation did not retain its supplied executable'
  rm -f "$TMP/bin/git" "$TMP/bin/go"
)

update_daemon_fixture() {
  cat >"$TMP/bin/mutagen" <<'MUTAGEN'
#!/usr/bin/env bash
case "$*" in
  version) printf '0.18.1\n' ;;
  'daemon stop') rm -f "$MOLT_HOME/state/home/.mutagen/daemon/daemon.sock" ;;
  'daemon start')
    [[ "${UPDATE_MODE:-}" != daemon-failure ]] || exit 1
    python3 - "$MOLT_HOME/state/home/.mutagen/daemon" <<'PY'
import os, socket, sys
os.makedirs(sys.argv[1], exist_ok=True)
os.chdir(sys.argv[1])
socket.socket(socket.AF_UNIX).bind('daemon.sock')
PY
    ;;
esac
MUTAGEN
  "$TMP/bin/mutagen" daemon start
}

test_update() (
  prepare_update
  local original="$(readlink "$MOLT_HOME/current")"
  "$MOLT" config set MOLT_HOST offline-vm
  printf 'keep password\n' >"$MOLT_HOME/opencode.password"
  mkdir -p "$TMP/update-repo"
  git -C "$TMP/update-repo" init -q
  "$MOLT" register "$TMP/update-repo" >/dev/null
  local id="$("$MOLT" project-find "$TMP/update-repo")"
  cp "$MOLT_HOME/config" "$TMP/update-config.before"
  cp "$MOLT_HOME/.install-manifest" "$TMP/update-manifest.before"
  update_daemon_fixture
  "$MOLT" update >"$TMP/update.log" 2>&1 || { cat "$TMP/update.log" >&2; fail 'update failed'; }
  [[ "$(readlink "$MOLT_HOME/current")" != "$original" ]] || fail 'update did not install a new release'
  [[ "$("$MOLT_HOME/bin/molt-tui")" == 'updated TUI fixture' ]] || fail 'update reused the old TUI executable'
  cmp -s "$TMP/update-config.before" "$MOLT_HOME/config" || fail 'update changed configuration'
  cmp -s "$TMP/update-manifest.before" "$MOLT_HOME/.install-manifest" || fail 'update changed installation ownership or dependencies'
  [[ "$(<"$MOLT_HOME/opencode.password")" == 'keep password' && "$("$MOLT" project-find "$TMP/update-repo")" == "$id" ]] || fail 'update discarded credentials or project records'
  [[ ! -e "$(dirname "$(<"$UPDATE_RECORD")")" && ! -d "$MOLT_HOME/state/install.lock" ]] || fail 'update left its source or lock behind'
  [[ -S "$MOLT_HOME/state/home/.mutagen/daemon/daemon.sock" ]] || fail 'update left synchronization stopped'
  if "$MOLT" update --invalid; then fail 'update accepted an unknown option'; fi
  rm -f "$TMP/bin/git" "$TMP/bin/go"
)

test_update_failures() (
  prepare_update
  local original="$(readlink "$MOLT_HOME/current")" mode
  cp "$MOLT_HOME/.install-manifest" "$TMP/update-manifest.before"
  for mode in download-failure invalid-source build-failure; do
    if UPDATE_MODE="$mode" "$MOLT" update >"$TMP/update.log" 2>&1; then fail "$mode succeeded"; fi
    [[ "$(readlink "$MOLT_HOME/current")" == "$original" ]] || fail "$mode replaced the working release"
    cmp -s "$TMP/update-manifest.before" "$MOLT_HOME/.install-manifest" || fail "$mode changed the manifest"
    [[ ! -e "$(dirname "$(<"$UPDATE_RECORD")")" && ! -d "$MOLT_HOME/state/install.lock" ]] || fail "$mode left its source or lock behind"
    "$MOLT" help >/dev/null || fail "$mode broke the CLI"
  done
  update_daemon_fixture
  mkdir -p "$TMP/update-failing-mv"
  cat >"$TMP/update-failing-mv/mv" <<'MV'
#!/usr/bin/env bash
if [[ "${!#}" == "$MOLT_HOME/.install-manifest" && "$1" == */manifest ]]; then exit 1; fi
exec /bin/mv "$@"
MV
  chmod +x "$TMP/update-failing-mv/mv"
  if PATH="$TMP/update-failing-mv:$PATH" "$MOLT" update >"$TMP/update.log" 2>&1; then fail 'failed commit succeeded'; fi
  [[ "$(readlink "$MOLT_HOME/current")" == "$original" && -S "$MOLT_HOME/state/home/.mutagen/daemon/daemon.sock" ]] || fail 'failed commit did not restore the release and synchronization'
  cmp -s "$TMP/update-manifest.before" "$MOLT_HOME/.install-manifest" || fail 'failed commit changed the manifest'
  if UPDATE_MODE=daemon-failure "$MOLT" update >"$TMP/update.log" 2>&1; then fail 'failed synchronization restart succeeded'; fi
  grep -Fq 'could not resume synchronization' "$TMP/update.log" || fail 'failed synchronization restart was not explained'
  rm -f "$TMP/bin/git" "$TMP/bin/go"
)

test_update_cancellation() (
  prepare_update
  local original="$(readlink "$MOLT_HOME/current")" mode
  cp "$MOLT_HOME/.install-manifest" "$TMP/update-manifest.before"
  for mode in cancel-download cancel-build; do
    rm -f "$UPDATE_STARTED"
    UPDATE_MODE="$mode" python3 - "$MOLT" <<'PY'
import os, pathlib, signal, subprocess, sys, time
with open(os.environ['UPDATE_RECORD'] + '.log', 'w') as log:
    child = subprocess.Popen([sys.argv[1], 'update'], stdout=log, stderr=log, start_new_session=True)
    try:
        deadline = time.monotonic() + 10
        while not pathlib.Path(os.environ['UPDATE_STARTED']).exists():
            assert child.poll() is None and time.monotonic() < deadline, 'update did not reach cancellation point'
            time.sleep(.02)
        os.killpg(child.pid, signal.SIGTERM)
        assert child.wait(timeout=5) != 0, 'cancelled update succeeded'
        source = pathlib.Path(os.environ['UPDATE_RECORD']).read_text().strip()
        while pathlib.Path(source).parent.exists() or pathlib.Path(os.environ['MOLT_HOME'], 'state/install.lock').exists():
            assert time.monotonic() < deadline, 'cancelled update did not clean up'
            time.sleep(.02)
    finally:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
PY
    [[ "$(readlink "$MOLT_HOME/current")" == "$original" ]] || fail 'cancelled update replaced the working release'
    cmp -s "$TMP/update-manifest.before" "$MOLT_HOME/.install-manifest" || fail 'cancelled update changed the manifest'
  done
  rm -f "$TMP/bin/git" "$TMP/bin/go"
)

test_action_capture() (
  install capture
  local work rc=0
  work="$(mktemp -d "$MOLT_HOME/state/tmp/action.XXXXXX")"
  "$MOLT" ui-action "$work" /bin/bash -c 'printf "success details\n"; printf "Building container image\n" >"$MOLT_UI_PROGRESS"' >/dev/null || fail 'successful action failed during cleanup'
  [[ "$(<"$work/progress")" == 'Building container image' ]] || fail 'action did not provide its progress file'
  [[ ! -f "$work/pid" ]] || fail 'successful action left a worker record'
  "$MOLT" ui-action "$work" /bin/bash -c 'printf "failure details\n"; exit 23' >/dev/null || rc=$?
  [[ "$rc" == 23 ]] || fail 'captured action lost its exit status'
  grep -qx 'failure details' "$work/output" || fail 'captured action lost its output'
  [[ ! -f "$work/pid" ]] || fail 'completed action left a worker record'
  touch "$work/cancel"
  rc=0
  "$MOLT" ui-action "$work" touch "$work/should-not-run" >/dev/null || rc=$?
  [[ "$rc" == 130 && ! -f "$work/should-not-run" ]] || fail 'an action cancelled before startup still ran'
)

test_ssh_paths() (
  install 'ssh with spaces %h'
  source "$ROOT/bin/_molt.sh"
  local output expected
  # A closed loopback port exercises native option expansion without authentication or a VM.
  output="$(molt_ssh -vvv -F /dev/null -o BatchMode=yes -o IdentityAgent=none -o IdentityFile=none -p 1 127.0.0.1 true 2>&1 || true)"
  expected="-> '$MOLT_HOME/state/ssh/known_hosts'"
  [[ "$output" == *"$expected"* ]] || fail 'SSH interpreted spaces/percent tokens instead of the contained known-hosts path'
)

for test in ${*:-test_config test_empty_connection test_connections test_connection_aliases test_shell_integration test_shell_edits test_failed_shell_activation test_project_management test_install_repair test_native_install test_install_options test_source_install_rebuilds_tui test_update test_update_failures test_update_cancellation test_action_capture test_ssh_paths}; do
  "$test"
  printf 'PASS: %s\n' "$test"
done
