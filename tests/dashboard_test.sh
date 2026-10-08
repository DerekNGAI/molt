#!/usr/bin/env bash
# Telemetry uses an isolated installation and SSH double; never the user's VM.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-dashboard.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/install/bin" "$TMP/install/remote" "$TMP/tools"
cp "$ROOT/bin/"*.sh "$ROOT/bin/molt" "$TMP/install/bin/"
cp "$ROOT/remote/monitor.sh" "$TMP/install/remote/"
export HOME="$TMP/home" MOLT_HOME="$TMP/install" PATH="$TMP/tools:/usr/bin:/bin"
printf 'FORMAT=2\nINSTALL_ID=0123456789abcdef0123456789abcdef\nROOT=%s\nSTATUS=ready\n' "$MOLT_HOME" >"$MOLT_HOME/.install-manifest"
printf 'MOLT_HOST=fixture-vm\nMOLT_ROOT=%q\n' "$HOME" >"$MOLT_HOME/config"
cat >"$TMP/tools/ssh" <<'SSH'
#!/usr/bin/env bash
[[ "$*" == *'BatchMode=yes'* && "$*" == *'StrictHostKeyChecking=yes'* ]] || exit 3
[[ "${!#}" == *'bash -s --'* ]] || exit 4
printf 'system\t1000\t700\t8192\t4096\t100000\t30000\t3600\t1.2 0.8 0.5\t2048\t4096\tfixture CPU\ndocker\tready\n'
SSH
chmod +x "$TMP/tools/ssh"
MOLT="$MOLT_HOME/bin/molt"
output="$(/bin/bash "$MOLT" monitor host fixture-vm)"
[[ "$output" == *$'system\t1000'* && "$output" == *$'docker\tready'* ]] || { printf 'FAIL: missing telemetry\n' >&2; exit 1; }
[[ "$(/bin/bash "$MOLT" monitor sync)" == '[]' ]] || { printf 'FAIL: missing daemon should yield empty sessions\n' >&2; exit 1; }
[[ ! -e "$MOLT_HOME/state/home/.mutagen/daemon/daemon.sock" ]] || { printf 'FAIL: monitoring started a daemon\n' >&2; exit 1; }
if /bin/bash "$MOLT" monitor host '-oProxyCommand=touch injected' >/dev/null 2>&1; then printf 'FAIL: invalid host accepted\n' >&2; exit 1; fi
[[ ! -e "$MOLT_HOME/state/ssh/injected" ]] || exit 1
printf 'molt dashboard backend tests: ok\n'
