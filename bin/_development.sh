#!/usr/bin/env bash
# Sourceable development hooks. The CLI supplies the loaded PROJECT_* and transport functions.

development_profile_path() { printf '%s/.molt/development.json\n' "$PROJECT_PATH"; }
development_remote_meta() { printf '%s/meta/%s/development\n' "$PROJECT_REMOTE_HOME" "$PROJECT_ID"; }
development_remote_state() { printf '%s/state/development/%s\n' "$PROJECT_REMOTE_HOME" "$PROJECT_ID"; }
development_remote_cache() { printf '%s/cache/%s/development\n' "$PROJECT_REMOTE_HOME" "$PROJECT_ID"; }
development_tools() { "$SCRIPT_DIR/molt-tui" development-tools "$@"; }

# macOS has JXA; Linux harnesses and Node-equipped Macs use the same JSON expression.
development_json() {
  local code="$1"; shift
  if command -v node >/dev/null 2>&1; then
    node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{const v=JSON.parse(s||"null");const r=Function("value","args",process.argv[1])(v,process.argv.slice(2));if(r!==undefined)process.stdout.write(typeof r==="string"?r:JSON.stringify(r));}catch(e){console.error("development: invalid JSON operation");process.exitCode=2;}});' "$code" "$@"
  else
    /usr/bin/osascript -l JavaScript -e 'ObjC.import("Foundation");function run(args){const data=$.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;const s=ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data,$.NSUTF8StringEncoding));const value=JSON.parse(s||"null");const r=Function("value","args",args[0])(value,args.slice(1));return r===undefined?"":typeof r==="string"?r:JSON.stringify(r);}' "$code" "$@"
  fi
}
development_safe_local() {
  [[ "$PROJECT_ID" =~ ^[a-f0-9]{12}$ && "$MOLT_INSTALL_ID" =~ ^[a-f0-9]{32}$ && "$PROJECT_STATE" == "$MOLT_HOME/projects/$PROJECT_ID" && "$(molt_canonical "$PROJECT_STATE/development.json")" == "$PROJECT_STATE/development.json" && ! -L "$PROJECT_STATE/development.json" ]] || { molt_error 'unsafe development state'; return 1; }
}
development_local_read() {
  development_safe_local || return 1
  if [[ -f "$PROJECT_STATE/development.json" ]]; then
    development_json 'if(value.version!==1||value.owner!==args[0]||value.project_id!==args[1])throw Error();return value' "$MOLT_INSTALL_ID" "$PROJECT_ID" <"$PROJECT_STATE/development.json"
  else printf '{}'; fi
}
development_local_write() {
  local temporary
  development_safe_local || return 1
  temporary="$(mktemp "$PROJECT_STATE/.development.XXXXXX")" || return 1
  if development_json 'value.version=1;value.owner=args[0];value.project_id=args[1];return value' "$MOLT_INSTALL_ID" "$PROJECT_ID" >"$temporary"; then
    chmod 600 "$temporary" && mv -f -- "$temporary" "$PROJECT_STATE/development.json"
  else rm -f -- "$temporary"; return 1; fi
}
development_validate_profile() { development_tools validate "$1"; }
development_rpc() {
  [[ "$PROJECT_REMOTE_HOME" == /* && "$PROJECT_ID" =~ ^[a-f0-9]{12}$ ]] || return 1
  local node="$PROJECT_REMOTE_HOME/state/development/node/bin/node" runner="$PROJECT_REMOTE_HOME/state/development/development.mjs"
  remote_run "test ! -L $(quote_remote "$node") && test -x $(quote_remote "$node") && test ! -L $(quote_remote "$runner") && exec $(quote_remote "$node" "$runner" --control "$1" --root "$PROJECT_REMOTE_HOME" --owner "$MOLT_INSTALL_ID" --project "$PROJECT_ID" "${@:2}")"
}
development_install_runtime() {
  local stage file
  stage="$(remote_script development-stage "$PROJECT_REMOTE_HOME" "$MOLT_INSTALL_ID" "$PROJECT_ID")" || return 1
  for file in development.mjs android.sh; do upload_file "$SCRIPT_DIR/../remote/$file" "$stage/$file" || return 1; done
  upload_file "$SCRIPT_DIR/../development-tools.lock.json" "$stage/development-tools.lock.json" || return 1
  for file in molt.nix menu.mjs GUIDELINE.md generation.md BUILD.md; do upload_file "$SCRIPT_DIR/../templates/development/$file" "$stage/$file" || return 1; done
  remote_script development-install "$PROJECT_REMOTE_HOME" "$MOLT_INSTALL_ID" "$PROJECT_ID" "$stage"
}
development_validate_candidate() (
  local work profile cwd resolved
  work="$(mktemp -d "$MOLT_HOME/state/tmp/development-validation.XXXXXX")" || return 1
  trap "rm -rf -- $(printf '%q' "$work")" EXIT
  mkdir -p "$work/repo/.molt"
  development_json 'return value.profile' >"$work/repo/.molt/development.json" || return 2
  while IFS= read -r cwd; do
    [[ -n "$cwd" && "$cwd" != /* && "$cwd" != .. && "$cwd" != ../* && "$cwd" != *'/../'* ]] || return 2
    resolved="$(molt_canonical "$PROJECT_PATH/$cwd")" || return 2
    [[ -d "$resolved" && ( "$resolved" == "$PROJECT_PATH" || "$resolved" == "$PROJECT_PATH/"* ) ]] || return 2
    mkdir -p -- "$work/repo/$cwd" || return 1
  done < <(development_json 'return value.actions.map(a=>a.cwd||".").join("\n")+(value.actions.length?"\n":"")' <"$work/repo/.molt/development.json")
  development_validate_profile "$work/repo/.molt/development.json"
)
development_safe_restart() {
  local probe
  project_has_opencode_clients && { molt_error 'workspace clients are active; retry preparation after closing them'; return 1; }
  load_password || return 1
  probe="$(opencode_tools server "http://127.0.0.1:$PROJECT_OPENCODE_PORT")" || { molt_error 'OpenCode activity is unknown; working runtime retained'; return 1; }
  [[ "${probe#*$'\n'}" == idle ]] || { molt_error 'OpenCode is busy; working runtime retained'; return 1; }
  if [[ -f "$PROJECT_STATE/development.json" ]]; then
    development_rpc activity | development_json 'if(value.busy!==false)throw Error()' >/dev/null || { molt_error 'development work is active or unknown; working runtime retained'; return 1; }
  fi
}
development_prepare_locked() {
  local candidate normalized token result previous rc
  flush_project_sync || return 1
  development_install_runtime || return 1
  startup_progress 'Inspecting development configuration'
  candidate="$(development_rpc candidate)" || return $?
  if [[ "$(printf '%s' "$candidate" | development_json 'return String(value.reused)')" == true ]]; then
    development_local_read | development_json 'value.active=JSON.parse(args[0]);return value' "$candidate" | development_local_write
    return
  fi
  normalized="$(printf '%s' "$candidate" | development_validate_candidate)" || return $?
  token="$(printf '%s' "$candidate" | development_json 'return value.token')"
  startup_progress 'Building locked development environment'
  result="$(printf '%s' "$normalized" | development_rpc build "$token")" || return $?
  development_safe_restart || return 1
  flush_project_sync || return 1
  previous="$(development_local_read)" || return 1
  result="$(development_rpc promote "$token")" || return $?
  printf '%s' "$previous" | development_json 'value.active=JSON.parse(args[0]);return value' "$result" | development_local_write || return 1
  if (ensure_container && wait_opencode_ready && forward_opencode_port); then
    flush_project_sync || return 1
    startup_progress 'Development environment is ready'
    return 0
  else rc=$?; fi
  startup_progress 'Restoring the previous working runtime'
  development_rpc rollback >/dev/null || return 1
  printf '%s' "$previous" | development_local_write || return 1
  (ensure_container && wait_opencode_ready && forward_opencode_port) || { molt_error 'runtime rollback needs attention; ownership records retained'; return 1; }
  return "$rc"
}
development_prepare() {
  local rc record inventory
  development_safe_local || return 1
  [[ ! -f "$(development_profile_path)" ]] || development_validate_profile "$(development_profile_path)" >/dev/null || return 2
  ensure_project_container || return 1
  development_local_read | development_json 'value.preparation={state:"preparing"};return value' | development_local_write || return 1
  if with_project_setup_lock development_prepare_locked; then rc=0; else rc=$?; fi
  record="$(development_local_read)" || return 1
  inventory="$(development_rpc inventory 2>/dev/null)" || inventory='[]'
  printf '%s' "$record" | development_json 'value.resources=JSON.parse(args[0]);value.preparation={state:args[1]==="0"?"ready":"failed"};return value' "$inventory" "$rc" | development_local_write || return 1
  return "$rc"
}

# Called by ensure_container. Publication uses the active revision, not mutable source.
development_container_configuration() {
  local record rows port revision image
  DEVELOPMENT_RUNTIME_IMAGE="$PROJECT_IMAGE" DEVELOPMENT_DOCKER_ARGS=()
  [[ -f "$PROJECT_STATE/development.json" ]] || return 0
  record="$(development_local_read)" || return 1
  [[ "$(printf '%s' "$record" | development_json 'return String(!!value.active)')" == true ]] || return 0
  record="$(development_rpc runtime)" || return 1
  image="$(printf '%s' "$record" | development_json 'return value.image||""')"
  [[ "$image" =~ ^molt-development-[a-f0-9]{8}-[a-f0-9]{12}:[a-f0-9]{64}$ ]] || return 1
  DEVELOPMENT_RUNTIME_IMAGE="$image"
  while IFS= read -r port; do
    valid_port "$port" && [[ "$port" != 4096 ]] || return 2
    DEVELOPMENT_DOCKER_ARGS+=(--publish "127.0.0.1::$port")
  done < <(printf '%s' "$record" | development_json 'return value.profile.ports.map(p=>String(p.container_port)).join("\n")+(value.profile.ports.length?"\n":"")')
}
development_exec() {
  local operation="$1"; shift
  local -a terminal=() flags=(-i)
  if [[ -t 0 && -t 1 && ( "$operation" == run || "$operation" == shell ) ]]; then terminal=(-t); flags=(-it); fi
  if [[ "$operation" == shell ]]; then
    ssh ${terminal[@]+"${terminal[@]}"} "$MOLT_HOST" "docker exec ${flags[*]} $(quote_remote "$PROJECT_CONTAINER" /opt/molt/workspace-entrypoint /bin/bash)"
  else
    ssh ${terminal[@]+"${terminal[@]}"} "$MOLT_HOST" "docker exec ${flags[*]} $(quote_remote "$PROJECT_CONTAINER" /opt/molt/workspace-entrypoint /opt/node/bin/node /opt/molt/development.mjs --root /workspace --state /molt-cache/development --profile /molt-meta/development/profile.json "$operation" "$@")"
  fi
}
development_restore_forwards() {
  local status runtime id vm preferred scheme local_port selected="${1:-}" restore="${2:-}" recorded=''
  status="$(development_rpc status)" || return 1
  runtime="$(development_rpc runtime)" || return 1
  if [[ -n "$restore" ]]; then recorded="$(molt_forward_rows "$PROJECT_STATE/forwards")" || return 1; fi
  if [[ -n "$selected" ]]; then printf '%s' "$runtime" | development_json 'if(!value.profile.ports.some(p=>p.id===args[0]))throw Error()' "$selected" >/dev/null || return 2; fi
  while IFS=$'\t' read -r id vm preferred scheme; do
    [[ -n "$id" ]] || continue
    valid_port "$vm" || { molt_error 'application publication unavailable; start its service first'; return 1; }
    if ! remote_run "curl -q --noproxy '*' --insecure --silent --max-time 3 --output /dev/null $(quote_remote "$scheme://127.0.0.1:$vm/")"; then
      molt_error "Application $id is not reachable through Docker. Bind its service to 0.0.0.0 rather than container localhost, then retry."
      return 1
    fi
    local_port="$(molt_forward_allocate "app:$id" "$preferred" "$vm")" || return 1
    log "$id: $scheme://127.0.0.1:$local_port/"
  done < <(printf '%s' "$status" | development_json 'const profile=JSON.parse(args[0]).profile;const ports=value.ports.filter(p=>(!args[1]||p.id===args[1])&&(args[1]||value.services.some(s=>s.id===p.service&&s.state==="running"))&&(!args[3]||args[2].split("\n").some(row=>row.startsWith("app:"+p.id+"\t"+args[4]+"\t"))));return ports.map(p=>[p.id,p.vm_port,profile.ports.find(pref=>pref.id===p.id).local_port,p.scheme].join("\t")).join("\n")+(ports.length?"\n":"")' "$runtime" "$selected" "$recorded" "$restore" "$MOLT_HOST")
}
development_workspace_ready() {
  local record
  [[ -f "$PROJECT_STATE/development.json" ]] || return 0
  record="$(development_local_read)" || return 1
  [[ "$(printf '%s' "$record" | development_json 'return String(value.desired===true)')" == true ]] || return 0
  development_exec restore >/dev/null || return 1
  development_restore_forwards '' restore
}
development_start() {
  development_prepare || return $?
  development_local_read | development_json 'value.desired=true;return value' | development_local_write || return 1
  development_exec start || return $?
  development_restore_forwards
}
development_stop_project() {
  local failed=0 runtime
  android_stop_viewer || failed=1
  [[ ! -f "$PROJECT_STATE/development.json" && ! -f "$(development_profile_path)" ]] || android_stop || failed=1
  if [[ -f "$PROJECT_STATE/development.json" ]]; then
    runtime="$(development_rpc status 2>/dev/null)" || { molt_error 'VM observation unavailable; stop records retained'; return 1; }
    if [[ "$(printf '%s' "$runtime" | development_json 'return value.environment.state')" == ready ]]; then development_exec stop >/dev/null || failed=1; fi
    if [[ "$failed" == 0 ]]; then development_local_read | development_json 'value.desired=false;return value' | development_local_write || failed=1; fi
  fi
  molt_forward_cancel app: || failed=1
  molt_forward_cancel adb || failed=1
  return "$failed"
}
development_cleanup_project() {
  [[ -f "$PROJECT_STATE/development.json" ]] || return 0
  development_stop_project || return 1
  stop_project_writer || return 1
  if [[ "${PROJECT_SYNC_CREATED:-0}" == 1 ]]; then mutagen sync resume "$PROJECT_SYNC" && flush_project_sync || return 1; fi
  android_cleanup_project || return 1
  development_rpc cleanup || return 1
  # The caller removes registration only after all hooks and source synchronization pass.
}
development_cleanup_shared() {
  local exists
  exists="$(remote_run "if test -d $(quote_remote "$PROJECT_REMOTE_HOME/state/development"); then printf yes; else printf no; fi")" || return 1
  [[ "$exists" == yes ]] || return 0
  development_rpc cleanup-shared
}
development_local_down() (
  local state failed=0
  for state in "$MOLT_HOME/projects"/*/path; do
    [[ -f "$state" ]] || continue
    load_project_state "${state%/*}" || { failed=1; continue; }
    android_stop_viewer || failed=1
    molt_forward_cancel app: || failed=1
    molt_forward_cancel adb || failed=1
  done
  return "$failed"
)
development_inventory() {
  local record
  [[ -f "$PROJECT_STATE/development.json" ]] || return 0
  record="$(development_local_read)" || return 1
  [[ -z "${PROJECT_REMOTE_HOME:-}" ]] || printf '  development metadata: %s\n  development state: %s\n  development data: %s\n  Android container/network: %s\n  Android data: %s\n' "$(development_remote_meta)" "$(development_remote_state)" "$(development_remote_cache)" "$(android_container_name)" "$(android_remote_data)"
  [[ -z "${PROJECT_REMOTE_HOME:-}" ]] || printf '  shared private Nix store: %s/cache/development/nix\n  private VM tooling/preparation: %s/state/development and %s/state/android-preparation\n' "$PROJECT_REMOTE_HOME" "$PROJECT_REMOTE_HOME" "$PROJECT_REMOTE_HOME"
  [[ ! -f "$PROJECT_STATE/development.json" ]] || printf '  local development/viewer ownership: %s\n' "$PROJECT_STATE/development.json"
  printf '%s' "$record" | development_json 'return (value.resources||[]).map(p=>"  recorded resource: "+p).join("\n")+((value.resources||[]).length?"\n":"")'
  molt_forward_rows "$PROJECT_STATE/forwards" | while IFS=$'\t' read -r purpose host lp rp state master; do [[ -z "$purpose" || "$purpose" == opencode ]] || printf '  %s tunnel: %s 127.0.0.1:%s -> 127.0.0.1:%s (%s)\n' "$purpose" "$host" "$lp" "$rp" "$state"; done
}
development_status_json() {
  local spec status rows record master viewer_state=closed helper
  if [[ -f "$(development_profile_path)" || -L "$(development_profile_path)" ]]; then spec="$(development_validate_profile "$(development_profile_path)")" || return 2;
  else spec='{"version":1,"name":"Development workspace","actions":[],"ports":[],"android":{"enabled":false}}'; fi
  if status="$(MOLT_SSH_READ_ONLY=1 development_rpc status 2>/dev/null)"; then :;
  else
    status="$(printf '%s' "$spec" | development_json 'return {version:1,project_id:args[0],name:value.name,environment:{state:"unknown",revision:"",reason:"VM observation unavailable"},services:value.actions.filter(a=>a.kind==="service").map(a=>({id:a.id,label:a.label,state:"unknown",reason:"VM observation unavailable"})),ports:value.ports.map(p=>Object.assign({},p,{vm_port:0,local_port:0,url:"",state:"unknown",reason:"VM observation unavailable"})),android:{enabled:value.android.enabled,state:value.android.enabled?"unknown":"disabled",reason:value.android.enabled?"VM observation unavailable":"",container:"",adb_vm_port:0,adb_local_port:0,adb_server_local_port:0,viewer_state:"closed"},cache:{reclaimable_bytes:0,reason:"VM observation unavailable"},cleanup:{state:"clean",remaining:[],reason:""}}' "$PROJECT_ID")" || return 2
  fi
  rows="$(molt_forward_rows "$PROJECT_STATE/forwards")" || return 1
  record="$(development_local_read)" || return 1
  master="$(MOLT_SSH_READ_ONLY=1 molt_forward_master "$MOLT_HOST" 2>/dev/null)" || master=unknown
  helper="$(printf '%s' "$record" | development_json 'return value.viewer||{}')"
  if [[ "$(printf '%s' "$helper" | development_json 'return String(!!value.pid)')" == true ]]; then
    if android_process_matches "$helper"; then viewer_state=running;
    elif kill -0 "$(printf '%s' "$helper" | development_json 'return String(value.pid)')" 2>/dev/null; then viewer_state=unknown; fi
  fi
  printf '%s' "$status" | development_json 'for(const row of args[0].split("\n")){const [purpose,host,lp,rp,state,master]=row.split("\t");const port=value.ports.find(p=>purpose==="app:"+p.id);if(port&&state==="active"&&host===args[2]&&Number(rp)===port.vm_port&&master!=="unknown"&&master===args[3]){port.local_port=Number(lp);port.url=port.scheme+"://127.0.0.1:"+lp+"/";port.state="forwarded";port.reason="";}}const local=JSON.parse(args[1]);value.android.enabled=JSON.parse(args[5]).android.enabled;if(!value.android.enabled)value.android.state="disabled";value.android.viewer_state=args[4];const intent=local.viewer_intent||{};for(const [field,key] of [["adb_local_port","adb_port"],["adb_server_local_port","server_port"]]){const port=intent[key]||0;if(!Number.isInteger(port)||port!==0&&(port<1024||port>65535||key==="server_port"&&port===5037))throw Error();value.android[field]=port;}return value' "$rows" "$record" "$MOLT_HOST" "$master" "$viewer_state" "$spec"
  printf '\n'
}
development_cache_json() {
  local preview
  if preview="$(MOLT_SSH_READ_ONLY=1 development_rpc cache 2>/dev/null)"; then printf '%s\n' "$preview";
  else printf '{} ' | development_json 'return {version:1,project_id:args[0],revision:"",reclaimable_bytes:0,items:[],reason:"VM cache observation unavailable"}' "$PROJECT_ID"; printf '\n'; fi
}
development_open_port() {
  local status url
  development_restore_forwards "$1" || return $?
  status="$(development_status_json)" || return $?
  url="$(printf '%s' "$status" | development_json 'const p=value.ports.find(p=>p.id===args[0]);if(!p||p.state!=="forwarded"||!/^https?:\/\/127\.0\.0\.1:[0-9]+\/$/.test(p.url))throw Error();return p.url' "$1")" || return 2
  open "$url"
}
cmd_dev() {
  [[ $# -ge 2 ]] || { molt_error 'molt dev <repo-path|@id> <action>'; return 2; }
  local target="$1" state; shift
  [[ "$target" != @* || "${target#@}" =~ ^[a-f0-9]{12}$ ]] || return 2
  if [[ "$target" == @* ]]; then load_project "$target" || return 1;
  else state="$(find_project_for_path "$target")" || { molt_error 'project is not registered'; return 1; }; load_project_state "$state" || return 1; fi
  development_dispatch "$@"
}
development_dispatch() {
  local action="${1:-}" rc; shift || true
  case "$action" in
    status|ports|cache) [[ $# == 1 && "$1" == --json ]] || return 2 ;;
    prepare|menu|shell|start|stop) [[ $# == 0 ]] || return 2 ;;
    run|open) [[ $# == 1 && "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || return 2 ;;
    logs) [[ $# == 0 || $# == 1 && "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || return 2 ;;
    clean-cache) [[ $# == 3 && "$1" == --yes && "$2" == --revision && "$3" =~ ^[a-f0-9]{64}$ ]] || return 2 ;;
    android) android_dispatch "$@"; return $? ;;
    *) molt_error 'unknown development action'; return 2 ;;
  esac
  case "$action" in
    status) development_status_json ;;
    ports) development_status_json | development_json 'return value.ports' || return $?; printf '\n' ;;
    cache) development_cache_json ;;
    prepare) development_prepare ;;
    start) development_start ;;
    stop) development_stop_project ;;
    shell) development_prepare && development_exec shell ;;
    run)
      development_prepare || return $?
      if development_rpc runtime | development_json 'if(!value.profile.actions.some(a=>a.id===args[0]&&a.kind==="service"))throw Error()' "$1" >/dev/null 2>&1; then
        development_local_read | development_json 'value.desired=true;return value' | development_local_write || return 1
      fi
      development_exec run "$1" ;;
    logs) development_exec logs "$@" ;;
    menu) cmd_tui --screen "development:$PROJECT_ID" ;;
    open) development_open_port "$1" ;;
    clean-cache) with_project_setup_lock development_rpc clean-cache "$3" ;;
  esac
}
