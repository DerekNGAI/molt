#!/usr/bin/env bash
set -euo pipefail

MOLT_HOME="${MOLT_HOME:-$HOME/.molt}"
MANIFEST="$MOLT_HOME/.install-manifest"
YES=0

usage() {
  cat <<USAGE
molt-uninstall — remove molt from this Mac

  molt-uninstall          ask before removing molt
  molt-uninstall --yes    remove molt without prompting
USAGE
}

die() {
  printf 'molt: %s\n' "$*" >&2
  exit 1
}

manifest_value() {
  local key="$1"
  [[ -f "$MANIFEST" ]] || return 1
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$MANIFEST"
}

remove_path_entry() {
  local zshrc="$1" molt_home_line="$2" path_line="$3" created="$4" tmp mode
  [[ -f "$zshrc" ]] || return 0

  tmp="$(mktemp "${TMPDIR:-/tmp}/molt-zshrc.XXXXXX")"
  if ! awk -v molt_home_line="$molt_home_line" -v path_line="$path_line" '
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (lines[i] == path_line || (molt_home_line != "" && lines[i] == molt_home_line)) {
          removed[i] = 1
          if (lines[i] == molt_home_line && i > 1 && lines[i - 1] == "# molt") {
            removed[i - 1] = 1
            if (i > 2 && lines[i - 2] == "") removed[i - 2] = 1
          }
        }
      }
      for (i = 1; i <= NR; i++) if (!removed[i]) print lines[i]
    }
  ' "$zshrc" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mode="$(stat -f '%Lp' "$zshrc" 2>/dev/null || printf '644')"
  if ! chmod "$mode" "$tmp" || ! mv "$tmp" "$zshrc"; then
    rm -f "$tmp"
    return 1
  fi

  if [[ "$created" == 1 ]] && [[ -z "$(tr -d '[:space:]' <"$zshrc")" ]]; then
    rm -f "$zshrc"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$MOLT_HOME" != "$HOME" && "$MOLT_HOME" != / ]] || die "refusing to remove MOLT_HOME=$MOLT_HOME"

if [[ "$YES" != 1 ]]; then
  printf 'Remove molt, its local state, and dependencies installed by molt? [y/N] '
  read -r answer
  [[ "$answer" == y || "$answer" == Y ]] || exit 0
fi

if [[ -x "$MOLT_HOME/bin/molt" ]]; then
  MOLT_ASSUME_YES=1 "$MOLT_HOME/bin/molt" reset --all
  "$MOLT_HOME/bin/molt" remove-remote-roots
  "$MOLT_HOME/bin/molt" down || true
fi

ZSHRC="$(manifest_value ZSHRC 2>/dev/null || printf '%s' "${ZDOTDIR:-$HOME}/.zshrc")"
MOLT_HOME_LINE="$(manifest_value MOLT_HOME_LINE 2>/dev/null || printf '%s' '')"
PATH_LINE="$(manifest_value PATH_LINE 2>/dev/null || printf '%s' 'export PATH="$HOME/.molt/shims:$HOME/.molt/bin:$HOME/.opencode/bin:$PATH"')"
ZSHRC_CREATED="$(manifest_value ZSHRC_CREATED 2>/dev/null || printf '0')"
PATH_ADDED="$(manifest_value PATH_ADDED 2>/dev/null || printf '0')"
MUTAGEN_INSTALLED="$(manifest_value MUTAGEN_INSTALLED 2>/dev/null || printf '0')"
OPENCODE_INSTALLED="$(manifest_value OPENCODE_INSTALLED 2>/dev/null || printf '0')"

if [[ "$PATH_ADDED" == 1 ]]; then
  remove_path_entry "$ZSHRC" "$MOLT_HOME_LINE" "$PATH_LINE" "$ZSHRC_CREATED"
fi

if [[ "$MUTAGEN_INSTALLED" == 1 ]]; then
  command -v mutagen >/dev/null 2>&1 && mutagen daemon stop >/dev/null 2>&1 || true
  command -v brew >/dev/null 2>&1 && brew uninstall mutagen >/dev/null 2>&1 || true
fi

if [[ "$OPENCODE_INSTALLED" == 1 ]]; then
  rm -f "$HOME/.opencode/bin/opencode"
  rmdir "$HOME/.opencode/bin" 2>/dev/null || true
  rmdir "$HOME/.opencode" 2>/dev/null || true
fi

rm -rf "$MOLT_HOME"
printf 'molt: removed local installation\n'
