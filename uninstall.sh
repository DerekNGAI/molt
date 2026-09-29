#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/_molt.sh" ]]; then source "$SCRIPT_DIR/_molt.sh";
else source "$SCRIPT_DIR/bin/_molt.sh"; fi
if [[ -f "${SCRIPT_DIR%/*}/.install-manifest" ]]; then MOLT_HOME="${MOLT_HOME:-${SCRIPT_DIR%/*}}";
else MOLT_HOME="${MOLT_HOME:-$HOME/.molt}"; fi
YES=0; LOCAL_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --local-only) LOCAL_ONLY=1 ;;
    --help|-h)
      printf 'molt-uninstall [--yes] [--local-only]\n\nDefault: remove owned remote and local resources; keep records if cleanup fails.\n--local-only: remove this Mac installation, leaving remote resources.\n'; exit 0 ;;
    *) molt_error "unknown option: $1"; exit 2 ;;
  esac
  shift
done
molt_safe_home || exit 1
[[ -e "$MOLT_HOME" ]] || { printf 'molt: already removed\n'; exit 0; }
molt_owned_home || exit 1
if [[ "$YES" == 0 ]]; then
  printf 'Remove molt%s? [y/N] ' "$(if [[ "$LOCAL_ONLY" == 1 ]]; then printf ' locally, leaving remote resources'; else printf ' and its owned remote resources'; fi)"
  read -r answer
  [[ "$answer" == y || "$answer" == Y ]] || exit 0
fi
export MOLT_HOME
if [[ "$LOCAL_ONLY" == 1 ]]; then
  printf 'Remote resources left for manual cleanup:\n'
  "$MOLT_HOME/bin/molt" cleanup-inventory
else
  "$MOLT_HOME/bin/molt" local-down || exit 1
  MOLT_ASSUME_YES=1 "$MOLT_HOME/bin/molt" reset --all || {
    molt_error 'cleanup failed; installation and retry records preserved'; exit 1;
  }
  "$MOLT_HOME/bin/molt" remove-remote-roots || {
    molt_error 'remote root cleanup failed; retry records preserved'; exit 1;
  }
fi
"$MOLT_HOME/bin/molt" local-down || { molt_error 'could not stop owned local processes'; exit 1; }
if [[ -f "$MOLT_HOME/legacy-install-manifest" ]]; then
  molt_remove_legacy_shell "$MOLT_HOME/legacy-install-manifest"
  molt_error 'legacy shared dependencies, SSH entries, and shared tool state are preserved'
fi
molt_owned_home || exit 1
rm -rf -- "$MOLT_HOME"
printf 'molt: removed local installation\n'
