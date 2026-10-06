#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-manage.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/bin" "$TMP/dotfiles"
export HOME="$TMP/home" ZDOTDIR="$TMP/dotfiles" PATH="$TMP/bin:/usr/bin:/bin"
export MOLT_MUTAGEN_BINARY="$TMP/bin/mutagen" MOLT_OPENCODE_BINARY="$TMP/bin/opencode" MOLT_GUM_BINARY="$TMP/bin/gum"
for tool in mutagen opencode; do
  printf '#!/usr/bin/env bash\ncase "$*" in version) printf "0.18.1\\n" ;; --version) printf "2.0.2\\n" ;; esac\n' >"$TMP/bin/$tool"
done
printf '#!/usr/bin/env bash\nprintf "gum version v2.0.2 (test)\\n"\n' >"$TMP/bin/gum"
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

test_gum_install() (
  export MOLT_HOME="$HOME/private-gum" MOLT_BOOTSTRAP_GUM_BINARY="$MOLT_GUM_BINARY" MOLT_GUM_BINARY=''
  /bin/bash "$ROOT/install.sh" --non-interactive >"$TMP/install.log" 2>&1
  [[ -x "$MOLT_HOME/tools/gum/gum" ]] || fail 'bootstrap Gum was not installed privately'
  grep -Fxq "GUM_BINARY=$MOLT_HOME/tools/gum/gum" "$MOLT_HOME/.install-manifest" || fail 'Gum manifest points to the temporary bootstrap directory'
  [[ -x "$MOLT_HOME/current/install.sh" && -f "$MOLT_HOME/current/config.example" ]] || fail 'installation cannot repair itself'
  [[ -x "$MOLT_HOME/MOLT.command" ]] || fail 'missing Finder launcher'
  /bin/bash "$MOLT_HOME/current/install.sh" --non-interactive >"$TMP/repair.log" 2>&1 || { cat "$TMP/repair.log" >&2; fail 'installation could not repair itself from its owned release'; }
)

test_install_options() (
  export MOLT_HOME="$HOME/invalid-option"
  if /bin/bash "$ROOT/install.sh" --invalid >"$TMP/install.log" 2>&1; then fail 'accepted an unknown installer option'; fi
  [[ ! -e "$MOLT_HOME" ]] || fail 'unknown installer option left an installation behind'
)

test_action_capture() (
  install capture
  local work rc=0
  work="$(mktemp -d "$MOLT_HOME/state/tmp/action.XXXXXX")"
  "$MOLT" ui-action "$work" /bin/bash -c 'printf "success details\n"' >/dev/null || fail 'successful action failed during cleanup'
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

for test in ${*:-test_config test_empty_connection test_connections test_connection_aliases test_shell_integration test_shell_edits test_failed_shell_activation test_project_management test_gum_install test_install_options test_action_capture test_ssh_paths}; do
  "$test"
  printf 'PASS: %s\n' "$test"
done
