#!/usr/bin/env bash
# OpenCode authentication, readiness, and the single required SSH tunnel.
validate_opencode_config() {
  /usr/bin/osascript -l JavaScript -e '
    ObjC.import("Foundation");
    function run(args) {
      let text = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(args[0], $.NSUTF8StringEncoding, null));
      // Preserve strings while removing JSONC comments and trailing commas.
      text = text.replace(/("(?:[^"\\]|\\.)*")|\/\/[^\r\n]*|\/\*[\s\S]*?\*\//g, (match, string) => string || " ");
      text = text.replace(/("(?:[^"\\]|\\.)*")|,(?=\s*[}\]])/g, (match, string) => string || "");
      const config = JSON.parse(text);
      if (config === null || typeof config !== "object" || Array.isArray(config)) throw new Error("Expected a JSON object");
    }
  ' "$1" >/dev/null 2>&1
}
sync_opencode_config() {
  startup_progress 'Synchronizing OpenCode settings'
  OPENCODE_CONFIG_VERSION="$(upload_opencode_config)" || die 'could not synchronize local OpenCode configuration; working VM settings retained'
}
upload_opencode_config() (
  local source="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-${MOLT_USER_HOME:-$HOME}/.config}/opencode}" work file stage hash
  umask 077
  if [[ ! -d "$source" ]]; then
    remote_script config-sync-version "$PROJECT_REMOTE_HOME" "$MOLT_INSTALL_ID"
    return
  fi
  work="$(mktemp -d "$MOLT_HOME/state/tmp/config.XXXXXX")" || exit 1
  trap "rm -rf -- $(printf '%q' "$work")" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  COPYFILE_DISABLE=1 tar --format=gnutar -chf - \
    --exclude=node_modules --exclude=.git --exclude=.gitignore --exclude=.DS_Store \
    --exclude=package-lock.json --exclude=bun.lock --exclude=bun.lockb -C "$source" . | gzip -n >"$work/config.tar.gz" || exit 1
  mkdir "$work/files" || exit 1
  tar -xzf "$work/config.tar.gz" -C "$work/files" || exit 1
  for file in config.json opencode.json opencode.jsonc; do
    [[ ! -f "$work/files/$file" ]] || validate_opencode_config "$work/files/$file" || die "local $file must be a valid JSONC object"
  done
  hash="$(shasum -a 256 "$work/config.tar.gz" | cut -d ' ' -f1)" || exit 1
  stage="$(remote_script config-sync-stage "$PROJECT_REMOTE_HOME" "$MOLT_INSTALL_ID")" || exit 1
  upload_file "$work/config.tar.gz" "$stage/config.tar.gz" || exit 1
  remote_script config-sync-install "$PROJECT_REMOTE_HOME" "$MOLT_INSTALL_ID" "$stage" "$hash"
)

ensure_password() {
  managed_file "$MOLT_OPENCODE_PASSWORD_FILE"
  if [[ ! -s "$MOLT_OPENCODE_PASSWORD_FILE" ]]; then
    (umask 077; openssl rand -hex 24 >"$MOLT_OPENCODE_PASSWORD_FILE")
  fi
  chmod 600 "$MOLT_OPENCODE_PASSWORD_FILE"
}
sync_password() {
  startup_progress 'Securing workspace connection'
  ensure_password
  upload_file "$MOLT_OPENCODE_PASSWORD_FILE" "$PROJECT_REMOTE_META/opencode.password"
  remote_run "chmod 600 $(quote_remote "$PROJECT_REMOTE_META/opencode.password")"
}
wait_opencode_ready() {
  local command
  command='for attempt in $(seq 1 60); do curl -fsS --max-time 1 --user "opencode:$(cat /molt-meta/opencode.password)" http://127.0.0.1:4096/global/health >/dev/null 2>&1 && exit 0; sleep 0.5; done; exit 1'
  startup_progress 'Waiting for OpenCode server health'
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
  startup_progress 'Opening and checking SSH tunnel'
  # The SSH master reuses an identical forward and rejects another owner's listener.
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
  local tmp binary client_pid='' rc=0
  molt_state
  tmp="$(mktemp -d "$MOLT_HOME/state/tmp/client.XXXXXX")"
  trap 'if [[ -n "$client_pid" ]]; then molt_kill_tree "$client_pid"; wait "$client_pid" 2>/dev/null || true; fi; rm -rf -- "$tmp"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  printf '%s\n' "$$" >"$tmp/parent.pid"
  printf '%s\n' "$0" >"$tmp/script"
  if [[ -n "${PROJECT_ID:-}" ]]; then write_value "$tmp/project" "$PROJECT_ID"; fi
  # An interruptible wait lets uninstall stop the client even during process startup.
  if [[ -n "${MOLT_CLIENT_UPSTREAM:-}" ]]; then
    managed_file "$PROJECT_STATE/sessions"
    binary="$(molt_value "$MOLT_HOME/.install-manifest" OPENCODE_BINARY)" || return 1
    "$SCRIPT_DIR/molt-tui" attach-client --upstream "$MOLT_CLIENT_UPSTREAM" --directory "$MOLT_CLIENT_DIRECTORY" \
      --sessions "$PROJECT_STATE/sessions" -- "$binary" "$@" <&0 &
  else
    molt_client "$@" <&0 &
  fi
  client_pid=$!
  wait "$client_pid" || rc=$?
  rm -rf -- "$tmp"
  trap - EXIT INT TERM HUP
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
  startup_progress 'Opening OpenCode session'
  MOLT_CLIENT_UPSTREAM="http://127.0.0.1:$PROJECT_OPENCODE_PORT" MOLT_CLIENT_DIRECTORY="$directory" \
    cmd_client attach "http://127.0.0.1:$PROJECT_OPENCODE_PORT" --dir "$directory" "$@" || rc=$?
  # Flush current edits; synchronization continues after the client disconnects.
  flush_project_sync || { log 'could not flush final changes; sync remains running'; [[ "$rc" != 0 ]] || rc=1; }
  return "$rc"
}
