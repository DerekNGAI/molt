#!/usr/bin/env bash
# Install a private, session-activated molt installation.
set -euo pipefail
umask 077
SRC="$(cd "$(dirname "$0")" && pwd -P)"
source "$SRC/bin/_molt.sh"
MOLT_HOME="${MOLT_HOME:-$HOME/.molt}"
INTERACTIVE=auto
while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive) INTERACTIVE=0 ;;
    --interactive) INTERACTIVE=1 ;;
    --help|-h) printf 'install.sh [--interactive|--non-interactive]\n\nInteractive terminals open the local setup wizard.\n'; exit 0 ;;
    *) molt_error "unknown installer option: $1"; exit 2 ;;
  esac
  shift
done
if [[ "$INTERACTIVE" == 1 || ( "$INTERACTIVE" == auto && -t 0 && -t 1 ) ]]; then
  [[ -t 0 && -t 1 ]] || { molt_error 'interactive installation requires a terminal'; exit 1; }
  binary="${MOLT_TUI_BINARY:-$SRC/bin/molt-tui}"
  if [[ ! -x "$binary" || -d "$binary" || ( -z "${MOLT_TUI_BINARY:-}" && -e "$SRC/.git" ) ]]; then
    command -v go >/dev/null 2>&1 || { molt_error 'install Go 1.26 or supply MOLT_TUI_BINARY to build the control center'; exit 1; }
    bootstrap="$(mktemp -d "${TMPDIR:-/tmp}/molt-bootstrap.XXXXXX")"
    trap 'rm -rf -- "$bootstrap"' EXIT
    binary="$bootstrap/molt-tui"
    printf 'molt: building the terminal interface...\n'
    (cd "$SRC/tui" && CGO_ENABLED=0 go build -trimpath -o "$binary" .)
  fi
  "$binary" --home "$MOLT_HOME" --install-source "$SRC"
  exit $?
fi
molt_safe_home || exit 1
if [[ "$MOLT_HOME" == "$SRC" || "$MOLT_HOME" == "$SRC/"* || "$SRC" == "$MOLT_HOME/"* ]]; then
  [[ "$SRC" == "$MOLT_HOME/releases/"* && "$SRC" == "$(molt_canonical "$MOLT_HOME/current")" ]] && molt_owned_home || {
    molt_error 'MOLT_HOME must not overlap the source checkout'; exit 1;
  }
fi

FRESH=0; LEGACY=0; STAGE=""; SWITCHED=0; COMMITTED=0; LEGACY_MOVED=0
OLD_CURRENT="$(readlink "$MOLT_HOME/current" 2>/dev/null || true)"
LOCKED=0; LOCK="$MOLT_HOME/state/install.lock"
MANIFEST="$MOLT_HOME/.install-manifest"
if [[ -f "$MANIFEST" ]]; then
  if [[ "$(molt_value "$MANIFEST" FORMAT 2>/dev/null || true)" == 2 ]]; then
    molt_owned_home || exit 1
  else
    [[ ! -L "$MANIFEST" && -d "$MOLT_HOME/bin" && -d "$MOLT_HOME/shims" ]] &&
      molt_value "$MANIFEST" ZSHRC >/dev/null && molt_value "$MANIFEST" PATH_ADDED >/dev/null || {
        molt_error 'unrecognized installation manifest'; exit 1;
      }
    LEGACY=1
    MOLT_INSTALL_ID="$(molt_id)"
  fi
elif [[ -d "$MOLT_HOME" && -n "$(ls -A "$MOLT_HOME")" ]]; then
  molt_error "refusing populated, unowned directory: $MOLT_HOME"; exit 1
else
  FRESH=1
  MOLT_INSTALL_ID="$(molt_id)"
fi

