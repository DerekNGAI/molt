#!/usr/bin/env bash
# OpenCode authentication, readiness, and the single required SSH tunnel.
molt_opencode_managed() { [[ "$(molt_value "$MOLT_HOME/.install-manifest" OPENCODE_MANAGED 2>/dev/null || true)" == 1 ]]; }
valid_opencode_version() { [[ "$1" =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]]; }
opencode_tools() {
  local action="$1"; shift
  if [[ "$action" == server ]]; then "$SCRIPT_DIR/molt-tui" opencode-tools server "$@";
  else "$SCRIPT_DIR/molt-tui" opencode-tools "$action" "$MOLT_HOME" "$SCRIPT_DIR/../tools.lock" "$@"; fi
}
newer_opencode_version() {
  local a b c x y z
  IFS=. read -r a b c <<<"$1"
  IFS=. read -r x y z <<<"$2"
  (( 10#$a > 10#$x || 10#$a == 10#$x && 10#$b > 10#$y || 10#$a == 10#$x && 10#$b == 10#$y && 10#$c > 10#$z ))
}
project_has_opencode_clients() {
  local file work pid
  for file in "$MOLT_HOME/state/tmp"/{client,run}.*/project; do
    [[ -f "$file" && "$(read_value "$file")" == "$PROJECT_ID" ]] || continue
    work="${file%/*}"
    [[ "$work" != "${MOLT_CLIENT_WORK:-}" && "$work" != "${MOLT_RUN_WORK:-}" ]] || continue
    pid="$(read_value "$work/parent.pid" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    if kill -0 "$pid" 2>/dev/null; then return 0; fi
  done
  return 1
}
managed_opencode_client() {
  local version="${1:-}" base
  [[ -n "$version" ]] || version="$(opencode_tools latest)" || return 1
  valid_opencode_version "$version" || die 'invalid managed OpenCode version'
  base="$(molt_value "$MOLT_HOME/.install-manifest" OPENCODE_BINARY)" || return 1
  opencode_tools client "$version" "$base"
}
prepare_opencode_version() {
  local latest running owner probe activity=unknown current="${PROJECT_OPENCODE_VERSION:-1.18.34}" binary
  PROJECT_OPENCODE_TARGET='' PROJECT_OPENCODE_DEFERRED=0 PROJECT_OPENCODE_RUNNING=false
  if ! molt_opencode_managed; then
    if valid_opencode_version "${PROJECT_OPENCODE_VERSION:-}"; then PROJECT_OPENCODE_TARGET="$PROJECT_OPENCODE_VERSION"; fi
    return 0
  fi
  startup_progress 'Checking OpenCode versions'
  latest="$(opencode_tools latest)" || return 1
  valid_opencode_version "$latest" || die 'invalid OpenCode release version'
  running="$(remote_run "docker inspect -f '{{.State.Running}}' $(quote_remote "$PROJECT_CONTAINER") 2>/dev/null || true")" || return 1
  if [[ "$running" == true || "$running" == false ]]; then
    owner="$(remote_run "docker inspect -f '{{index .Config.Labels \"io.molt.installation\"}}' $(quote_remote "$PROJECT_CONTAINER")")" || return 1
    [[ "$owner" == "$MOLT_INSTALL_ID" ]] || die 'container ownership mismatch'
  fi
  if [[ "$running" == false ]]; then
    probe="$(remote_run "docker inspect -f '{{index .Config.Labels \"io.molt.opencode\"}}' $(quote_remote "$PROJECT_CONTAINER")")" || return 1
    if valid_opencode_version "$probe"; then current="$probe"; fi
  elif [[ "$running" == true ]]; then
    load_password
    forward_opencode_port
    if probe="$(opencode_tools server "http://127.0.0.1:$PROJECT_OPENCODE_PORT")"; then
      current="${probe%%$'\n'*}" activity="${probe#*$'\n'}"
    fi
    PROJECT_OPENCODE_RUNNING=true
  fi
  [[ -n "$current" ]] || current=1.18.34
  valid_opencode_version "$current" || die 'invalid recorded OpenCode server version'
  PROJECT_OPENCODE_VERSION="$current"
  PROJECT_OPENCODE_TARGET="$latest"
  if newer_opencode_version "$current" "$latest"; then PROJECT_OPENCODE_TARGET="$current"; fi
  managed_file "$PROJECT_STATE/opencode_pending"
  if [[ "$PROJECT_OPENCODE_TARGET" != "$current" ]]; then write_value "$PROJECT_STATE/opencode_pending" "$PROJECT_OPENCODE_TARGET";
  else rm -f "$PROJECT_STATE/opencode_pending"; fi
  if [[ "$running" == true ]] && { [[ "$activity" != idle ]] || project_has_opencode_clients; }; then
    PROJECT_OPENCODE_TARGET="$current" PROJECT_OPENCODE_DEFERRED=1
    log "Keeping OpenCode $current: workspace is active or its activity could not be verified."
  fi
  startup_progress "Preparing OpenCode client · $PROJECT_OPENCODE_TARGET"
  if ! binary="$(managed_opencode_client "$PROJECT_OPENCODE_TARGET")"; then
    if [[ "$running" == true && "$PROJECT_OPENCODE_TARGET" != "$current" ]] && binary="$(managed_opencode_client "$current")"; then
      log "OpenCode client download failed; keeping the working $current client/server pair."
      PROJECT_OPENCODE_TARGET="$current" PROJECT_OPENCODE_DEFERRED=1
    else return 1; fi
  fi
  managed_file "$PROJECT_STATE/opencode_version"
  write_value "$PROJECT_STATE/opencode_version" "$current"
}
recheck_opencode_update() {
  local probe running
  [[ "${PROJECT_OPENCODE_RUNNING:-false}" == true ]] || return 0
  running="$(remote_run "docker inspect -f '{{.State.Running}}' $(quote_remote "$PROJECT_CONTAINER")")" || return 1
  [[ "$running" != false ]] || return 0
  if project_has_opencode_clients || ! probe="$(opencode_tools server "http://127.0.0.1:$PROJECT_OPENCODE_PORT")" || [[ "${probe#*$'\n'}" != idle || "${probe%%$'\n'*}" != "$PROJECT_OPENCODE_VERSION" ]]; then
    PROJECT_OPENCODE_TARGET="$PROJECT_OPENCODE_VERSION" PROJECT_OPENCODE_DEFERRED=1
    log 'OpenCode update deferred: workspace activity changed while the image was building.'
    return 1
  fi
}
reuse_opencode_server() {
  local running suffix=''
  running="$(remote_run "docker inspect -f '{{.State.Running}}' $(quote_remote "$PROJECT_CONTAINER")")" || return 1
  if [[ "$running" == false ]]; then remote_run "docker start $(quote_remote "$PROJECT_CONTAINER") >/dev/null" || return 1; fi
  start_sync
  wait_opencode_ready
  forward_opencode_port
  PROJECT_ACTIVE=1
  if declare -F development_workspace_ready >/dev/null; then development_workspace_ready || return $?; fi
  save_project
  [[ ! -f "$PROJECT_STATE/opencode_pending" ]] || suffix=' (update deferred)'
  startup_progress "$PROJECT_NAME is ready on $MOLT_HOST · OpenCode $PROJECT_OPENCODE_VERSION$suffix"
}
cmd_opencode_update() {
  [[ $# == 0 ]] || die 'molt opencode-update'
  molt_owned_home || die 'install molt before updating OpenCode'
  molt_opencode_managed || die 'this installation uses an explicit OpenCode binary override; reinstall without MOLT_OPENCODE_BINARY to enable managed updates'
  local version binary
  startup_progress 'Checking the latest stable OpenCode release'
  version="$(opencode_tools latest --refresh)" || return 1
  startup_progress "Downloading and verifying OpenCode $version"
  binary="$(managed_opencode_client "$version")" || return 1
  log "OpenCode $version is ready. VM workspaces update automatically on their next launch when no work or terminals are active."
}

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
  local command probe version
  command='for attempt in $(seq 1 60); do curl -fsS --max-time 1 --user "opencode:$(cat /molt-meta/opencode.password)" http://127.0.0.1:4096/global/health >/dev/null 2>&1 && exit 0; sleep 0.5; done; exit 1'
  startup_progress 'Waiting for OpenCode server health'
  if ! remote_run "docker exec $(quote_remote "$PROJECT_CONTAINER") sh -c $(quote_remote "$command")"; then
    remote_run "docker logs --tail 30 $(quote_remote "$PROJECT_CONTAINER") 2>&1" >&2 || true
    die 'OpenCode did not become ready; retry startup or inspect molt logs'
  fi
  if molt_opencode_managed; then
    load_password
    forward_opencode_port
    probe="$(opencode_tools server "http://127.0.0.1:$PROJECT_OPENCODE_PORT")" || return 1
    version="${probe%%$'\n'*}"
    [[ "$version" == "${PROJECT_OPENCODE_TARGET:-$PROJECT_OPENCODE_VERSION}" ]] || die "OpenCode server version $version differs from the selected client version"
    PROJECT_OPENCODE_VERSION="$version"
    managed_file "$PROJECT_STATE/opencode_version"
    write_value "$PROJECT_STATE/opencode_version" "$version"
    if [[ "$(read_value "$PROJECT_STATE/opencode_pending" 2>/dev/null || true)" == "$version" ]]; then rm -f "$PROJECT_STATE/opencode_pending"; fi
  fi
}
molt_forward_master() {
  local output pid started
  output="$(ssh -O check "$1" 2>&1)" || return 1
  [[ "$output" =~ pid=([0-9]+) ]] || { printf 'unknown\n'; return; }
  pid="${BASH_REMATCH[1]}"
  started="$(ps -p "$pid" -o lstart= 2>/dev/null)" || return 1
  printf '%s:%s' "$pid" "$started" | shasum -a 256 | cut -d ' ' -f1
}

with_molt_forward_lock() (
  local lock="$MOLT_HOME/state/ssh/forwards.lock" attempt previous acquired=0
  [[ "$(molt_canonical "$lock")" == "$lock" && ! -L "$lock" ]] || return 1
  for attempt in {1..300}; do
    if mkdir "$lock" 2>/dev/null; then acquired=1; break; fi
    previous="$(read_value "$lock/pid" 2>/dev/null || true)"
    if [[ "$previous" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "$previous" 2>/dev/null; then
      [[ ! -L "$lock/pid" ]] || return 1
      rm -f -- "$lock/pid" && rmdir -- "$lock" || return 1
    else sleep 0.05; fi
  done
  [[ "$acquired" == 1 ]] || { molt_error 'forward allocation is locked'; return 1; }
  trap "rm -f -- $(printf '%q' "$lock/pid"); rmdir -- $(printf '%q' "$lock")" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  printf '%s\n' "${BASHPID:-$$}" >"$lock/pid"
  "$@"
)

molt_forward_rows() {
  local file="$1" purpose host local_port vm_port state master extra
  [[ "$(molt_canonical "$file")" == "$file" && ! -L "$file" ]] || return 1
  [[ -f "$file" ]] || return 0
  while IFS=$'\t' read -r purpose host local_port vm_port state master extra; do
    [[ -n "$purpose" ]] || continue
    if [[ "$purpose" =~ ^[0-9]{1,5}$ && -z "$host" ]]; then
      valid_port "$purpose" || return 1
      printf 'opencode\t%s\t%s\t%s\tactive\tunknown\n' "$MOLT_HOST" "$purpose" "$purpose"
      continue
    fi
    [[ "$purpose" == opencode || "$purpose" == adb || "$purpose" =~ ^app:[a-z][a-z0-9-]{0,31}$ ]] &&
      [[ "$host" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$ && -z "$extra" ]] &&
      valid_port "$local_port" && ((10#$local_port >= 1024)) && valid_port "$vm_port" &&
      [[ "$state" == active || "$state" == pending ]] &&
      [[ "$master" == unknown || "$master" =~ ^[a-f0-9]{64}$ ]] || { molt_error 'invalid forward ownership record'; return 1; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$purpose" "$host" "$local_port" "$vm_port" "$state" "$master"
  done <"$file"
}

molt_forward_save() {
  local temporary
  [[ "$(molt_canonical "$PROJECT_STATE/forwards")" == "$PROJECT_STATE/forwards" && ! -L "$PROJECT_STATE/forwards" ]] || return 1
  temporary="$(mktemp "$PROJECT_STATE/.forwards.XXXXXX")" || return 1
  chmod 600 "$temporary" || return 1
  cat >"$temporary" && mv -f -- "$temporary" "$PROJECT_STATE/forwards"
}

molt_forward_cancel_locked() {
  local prefix="$1" rows purpose host local_port vm_port state master kept='' failed=0 line
  rows="$(molt_forward_rows "$PROJECT_STATE/forwards")" || return 1
  while IFS=$'\t' read -r purpose host local_port vm_port state master; do
    [[ -n "$purpose" ]] || continue
    printf -v line '%s\t%s\t%s\t%s\t%s\t%s' "$purpose" "$host" "$local_port" "$vm_port" "$state" "$master"
    if [[ "$purpose" == "$prefix"* ]]; then
      if ssh -O cancel -L "127.0.0.1:$local_port:127.0.0.1:$vm_port" "$host" >/dev/null 2>&1; then continue; fi
      # A vanished master has no forwards. A live master's failure needs a retry.
      if ! ssh -O check "$host" >/dev/null 2>&1; then continue; fi
      failed=1
    fi
    kept="${kept}${line}"$'\n'
  done <<<"$rows"
  printf '%s' "$kept" | molt_forward_save || return 1
  [[ "$failed" == 0 ]] || { molt_error 'could not cancel owned forward; record retained'; return 1; }
}
molt_forward_cancel() { [[ -e "$PROJECT_STATE/forwards" || -L "$PROJECT_STATE/forwards" ]] || return 0; with_molt_forward_lock molt_forward_cancel_locked "$1"; }
cancel_project_forwards() { molt_forward_cancel ''; }

molt_forward_allocate_locked() {
  local purpose="$1" preferred="$2" vm_port="$3" fixed="${4:-0}" rows kept='' line p h lp rp state master current_master candidate attempt other used message reused=0
  rows="$(molt_forward_rows "$PROJECT_STATE/forwards")" || return 1
  while IFS=$'\t' read -r p h lp rp state master; do
    [[ -n "$p" ]] || continue
    if [[ "$p" == "$purpose" ]]; then
      if [[ "$h" == "$MOLT_HOST" && "$rp" == "$vm_port" ]]; then preferred="$lp"; reused=1;
      else molt_forward_cancel_locked "$purpose" || return 1; fi
    else
      printf -v line '%s\t%s\t%s\t%s\t%s\t%s' "$p" "$h" "$lp" "$rp" "$state" "$master"
      kept="${kept}${line}"$'\n'
    fi
  done <<<"$rows"
  for ((attempt=0; attempt<500; attempt++)); do
    candidate=$((1024 + (10#$preferred - 1024 + attempt) % 64512)); used=0
    for other in "$MOLT_HOME/projects"/*/forwards; do
      [[ -f "$other" && "$other" != "$PROJECT_STATE/forwards" ]] || continue
      while IFS=$'\t' read -r p h lp rp state master; do
        [[ "$lp" != "$candidate" ]] || used=1
      done <<<"$(molt_forward_rows "$other")"
    done
    while IFS=$'\t' read -r p h lp rp state master; do [[ "$lp" != "$candidate" ]] || used=1; done <<<"$kept"
    if [[ "$used" == 1 ]]; then [[ "$fixed" == 0 ]] || break; continue; fi
    if [[ "$reused" == 0 || "$attempt" != 0 ]] && molt_port_listening "$candidate"; then [[ "$fixed" == 0 ]] || break; continue; fi
    current_master="$(molt_forward_master "$MOLT_HOST")" || { molt_error 'SSH master unavailable'; return 1; }
    printf '%s%s\t%s\t%s\t%s\tpending\t%s\n' "$kept" "$purpose" "$MOLT_HOST" "$candidate" "$vm_port" "$current_master" | molt_forward_save || return 1
    if message="$(ssh -O forward -L "127.0.0.1:$candidate:127.0.0.1:$vm_port" "$MOLT_HOST" 2>&1)"; then
      printf '%s%s\t%s\t%s\t%s\tactive\t%s\n' "$kept" "$purpose" "$MOLT_HOST" "$candidate" "$vm_port" "$current_master" | molt_forward_save || return 1
      printf '%s\n' "$candidate"; return 0
    fi
    case "$message" in
      *'Address already in use'*|*'cannot listen to port'*|*'cannot bind'*) printf '%s' "$kept" | molt_forward_save || return 1 ;;
      *'Port forwarding failed'*)
        if molt_port_listening "$candidate"; then printf '%s' "$kept" | molt_forward_save || return 1;
        else molt_error 'SSH forwarding failed; pending intent retained'; return 1; fi ;;
      *) molt_error 'SSH forwarding failed; pending intent retained'; return 1 ;;
    esac
    [[ "$fixed" == 0 ]] || break
  done
  molt_error 'could not allocate a loopback port after at most 500 attempts'; return 1
}
molt_port_listening() {
  if command -v lsof >/dev/null 2>&1; then lsof -nP -i "TCP:$1" -sTCP:LISTEN >/dev/null 2>&1;
  elif [[ -r /proc/net/tcp ]]; then
    local port; printf -v port '%04X' "$((10#$1))"
    awk -v port="$port" '$4=="0A" && $2~":"port"$" {found=1} END {exit !found}' /proc/net/tcp /proc/net/tcp6
  else return 1; fi
}
molt_forward_allocate() {
  [[ "$1" == opencode || "$1" == adb || "$1" =~ ^app:[a-z][a-z0-9-]{0,31}$ ]] && valid_port "$2" && ((10#$2 >= 1024)) && valid_port "$3" || return 2
  with_molt_forward_lock molt_forward_allocate_locked "$@"
}
forward_opencode_port() {
  local port="$PROJECT_OPENCODE_PORT" status
  startup_progress 'Opening and checking SSH tunnel'
  # The SSH master reuses an identical forward and rejects another owner's listener.
  molt_forward_allocate opencode "$port" "$port" 1 >/dev/null || die "could not forward OpenCode on localhost:$port; check for another listener"
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
  tmp="${MOLT_CLIENT_WORK:-$(mktemp -d "$MOLT_HOME/state/tmp/client.XXXXXX")}"
  case "$tmp" in "$MOLT_HOME/state/tmp/client."*) ;; *) die 'invalid client worker directory' ;; esac
  managed_file "$tmp"
  [[ -d "$tmp" ]] || die 'client worker directory not found'
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
    if molt_opencode_managed; then binary="$(managed_opencode_client "$PROJECT_OPENCODE_VERSION")" || return 1;
    else binary="$(molt_value "$MOLT_HOME/.install-manifest" OPENCODE_BINARY)" || return 1; fi
    export OPENCODE_DISABLE_AUTOUPDATE=1
    "$SCRIPT_DIR/molt-tui" attach-client --upstream "$MOLT_CLIENT_UPSTREAM" --directory "$MOLT_CLIENT_DIRECTORY" \
      --sessions "$PROJECT_STATE/sessions" -- "$binary" "$@" <&0 &
  else
    if molt_opencode_managed; then
      binary="$(managed_opencode_client)" || return 1
      OPENCODE_DISABLE_AUTOUPDATE=1 "$binary" "$@" <&0 &
    else molt_client "$@" <&0 & fi
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
  molt_state
  MOLT_CLIENT_WORK="$(mktemp -d "$MOLT_HOME/state/tmp/client.XXXXXX")"
  trap 'rm -rf -- "$MOLT_CLIENT_WORK"' EXIT
  printf '%s\n' "$$" >"$MOLT_CLIENT_WORK/parent.pid"
  printf '%s\n' "$0" >"$MOLT_CLIENT_WORK/script"
  write_value "$MOLT_CLIENT_WORK/project" "$PROJECT_ID"
  ensure_project_container
  load_password
  startup_progress 'Opening OpenCode session'
  MOLT_CLIENT_UPSTREAM="http://127.0.0.1:$PROJECT_OPENCODE_PORT" MOLT_CLIENT_DIRECTORY="$directory" \
    cmd_client attach "http://127.0.0.1:$PROJECT_OPENCODE_PORT" --dir "$directory" "$@" || rc=$?
  # Flush current edits; synchronization continues after the client disconnects.
  flush_project_sync || { log 'could not flush final changes; sync remains running'; [[ "$rc" != 0 ]] || rc=1; }
  return "$rc"
}
