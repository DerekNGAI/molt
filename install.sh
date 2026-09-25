#!/usr/bin/env bash
# Install onto this Mac: ~/.worker/{bin,shims,config}
set -euo pipefail

die() {
  printf 'worker: %s\n' "$*" >&2
  exit 1
}

manifest_value() {
  local key="$1"
  [[ -f "$MANIFEST" ]] || return 1
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$MANIFEST"
}

write_manifest() {
  (umask 077; cat >"$MANIFEST" <<EOF
ZSHRC=$ZSHRC
WORKER_HOME_LINE=$WORKER_HOME_LINE
PATH_LINE=$PATH_LINE
ZSHRC_CREATED=$ZSHRC_CREATED
PATH_ADDED=$PATH_ADDED
MUTAGEN_INSTALLED=$MUTAGEN_INSTALLED
OPENCODE_INSTALLED=$OPENCODE_INSTALLED
EOF
  )
}

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${WORKER_HOME:-$HOME/.worker}"
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd -P)"
[[ "$DEST" != "$SRC" && "$DEST" != "$SRC/"* ]] || die "WORKER_HOME must be outside the source checkout"

ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
WORKER_HOME_LINE="export WORKER_HOME=\"$DEST\""
PATH_LINE="export PATH=\"$DEST/shims:$DEST/bin:$HOME/.opencode/bin:\$PATH\""
MANIFEST="$DEST/.install-manifest"

ZSHRC_CREATED="$(manifest_value ZSHRC_CREATED 2>/dev/null || printf '0')"
PATH_ADDED="$(manifest_value PATH_ADDED 2>/dev/null || printf '0')"
MUTAGEN_INSTALLED="$(manifest_value MUTAGEN_INSTALLED 2>/dev/null || printf '0')"
OPENCODE_INSTALLED="$(manifest_value OPENCODE_INSTALLED 2>/dev/null || printf '0')"

if [[ ! -f "$ZSHRC" ]]; then
  ZSHRC_CREATED=1
fi
write_manifest

if command -v brew >/dev/null 2>&1 && ! command -v mutagen >/dev/null 2>&1; then
  echo "Installing Mutagen with Homebrew..."
  brew install mutagen-io/mutagen/mutagen
  MUTAGEN_INSTALLED=1
  write_manifest
fi

command -v mutagen >/dev/null 2>&1 || die "Mutagen is required; install it with Homebrew or add it to PATH"

if ! command -v opencode >/dev/null 2>&1 && [[ ! -x "$HOME/.opencode/bin/opencode" ]]; then
  command -v curl >/dev/null 2>&1 || die "OpenCode is required; install it or add curl to PATH"
  echo "Installing the local OpenCode client..."
  curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path
  [[ -x "$HOME/.opencode/bin/opencode" ]] || die "OpenCode installation did not produce $HOME/.opencode/bin/opencode"
  OPENCODE_INSTALLED=1
  write_manifest
fi

if ! command -v opencode >/dev/null 2>&1 && [[ ! -x "$HOME/.opencode/bin/opencode" ]]; then
  die "OpenCode is required; install it or add it to PATH"
fi

rm -rf "$DEST/bin" "$DEST/shims"
mkdir -p "$DEST/bin" "$DEST/shims"
cp -R "$SRC/bin/." "$DEST/bin/"
cp -R "$SRC/shims/." "$DEST/shims/"
cp "$SRC/uninstall.sh" "$DEST/bin/worker-uninstall"
chmod +x "$DEST/bin/worker" "$DEST/bin/worker-uninstall" "$DEST/shims/"*

if [[ ! -f "$DEST/config" ]]; then
  cp "$SRC/config.example" "$DEST/config"
  echo "wrote $DEST/config — edit WORKER_HOST"
fi

if [[ ! -f "$DEST/opencode.password" ]]; then
  (umask 077; : >"$DEST/opencode.password")
  echo "put the serve password in $DEST/opencode.password (chmod 600)"
fi
chmod 600 "$DEST/opencode.password"

if [[ ! -f "$ZSHRC" ]]; then
  mkdir -p "$(dirname "$ZSHRC")"
  (umask 022; : >"$ZSHRC")
fi
if ! grep -Fqx "$PATH_LINE" "$ZSHRC"; then
  {
    printf '\n# worker\n'
    printf '%s\n' "$WORKER_HOME_LINE"
    printf '%s\n' "$PATH_LINE"
  } >>"$ZSHRC"
  PATH_ADDED=1
  write_manifest
fi

echo
echo "Updated $ZSHRC. Start a new shell or run: source $ZSHRC"
echo
echo "Append $SRC/macos/ssh_config.snippet to ~/.ssh/config"
echo "Then: worker"
