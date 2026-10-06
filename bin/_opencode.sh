#!/usr/bin/env bash
# OpenCode authentication, readiness, and the single required SSH tunnel.
ensure_password() {
  managed_file "$MOLT_OPENCODE_PASSWORD_FILE"
  if [[ ! -s "$MOLT_OPENCODE_PASSWORD_FILE" ]]; then
    (umask 077; openssl rand -hex 24 >"$MOLT_OPENCODE_PASSWORD_FILE")
  fi
  chmod 600 "$MOLT_OPENCODE_PASSWORD_FILE"
}
sync_password() {
  ensure_password
  upload_file "$MOLT_OPENCODE_PASSWORD_FILE" "$PROJECT_REMOTE_META/opencode.password"
  remote_run "chmod 600 $(quote_remote "$PROJECT_REMOTE_META/opencode.password")"
}
wait_opencode_ready() {
  local command
  command='for attempt in $(seq 1 60); do curl -fsS --max-time 1 --user "opencode:$(cat /molt-meta/opencode.password)" http://127.0.0.1:4096/global/health >/dev/null 2>&1 && exit 0; sleep 0.5; done; exit 1'
  log 'Waiting for OpenCode…'
  if ! remote_run "docker exec $(quote_remote "$PROJECT_CONTAINER") sh -c $(quote_remote "$command")"; then
    remote_run "docker logs --tail 30 $(quote_remote "$PROJECT_CONTAINER") 2>&1" >&2 || true
    die 'OpenCode did not become ready; retry startup or inspect molt logs'
  fi
}
cancel_project_forwards() {
  local port
  [[ -f "$PROJECT_STATE/forwards" ]] || return 0
  while IFS= read -r port; do
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    ssh -O cancel -L "127.0.0.1:${port}:127.0.0.1:${port}" "$MOLT_HOST" >/dev/null 2>&1 || true
  done <"$PROJECT_STATE/forwards"
  : >"$PROJECT_STATE/forwards"
}
forward_opencode_port() {
  local port="$PROJECT_OPENCODE_PORT" status
  # Reusing an existing listener can attach to the wrong repository. Recreate our tunnel.
  cancel_project_forwards
  ssh -O forward -L "127.0.0.1:${port}:127.0.0.1:${port}" "$MOLT_HOST" >/dev/null 2>&1 || die "could not forward OpenCode on localhost:$port; check for another listener"
  write_value "$PROJECT_STATE/forwards" "$port"
  status="$(curl -q --noproxy '*' --max-time 3 --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$port/global/health" || true)"
  case "$status" in
    200|401) ;;
    *) die 'OpenCode SSH tunnel is unavailable; the VM SSH server must allow local TCP forwarding' ;;
  esac
}
load_password() {
  ensure_password
  OPENCODE_SERVER_PASSWORD="$(tr -d '\n' <"$MOLT_OPENCODE_PASSWORD_FILE")"
  export OPENCODE_SERVER_PASSWORD
}
cmd_client() {
  local tmp client_pid='' rc=0
  molt_state
  tmp="$(mktemp -d "$MOLT_HOME/state/tmp/client.XXXXXX")"
  trap 'if [[ -n "$client_pid" ]]; then molt_kill_tree "$client_pid"; wait "$client_pid" 2>/dev/null || true; fi; rm -rf -- "$tmp"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  printf '%s\n' "$$" >"$tmp/parent.pid"
  printf '%s\n' "$0" >"$tmp/script"
  # An interruptible wait lets uninstall stop the client even during process startup.
  molt_client "$@" <&0 &
  client_pid=$!
  wait "$client_pid" || rc=$?
  rm -rf -- "$tmp"
  trap - EXIT INT TERM
  return "$rc"
}
cmd_oc() {
  local current state
  current="$(canonical_path "$PWD")"
  if [[ -n "${1:-}" && "$1" != -* && -d "$1" ]]; then current="$(canonical_path "$1")"; shift; fi
  state="$(find_project_for_path "$current")" || die 'project is not registered; run molt register or molt start'
  load_project_state "$state"
  attach_loaded_project "$(container_path_for_pwd "$current")" "$@"
}
attach_loaded_project() {
  local directory="$1" rc=0
  shift
  ensure_project_container
  load_password
  cmd_client attach "http://127.0.0.1:$PROJECT_OPENCODE_PORT" --dir "$directory" "$@" || rc=$?
  # Bring the final server edits home even when the client exits with an error.
  flush_project_sync || { log 'could not flush final changes; sync remains running'; [[ "$rc" != 0 ]] || rc=1; }
  return "$rc"
}
