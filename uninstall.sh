#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/_molt.sh" ]]; then source "$SCRIPT_DIR/_molt.sh";
else source "$SCRIPT_DIR/bin/_molt.sh"; fi
if [[ -f "${SCRIPT_DIR%/*}/.install-manifest" ]]; then MOLT_HOME="${MOLT_HOME:-${SCRIPT_DIR%/*}}";
else MOLT_HOME="${MOLT_HOME:-$HOME/.molt}"; fi
YES=0; LOCAL_ONLY=0; UNDO_VM=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --local-only) LOCAL_ONLY=1 ;;
    --undo-vm) UNDO_VM=1 ;;
    --help|-h)
      printf 'molt-uninstall [--yes] [--local-only|--undo-vm]\n\nDefault: remove owned remote and local resources; keep records if cleanup fails.\n--local-only: remove this Mac installation, leaving remote resources.\n--undo-vm: also undo recorded Docker installation/user access when the daemon has no containers or volumes.\n'; exit 0 ;;
    *) molt_error "unknown option: $1"; exit 2 ;;
  esac
  shift
done
[[ "$LOCAL_ONLY" == 0 || "$UNDO_VM" == 0 ]] || { molt_error '--local-only and --undo-vm cannot be combined'; exit 2; }
molt_safe_home || exit 1
[[ -e "$MOLT_HOME" ]] || { printf 'molt: already removed\n'; exit 0; }
molt_owned_home || exit 1
warn_local_uninstall() {
  molt_error 'WARNING: VM resources may remain running. Workspaces, images, caches, provider credentials, SSH authorization, and VM preparation may remain. Remote edits will not be synchronized, and local cleanup records will be deleted.'
  "$MOLT_HOME/bin/molt" cleanup-inventory
}
SETUP_STATE="$("$MOLT_HOME/bin/molt" setup-state)" || exit 1
if [[ "$LOCAL_ONLY" == 1 && "$SETUP_STATE" != untouched ]]; then
  warn_local_uninstall || exit 1
fi
if [[ "$YES" == 0 ]]; then
  printf 'Remove molt%s? [y/N] ' "$(if [[ "$LOCAL_ONLY" == 1 || "$SETUP_STATE" == untouched ]]; then printf ' locally'; else printf ' and its owned remote resources'; fi)"
  read -r answer || exit 0
  [[ "$answer" == y || "$answer" == Y ]] || exit 0
fi
export MOLT_HOME
molt_stop_workers || { molt_error 'could not stop owned local processes'; exit 1; }
CURRENT_SETUP_STATE="$("$MOLT_HOME/bin/molt" setup-state)" || exit 1
if [[ "$LOCAL_ONLY" == 1 && "$SETUP_STATE" == untouched && "$CURRENT_SETUP_STATE" != untouched ]]; then
  warn_local_uninstall || exit 1
  if [[ "${MOLT_UI_BATCH:-0}" == 1 ]]; then
    molt_error 'VM setup changed during removal; retry local-only removal to review the warning'
    exit 1
  fi
  if [[ "$YES" == 0 ]]; then
    printf 'VM changes were recorded during removal. Remove locally anyway? [y/N] '
    read -r answer || exit 0
    [[ "$answer" == y || "$answer" == Y ]] || exit 0
  fi
fi
# Keep Mutagen and SSH available through synchronization, VM, and key cleanup.
export MOLT_UNINSTALLING=1
if [[ "$LOCAL_ONLY" != 1 ]]; then
  MOLT_ASSUME_YES=1 "$MOLT_HOME/bin/molt" reset --all || {
    molt_error 'cleanup failed; installation and retry records preserved. Use --local-only to remove locally after accepting VM leftovers.'; exit 1;
  }
  if [[ "$UNDO_VM" == 1 ]]; then
    "$MOLT_HOME/bin/molt" remove-remote-roots --keep-root || { molt_error 'shared cleanup failed; installation and retry records retained'; exit 1; }
    "$MOLT_HOME/bin/molt" unprepare-vm || { molt_error 'VM preparation cleanup failed; installation retained'; exit 1; }
  fi
  "$MOLT_HOME/bin/molt" remove-remote-roots || {
    molt_error 'remote root cleanup failed; retry records preserved'; exit 1;
  }
  "$MOLT_HOME/bin/molt" connection cleanup || {
    molt_error 'dedicated SSH key cleanup failed; installation and credentials retained'; exit 1;
  }
fi
"$MOLT_HOME/bin/molt" shell disable || { molt_error 'shell activation cleanup failed; installation retained'; exit 1; }
"$MOLT_HOME/bin/molt" local-down || { molt_error 'could not stop owned local processes'; exit 1; }
if [[ -f "$MOLT_HOME/legacy-install-manifest" ]]; then
  molt_remove_legacy_shell "$MOLT_HOME/legacy-install-manifest"
  molt_error 'legacy shared dependencies, SSH entries, and shared tool state are preserved'
fi
molt_owned_home || exit 1
rm -rf -- "$MOLT_HOME"
printf 'molt: removed local installation\n'
