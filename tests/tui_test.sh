#!/usr/bin/env bash
# Exercise the real Gum UI in a pseudo-terminal; SSH and project tools are disposable doubles.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-tui.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/bin" "$TMP/repos/app"
export HOME="$TMP/home" ZDOTDIR="$TMP/home" MOLT_HOME="$TMP/home/.molt" TERM=xterm-256color
export MOLT_MUTAGEN_BINARY="$TMP/bin/mutagen" MOLT_OPENCODE_BINARY="$TMP/bin/opencode"
for tool in mutagen opencode; do
  printf '#!/usr/bin/env bash\ncase "$*" in version) printf "0.18.1\\n" ;; --version) printf "1.18.33\\n" ;; esac\n' >"$TMP/bin/$tool"
done
cat >"$TMP/bin/ssh" <<'SSH'
#!/usr/bin/env bash
if [[ -f "$TUI_TMP/hold-ssh" && "$*" == *'-O check'* ]]; then
  printf '%s\n' "$$" >"$TUI_TMP/held.pid"
  sleep 60 & wait
fi
for arg in "$@"; do
  if [[ "$arg" == -G ]]; then exec /usr/bin/ssh "$@"; fi
done
exit 255
SSH
chmod +x "$TMP/bin/"*
source "$ROOT/bin/_molt.sh"
if [[ -z "${MOLT_GUM_BINARY:-}" ]]; then MOLT_GUM_BINARY="$(molt_download_tool gum "$TMP" "$ROOT/tools.lock")"; fi
export MOLT_GUM_BINARY
molt_gum_version "$MOLT_GUM_BINARY"
export PATH="$TMP/bin:/usr/bin:/bin"
/bin/bash "$ROOT/install.sh" --non-interactive >/dev/null
git -C "$TMP/repos/app" init -q
"$MOLT_HOME/bin/molt" config set MOLT_ROOT "$TMP/repos"
"$MOLT_HOME/bin/molt" config set MOLT_HOST unreachable-vm
"$MOLT_HOME/bin/molt" config set MOLT_ANIMATIONS 0
"$MOLT_HOME/bin/molt" register "$TMP/repos/app" >/dev/null
mkdir -p "$HOME/.ssh"
printf 'Include "%s/aliases.conf"\n' "$TMP" >"$HOME/.ssh/config"
printf 'Host unreachable-vm\n  HostName vm.example\n  User ubuntu\nHost alternate-vm\n  HostName alternate.example\n  User developer\n  Port 2222\n' >"$TMP/aliases.conf"
export TUI_ROOT="$ROOT" TUI_TMP="$TMP"
/usr/bin/expect "$ROOT/tests/tui_test.exp"
[[ ! -e "$MOLT_HOME" ]] || { printf 'FAIL: TUI uninstall left the installation\n' >&2; exit 1; }
mkdir -p "$TMP/vm"
cat >"$TMP/bin/ssh" <<'SSH'
#!/usr/bin/env bash
previous=''
for arg in "$@"; do
  if [[ "$previous" == -O ]]; then
    if [[ "$arg" == check ]]; then [[ -f "$TUI_TMP/connected" ]]; exit $?;
    elif [[ "$arg" == exit ]]; then rm -f "$TUI_TMP/connected"; exit 0; fi
  fi
  if [[ "$arg" == -fN ]]; then touch "$TUI_TMP/connected"; exit 0; fi
  previous="$arg"
done
touch "$TUI_TMP/connected"
HOME="$TUI_TMP/vm" /bin/bash -c "${!#}"
SSH
cat >"$TMP/bin/realpath" <<'REALPATH'
#!/usr/bin/env bash
source "$TUI_ROOT/bin/_molt.sh"
[[ "${1:-}" != -m ]] || shift
[[ "${1:-}" != -- ]] || shift
molt_canonical "$1"
REALPATH
cat >"$TMP/bin/awk" <<'AWK'
#!/usr/bin/env bash
if [[ "${!#}" == /etc/os-release ]]; then printf 'ubuntu\n'; else exec /usr/bin/awk "$@"; fi
AWK
cat >"$TMP/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
case "$1 ${2:-}" in 'info '*|'container ls') exit 0 ;; *) exit 2 ;; esac
DOCKER
chmod +x "$TMP/bin/"*
ssh-keygen -q -t ed25519 -N '' -f "$TMP/login-key"
export MOLT_HOME="$HOME/from-zero"
/usr/bin/expect "$ROOT/tests/setup_test.exp"
[[ ! -e "$MOLT_HOME" && ! -e "$TMP/vm/molt" && ! -e "$HOME/.zshrc" ]] || { printf 'FAIL: guided lifecycle left managed resources\n' >&2; exit 1; }
printf 'molt terminal interaction tests: ok\n'
