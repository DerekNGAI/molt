#!/usr/bin/env bash
# Install onto this Mac: ~/.worker/{bin,shims,config}
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${WORKER_HOME:-$HOME/.worker}"

mkdir -p "$DEST/bin" "$DEST/shims"
cp -R "$SRC/bin/." "$DEST/bin/"
cp -R "$SRC/shims/." "$DEST/shims/"
chmod +x "$DEST/bin/worker" "$DEST/shims/"*

if command -v brew >/dev/null 2>&1 && ! command -v mutagen >/dev/null 2>&1; then
  echo "Installing Mutagen with Homebrew..."
  brew install mutagen-io/mutagen/mutagen
fi

if ! command -v mutagen >/dev/null 2>&1; then
  echo "Mutagen is required for file synchronization. Install it before starting a project."
fi

if ! command -v opencode >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  echo "Installing the local OpenCode client..."
  curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path
fi

if [[ ! -f "$DEST/config" ]]; then
  cp "$SRC/config.example" "$DEST/config"
  echo "wrote $DEST/config — edit WORKER_HOST"
fi

if [[ ! -f "$DEST/opencode.password" ]]; then
  umask 077
  : >"$DEST/opencode.password"
  echo "put the serve password in $DEST/opencode.password (chmod 600)"
fi
chmod 600 "$DEST/opencode.password"

ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
if [[ ! -f "$ZSHRC" ]]; then
  mkdir -p "$(dirname "$ZSHRC")"
  umask 022
  : >"$ZSHRC"
fi
if ! grep -Fq 'export PATH="$HOME/.worker/shims:$HOME/.worker/bin:$HOME/.opencode/bin:$PATH"' "$ZSHRC"; then
  {
    printf '\n# worker\n'
    printf '%s\n' 'export PATH="$HOME/.worker/shims:$HOME/.worker/bin:$HOME/.opencode/bin:$PATH"'
  } >>"$ZSHRC"
fi

echo
echo "Updated $ZSHRC. Start a new shell or run: source $ZSHRC"
echo
echo "Append $SRC/macos/ssh_config.snippet to ~/.ssh/config"
echo "Then: worker"