cleanup_install() {
  local rc=$? recovery=0
  trap - EXIT
  if [[ "$COMMITTED" == 0 ]]; then
    if [[ "$SWITCHED" == 1 && -n "$OLD_CURRENT" ]]; then
      ln -s "$OLD_CURRENT" "$MOLT_HOME/current.restore" &&
        mv -fh "$MOLT_HOME/current.restore" "$MOLT_HOME/current" || recovery=1
    elif [[ "$SWITCHED" == 1 ]]; then
      rm -f "$MOLT_HOME/current" || recovery=1
    fi
    if [[ -n "$STAGE" && -f "$STAGE/previous.manifest" ]]; then
      mv -f "$STAGE/previous.manifest" "$MANIFEST" || recovery=1
    fi
    if [[ -n "$STAGE" && -f "$STAGE/previous.activation" ]]; then
      mv -f "$STAGE/previous.activation" "$MOLT_HOME/activate.zsh" || recovery=1
    fi
    if [[ "$LEGACY_MOVED" == 1 ]]; then
      for name in bin shims; do
        [[ ! -L "$MOLT_HOME/$name" ]] || rm -f "$MOLT_HOME/$name"
        [[ ! -d "$MOLT_HOME/legacy-$name" ]] || mv "$MOLT_HOME/legacy-$name" "$MOLT_HOME/$name"
      done
    fi
    if [[ "$recovery" == 0 ]]; then
      [[ -z "$STAGE" ]] || rm -rf "$STAGE"
      [[ "$FRESH" == 0 ]] || rm -rf "$MOLT_HOME"
    else molt_error "rollback incomplete; recovery files are retained in $STAGE"; fi
  fi
  if [[ "$LOCKED" == 1 ]]; then rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true; fi
  exit "$rc"
}
trap cleanup_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
molt_state
[[ ! -L "$LOCK" ]] || { molt_error 'symlinked installation lock'; exit 1; }
if ! mkdir "$LOCK" 2>/dev/null; then
  previous=""
  if [[ -f "$LOCK/pid" ]]; then IFS= read -r previous <"$LOCK/pid" || true; fi
  [[ "$previous" =~ ^[0-9]+$ ]] && ! kill -0 "$previous" 2>/dev/null || { molt_error 'another installation is running'; exit 1; }
  rm -f "$LOCK/pid"
  rmdir "$LOCK"
  mkdir "$LOCK"
fi
LOCKED=1
printf '%s\n' "$$" >"$LOCK/pid"
for name in config opencode.password; do
  [[ ! -L "$MOLT_HOME/$name" ]] || { molt_error "symlinked $name is outside the installation contract"; exit 1; }
done
if [[ "$FRESH" == 1 ]]; then
  printf 'FORMAT=2\nINSTALL_ID=%s\nROOT=%s\nSTATUS=installing\n' "$MOLT_INSTALL_ID" "$MOLT_HOME" >"$MANIFEST"
fi
mkdir -p "$MOLT_HOME/releases"
[[ ! -L "$MOLT_HOME/releases" ]] || { molt_error 'symlinked releases directory'; exit 1; }
STAGE="$(mktemp -d "$MOLT_HOME/releases/install.XXXXXX")"
[[ ! -f "$MANIFEST" ]] || cp -p "$MANIFEST" "$STAGE/previous.manifest"
[[ ! -f "$MOLT_HOME/activate.zsh" ]] || cp -p "$MOLT_HOME/activate.zsh" "$STAGE/previous.activation"
mkdir -p "$STAGE/bin" "$STAGE/shims" "$STAGE/tools"
cp -R "$SRC/bin/." "$STAGE/bin/"
cp -R "$SRC/shims/." "$STAGE/shims/"
cp -R "$SRC/remote" "$STAGE/remote"
if [[ -d "$SRC/tui" ]]; then cp -R "$SRC/tui" "$STAGE/tui"; fi
cp "$SRC/uninstall.sh" "$STAGE/bin/molt-uninstall"
cp "$SRC/install.sh" "$SRC/uninstall.sh" "$SRC/config.example" "$STAGE/"
cp "$SRC/tools.lock" "$STAGE/tools.lock"
chmod +x "$STAGE/bin/"* "$STAGE/shims/"*
# Rebuild sources when Go is available; Git checkouts must not reuse stale binaries.
# Packaged executables and explicit overrides can install without Go.
if [[ -n "${MOLT_TUI_BINARY:-}" ]]; then
  [[ -x "$MOLT_TUI_BINARY" && ! -d "$MOLT_TUI_BINARY" ]] || { molt_error 'invalid dashboard executable'; exit 1; }
  cp "$MOLT_TUI_BINARY" "$STAGE/bin/molt-tui"
