#!/usr/bin/env bash
# Read-only telemetry over MOLT's authenticated SSH transport. No remote agent.

cmd_monitor() {
  local action="${1:-}" host="${2:-$MOLT_CONFIG_HOST}"
  case "$action" in
    host)
      valid_alias "$host" || die 'invalid SSH host alias'
      MOLT_SSH_CONNECT_TIMEOUT=3 molt_ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$host" \
        "bash -s -- $(quote_remote "$MOLT_INSTALL_ID")" <"$SCRIPT_DIR/../remote/monitor.sh" ;;
    sync)
      # Do not start the Mutagen daemon merely to observe it.
      if [[ -S "$MOLT_HOME/state/home/.mutagen/daemon/daemon.sock" ]]; then
        mutagen sync list --template '{{json .}}'
      else printf '[]\n'; fi ;;
    *) die 'molt monitor [host <alias>|sync]' ;;
  esac
}
