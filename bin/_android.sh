#!/usr/bin/env bash
# Per-project Android and local private ADB/viewer lifecycle; no work merely when sourced.
android_container_name() { printf 'molt-android-%s-%s\n' "${MOLT_INSTALL_ID:0:8}" "$PROJECT_ID"; }
android_network_name() { android_container_name; }
android_remote_data() { printf '%s/android/data\n' "$(development_remote_cache)"; }
android_remote() {
  [[ "${PROJECT_REMOTE_HOME:-}" == /* ]] || { molt_error 'start the workspace before Android operations'; return 1; }
  ssh "$MOLT_HOST" "bash -s -- $(quote_remote "$1" "$PROJECT_REMOTE_HOME" "$MOLT_INSTALL_ID" "$PROJECT_ID" "${@:2}")" <"$SCRIPT_DIR/../remote/android.sh"
}
android_check_host() { MOLT_SSH_READ_ONLY=1 android_remote check; }
android_enabled() {
  local spec
  spec="$(development_validate_profile "$(development_profile_path)")" || return 2
  [[ "$(printf '%s' "$spec" | development_json 'return String(value.android.enabled)')" == true ]]
}
android_promote_preference() (
  local enabled="$1" profile before work normalized after
  profile="$(development_profile_path)"
  development_safe_local || return 1
  before="$(shasum -a 256 "$profile" | cut -d ' ' -f1)" || return 1
  work="$(mktemp -d "$MOLT_HOME/state/tmp/android-profile.XXXXXX")" || return 1
  trap "rm -rf -- $(printf '%q' "$work")" EXIT
  normalized="$(development_validate_profile "$profile")" || return 2
  printf '%s' "$normalized" | development_json 'value.android.enabled=args[0]==="true";return {profile:value}' "$enabled" >"$work/candidate" || return 2
  normalized="$(development_validate_candidate <"$work/candidate")" || return 2
  [[ "$(shasum -a 256 "$profile" | cut -d ' ' -f1)" == "$before" && "$(molt_canonical "$profile")" == "$profile" && ! -L "$profile" ]] || { molt_error 'development profile changed; inspect it before retrying'; return 1; }
  # Atomic promotion is scoped to the checked profile and preserves the user's devenv files.
  printf '%s\n' "$normalized" >"$work/profile"
  chmod 600 "$work/profile"
  mv -f -- "$work/profile" "$profile" || return 1
  flush_project_sync
)
android_enable() { molt_state || return 1; with_project_setup_lock android_promote_preference true; }
android_disable() { android_stop_viewer && android_stop || return 1; molt_state || return 1; with_project_setup_lock android_promote_preference false; }
android_prepare_host() {
  [[ -t 0 && -t 1 ]] || { molt_error 'Android prepare-host requires an interactive administrator terminal'; return 1; }
  # The existing VM setup pattern uses a PTY for sudo, not a noninteractive permission bypass.
  local stage
  stage="$(remote_script development-stage "$PROJECT_REMOTE_HOME" "$MOLT_INSTALL_ID" "$PROJECT_ID")" || return 1
  upload_file "$SCRIPT_DIR/../remote/android.sh" "$stage/android.sh" || return 1
  ssh -t "$MOLT_HOST" "bash $(quote_remote "$stage/android.sh" prepare-host "$PROJECT_REMOTE_HOME" "$MOLT_INSTALL_ID" "$PROJECT_ID")"
}
android_start() {
  android_enabled || { molt_error 'enable Android explicitly in this repository first'; return 1; }
  development_prepare || return $?
  local artifact pin
  artifact="$(development_tools artifact "$SCRIPT_DIR/../development-tools.lock.json" android linux arm64)" || return 1
  pin="$(printf '%s' "$artifact" | development_json 'return value.image+"@"+value.digest')" || return 2
  android_remote start "$pin"
}
android_stop() {
  android_stop_viewer || return 1
  [[ -n "${PROJECT_REMOTE_HOME:-}" ]] || return 0
  android_remote stop
}
android_cleanup_project() { android_stop_viewer && android_remote cleanup; }
android_reset() { [[ $# == 1 && "$1" == --yes ]] || return 2; android_stop_viewer && android_remote reset; }
android_logs() { android_remote logs; }

android_process_record() {
  local pid="$1" executable="$2" root="$3" started command digest actual
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" -gt 1 && "$(molt_canonical "$executable")" == "$executable" && ! -L "$executable" && "$executable" == "$root/"* ]] || return 1
  started="$(ps -p "$pid" -o lstart= 2>/dev/null)" || return 1
  command="$(ps -ww -p "$pid" -o command= 2>/dev/null)" || return 1
  if [[ -e "/proc/$pid/exe" ]]; then actual="$(molt_canonical "/proc/$pid/exe")";
  else actual="$(ps -p "$pid" -o comm= 2>/dev/null)"; fi
  [[ "$actual" == "$executable" ]] || return 1
  [[ -n "$started" && "$command" == *"$executable"* ]] || return 1
  digest="$(shasum -a 256 "$executable" | cut -d ' ' -f1)" || return 1
  printf '{}' | development_json 'return {pid:Number(args[0]),executable:args[1],owned_root:args[2],start:args[3],command:args[4],sha256:args[5]}' "$pid" "$executable" "$root" "$started" "$command" "$digest"
}
android_helper_owned() {
  local executable="$1" root="$2" release marker
  [[ "$(molt_canonical "$root")" == "$root" && ! -L "$root" && "$(molt_canonical "$executable")" == "$executable" && ! -L "$executable" && "$executable" == "$root/"* && ( "${executable##*/}" == adb || "${executable##*/}" == scrcpy ) ]] || return 1
  case "$root" in
    "$MOLT_HOME/releases/install."*/tools/development/darwin-*)
      release="${root%/tools/development/*}"; marker="$release/.molt-release"
      [[ "${release%/*}" == "$MOLT_HOME/releases" && ! -L "$marker" && "$(molt_canonical "$marker")" == "$marker" && "$(molt_value "$marker" FORMAT)" == 2 && "$(molt_value "$marker" INSTALL_ID)" == "$MOLT_INSTALL_ID" && "$(molt_value "$marker" ROOT)" == "$MOLT_HOME" && "$(molt_value "$marker" STATUS)" == ready ]] || return 1 ;;
    "$MOLT_HOME/tools/development/darwin-"*) molt_owned_home || return 1 ;;
    *) return 1 ;;
  esac
}
android_process_matches() {
  local record="$1" pid executable root expected current
  pid="$(printf '%s' "$record" | development_json 'return String(value.pid)')" || return 1
  executable="$(printf '%s' "$record" | development_json 'return value.executable')" || return 1
  root="$(printf '%s' "$record" | development_json 'return value.owned_root')" || return 1
  android_helper_owned "$executable" "$root" || return 1
  current="$(android_process_record "$pid" "$executable" "$root")" || return 1
  printf '%s' "$current" | development_json 'const old=JSON.parse(args[0]);if(["pid","executable","owned_root","start","command","sha256"].some(k=>value[k]!==old[k]))throw Error();return "matched"' "$record" >/dev/null
}
android_stop_viewer() {
  local local_record helper process pid attempt failed=0
  [[ -f "$PROJECT_STATE/development.json" ]] || return 0
  local_record="$(development_local_read)" || return 1
  pid="$(printf '%s' "$local_record" | development_json 'return value.viewer_intent&&value.viewer_intent.pending_pid?String(value.viewer_intent.pending_pid):""')"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && [[ "$(printf '%s' "$local_record" | development_json 'return String([value.viewer&&value.viewer.pid,value.adb_server&&value.adb_server.pid].includes(Number(args[0])))' "$pid")" != true ]]; then
    molt_error 'helper creation was interrupted before its identity was recorded; pending PID retained for inspection'
    return 1
  fi
  for helper in viewer adb_server; do
    process="$(printf '%s' "$local_record" | development_json 'return value[args[0]]||{}' "$helper")" || return 1
    pid="$(printf '%s' "$process" | development_json 'return value.pid?String(value.pid):""')"
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      if ! android_process_matches "$process"; then molt_error 'local helper identity mismatch; process and record retained'; failed=1; continue; fi
      kill -TERM "$pid" || { failed=1; continue; }
      for attempt in {1..50}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
      if kill -0 "$pid" 2>/dev/null; then
        android_process_matches "$process" && kill -KILL "$pid" || { failed=1; continue; }
      fi
    fi
    local_record="$(printf '%s' "$local_record" | development_json 'delete value[args[0]];return value' "$helper")"
    printf '%s' "$local_record" | development_local_write || return 1
  done
  [[ "$failed" == 0 ]] || return 1
  molt_forward_cancel adb
}
android_view_locked() {
  local status info adb scrcpy owned_root vm local_port server_port pid process record attempt offset log_file ready
  status="$(development_rpc status)" || return 1
  vm="$(printf '%s' "$status" | development_json 'if(value.android.state!=="ready")throw Error();return String(value.android.adb_vm_port)')" || return 1
  valid_port "$vm" || return 1
  info="$(development_tools viewer "$MOLT_HOME" "$SCRIPT_DIR/../development-tools.lock.json")" || return $?
  adb="$(printf '%s' "$info" | development_json 'return value.adb')"; scrcpy="$(printf '%s' "$info" | development_json 'return value.scrcpy')"; owned_root="$(printf '%s' "$info" | development_json 'return value.owned_root')"
  android_helper_owned "$adb" "$owned_root" && android_helper_owned "$scrcpy" "$owned_root" || return 1
  local_port="$(molt_forward_allocate_locked adb 19000 "$vm")" || return 1
  log_file="$PROJECT_STATE/android-viewer.log"; [[ "$(molt_canonical "$log_file")" == "$log_file" && ! -L "$log_file" ]] || return 1
  record="$(development_local_read)" || return 1
  for ((offset=0; offset<500; offset++)); do
    server_port=$((22000 + (16#${PROJECT_ID:0:4} + offset) % 10000))
    # A foreground private server gives us its actual PID; never address the user's 5037 server.
    record="$(printf '%s' "$record" | development_json 'value.viewer_intent={adb_port:Number(args[0]),server_port:Number(args[1]),owned_root:args[2]};return value' "$local_port" "$server_port" "$owned_root")"
    printf '%s' "$record" | development_local_write || return 1
    env ADB_SERVER_SOCKET="tcp:127.0.0.1:$server_port" ANDROID_ADB_SERVER_PORT="$server_port" nohup "$adb" -L "tcp:127.0.0.1:$server_port" nodaemon server >"$log_file" 2>&1 & pid=$!
    record="$(printf '%s' "$record" | development_json 'value.viewer_intent.pending_pid=Number(args[0]);return value' "$pid")"
    printf '%s' "$record" | development_local_write || return 1
    if process="$(android_process_record "$pid" "$adb" "$owned_root")"; then
      record="$(printf '%s' "$record" | development_json 'value.adb_server=JSON.parse(args[0]);return value' "$process")"
      printf '%s' "$record" | development_local_write || return 1
    fi
    ready=0
    for attempt in {1..50}; do
      kill -0 "$pid" 2>/dev/null || break
      if lsof -a -p "$pid" -i "TCP:$server_port" -sTCP:LISTEN >/dev/null 2>&1; then ready=1; break; fi
      sleep 0.05
    done
    if [[ "$ready" == 1 ]]; then break; fi
    if kill -0 "$pid" 2>/dev/null; then
      process="$(android_process_record "$pid" "$adb" "$owned_root")" || return 1
      android_process_matches "$process" && kill -TERM "$pid" || return 1
      molt_error 'private ADB server did not listen'; return 1
    fi
    wait "$pid" 2>/dev/null || true
    grep -Eq 'Address already in use|cannot bind' "$log_file" || { molt_error 'private ADB startup failed'; return 1; }
  done
  [[ "$ready" == 1 ]] || return 1
  process="$(android_process_record "$pid" "$adb" "$owned_root")" || return 1
  record="$(printf '%s' "$record" | development_json 'value.adb_server=JSON.parse(args[0]);return value' "$process")"
  printf '%s' "$record" | development_local_write || return 1
  env ADB_SERVER_SOCKET="tcp:127.0.0.1:$server_port" "$adb" -H 127.0.0.1 -P "$server_port" connect "127.0.0.1:$local_port" >>"$log_file" 2>&1 || return 1
  [[ "$(env ADB_SERVER_SOCKET="tcp:127.0.0.1:$server_port" "$adb" -H 127.0.0.1 -P "$server_port" -s "127.0.0.1:$local_port" shell getprop sys.boot_completed | tr -d '\r\n')" == 1 ]] || return 1
  # Video/control are local ADB forwards over the tunneled device transport; no remote ADB server.
  env ADB="$adb" ADB_SERVER_SOCKET="tcp:127.0.0.1:$server_port" ANDROID_ADB_SERVER_PORT="$server_port" nohup "$scrcpy" --force-adb-forward --serial="127.0.0.1:$local_port" >>"$log_file" 2>&1 & pid=$!
  record="$(printf '%s' "$record" | development_json 'value.viewer_intent.pending_pid=Number(args[0]);return value' "$pid")"
  printf '%s' "$record" | development_local_write || return 1
  sleep 0.2
  process="$(android_process_record "$pid" "$scrcpy" "$owned_root")" || { molt_error 'Android viewer exited; inspect its log'; return 1; }
  printf '%s' "$record" | development_json 'value.viewer=JSON.parse(args[0]);return value' "$process" | development_local_write
}
android_view() {
  android_stop_viewer || return 1
  android_start || return $?
  if with_molt_forward_lock android_view_locked; then return 0;
  else local rc=$?; android_stop_viewer || true; return "$rc"; fi
}
android_dispatch() {
  local action="${1:-}"; shift || true
  case "$action" in
    check|enable|disable|prepare-host|start|stop|view|logs) [[ $# == 0 ]] || return 2 ;;
    reset) [[ $# == 1 && "$1" == --yes ]] || return 2 ;;
    *) return 2 ;;
  esac
  case "$action" in
    check) android_check_host ;; enable) android_enable ;; disable) android_disable ;; prepare-host) android_prepare_host ;; start) android_start ;; stop) android_stop ;; view) android_view ;; logs) android_logs ;; reset) android_reset "$@" ;;
  esac
}