elif [[ -d "$STAGE/tui" ]]; then
  if command -v go >/dev/null 2>&1; then
    printf 'molt: building the terminal dashboard...\n'
    (cd "$STAGE/tui" && CGO_ENABLED=0 go build -trimpath -o ../bin/molt-tui .)
  elif [[ -e "$SRC/.git" || ! -x "$STAGE/bin/molt-tui" ]]; then
    molt_error 'install Go 1.26 or supply MOLT_TUI_BINARY; the Bubble Tea control center is required'; exit 1
  fi
fi
[[ -x "$STAGE/bin/molt-tui" ]] || { molt_error 'missing Bubble Tea control center'; exit 1; }
cat >"$STAGE/MOLT.command" <<'LAUNCHER'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd -P)"
if [[ -f "$here/.install-manifest" ]]; then export MOLT_HOME="$here";
else export MOLT_HOME="${here%/releases/*}"; fi
exec "$MOLT_HOME/bin/molt" tui
LAUNCHER
chmod +x "$STAGE/MOLT.command"
mkdir -p "$STAGE/bin/transport"
for name in ssh scp; do
  if [[ -L "$STAGE/bin/transport/$name" ]]; then
    [[ "$(readlink "$STAGE/bin/transport/$name")" == ../mutagen-transport ]] || { molt_error 'unexpected transport symlink'; exit 1; }
  elif [[ -e "$STAGE/bin/transport/$name" ]]; then molt_error 'unexpected transport executable'; exit 1;
  else ln -s ../mutagen-transport "$STAGE/bin/transport/$name"; fi
done

download_tool() {
  molt_download_tool "$1" "$STAGE" "$SRC/tools.lock" >/dev/null || return 1
  printf '%s\n' "$MOLT_HOME/tools/$1/$1"
}

resolve_tool() {
  local name="$1" explicit="$2" binary
  if [[ -n "$explicit" ]]; then molt_dependency "$name" "$explicit"; return; fi
  # Reuse an owned portable tool without depending on PATH or a command shim.
  if [[ "$LEGACY" == 0 && -x "$MOLT_HOME/tools/$name/$name" ]]; then
    cp -R "$MOLT_HOME/tools/$name" "$STAGE/tools/"
    printf '%s\n' "$MOLT_HOME/tools/$name/$name"; return
  fi
  binary="$(molt_dependency "$name" || true)"
  if [[ -n "$binary" ]]; then printf '%s\n' "$binary"; else download_tool "$name"; fi
}
MUTAGEN_BINARY="$(resolve_tool mutagen "${MOLT_MUTAGEN_BINARY:-}")"
OPENCODE_BINARY="$(resolve_tool opencode "${MOLT_OPENCODE_BINARY:-}")"
check_binary() {
  local binary="$1"
  case "$binary" in "$MOLT_HOME/tools/"*) binary="$STAGE/tools/${binary#"$MOLT_HOME/tools/"}" ;; esac
  molt_isolated "$binary" "${@:2}"
}
[[ "$(check_binary "$MUTAGEN_BINARY" version)" == 0.18.1 ]] || {
  molt_error 'Mutagen 0.18.1 is required for the contained transport'; exit 1;
}
[[ -n "$(check_binary "$OPENCODE_BINARY" --version)" ]] || { molt_error 'invalid OpenCode client'; exit 1; }

cat >"$STAGE/manifest" <<EOF
FORMAT=2
INSTALL_ID=$MOLT_INSTALL_ID
ROOT=$MOLT_HOME
STATUS=ready
MUTAGEN_BINARY=$MUTAGEN_BINARY
OPENCODE_BINARY=$OPENCODE_BINARY
EOF
# Activation derives its own path, including custom paths with spaces or quotes.
cat >"$STAGE/activate.zsh" <<'ACTIVATE'
export MOLT_HOME="${${(%):-%x}:A:h}"
typeset -U path
path=("$MOLT_HOME/shims" "$MOLT_HOME/bin" $path)
export PATH
ACTIVATE

if [[ "$LEGACY" == 1 ]]; then
  cp "$MANIFEST" "$MOLT_HOME/legacy-install-manifest"
  # Legacy binaries remain available if a migration is interrupted.
  [[ ! -e "$MOLT_HOME/legacy-bin" && ! -e "$MOLT_HOME/legacy-shims" ]] || { molt_error 'legacy backup already exists; restore it before migrating'; exit 1; }
  LEGACY_MOVED=1
  mv "$MOLT_HOME/bin" "$MOLT_HOME/legacy-bin"
  mv "$MOLT_HOME/shims" "$MOLT_HOME/legacy-shims"
  molt_error 'legacy global dependencies and shared tool state are preserved; see README migration notes'
fi
if [[ -f "$MANIFEST" && "$LEGACY" == 0 && -d "$MOLT_HOME/state/home/.mutagen/daemon" ]]; then
  replacement="$MUTAGEN_BINARY"
  case "$replacement" in "$MOLT_HOME/tools/"*) replacement="$STAGE/tools/${replacement#"$MOLT_HOME/tools/"}" ;; esac
  MOLT_MUTAGEN_BINARY="$replacement" molt_stop_daemon
fi
[[ -f "$MOLT_HOME/config" ]] || cp "$SRC/config.example" "$MOLT_HOME/config"
[[ -f "$MOLT_HOME/opencode.password" ]] || : >"$MOLT_HOME/opencode.password"
chmod 600 "$MOLT_HOME/opencode.password"
for name in bin shims tools MOLT.command; do
  if [[ -L "$MOLT_HOME/$name" ]]; then
    [[ "$(readlink "$MOLT_HOME/$name")" == "current/$name" ]] || { molt_error "unexpected $name symlink"; exit 1; }
  elif [[ -e "$MOLT_HOME/$name" ]]; then molt_error "unexpected $name directory"; exit 1
  else ln -s "current/$name" "$MOLT_HOME/$name"; fi
done
[[ ! -e "$MOLT_HOME/current.next" || -L "$MOLT_HOME/current.next" ]] || { molt_error 'unexpected current.next directory'; exit 1; }
rm -f "$MOLT_HOME/current.next"
ln -s "releases/$(basename "$STAGE")" "$MOLT_HOME/current.next"
# -h on macOS prevents mv following the existing directory symlink.
mv -fh "$MOLT_HOME/current.next" "$MOLT_HOME/current"
SWITCHED=1
mv "$STAGE/manifest" "$MANIFEST"
cp "$STAGE/activate.zsh" "$MOLT_HOME/activate.zsh"
COMMITTED=1
if [[ "$LEGACY" == 1 ]]; then
  molt_remove_legacy_shell "$MOLT_HOME/legacy-install-manifest"
  for state in "$MOLT_HOME/projects"/*/path; do
    [[ -f "$state" ]] || continue
    printf 'legacy\n' >"$(dirname "$state")/layout"
  done
fi
printf 'molt: installed in %s\nActivate this session: source %q\n' "$MOLT_HOME" "$MOLT_HOME/activate.zsh"
