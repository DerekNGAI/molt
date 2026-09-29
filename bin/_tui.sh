#!/usr/bin/env bash
# The console stays local. Each lifecycle action runs in its own CLI process.

tui_begin() {
  [[ -t 0 && -t 1 && "${TERM:-dumb}" != dumb ]] || { molt_error 'the control center needs an interactive terminal'; return 1; }
  TUI_STTY="$(stty -g)"
  tput smcup >&2 2>/dev/null || true
}

tui_end() {
  [[ -z "${TUI_STTY:-}" ]] || stty "$TUI_STTY" 2>/dev/null || true
  tput rmcup >&2 2>/dev/null || true
  tput cnorm >&2 2>/dev/null || true
}

tui_screen() {
  tput clear >&2 2>/dev/null || true
  "$GUM" style --bold --foreground 6 -- "MOLT  /  $1" >&2
  printf '\n' >&2
}

tui_choose() {
  local title="$1" description="$2" height
  shift 2
  tui_screen "$title"
  [[ -z "$description" ]] || printf '%s\n\n' "$description" >&2
  height="$(tput lines 2>/dev/null || printf 24)"
  height=$((height - 10)); [[ "$height" -gt 3 ]] || height=3
  "$GUM" choose --height "$height" --cursor.foreground 6 --selected.foreground 6 --label-delimiter '|' -- "$@"
}

tui_input() {
  tui_screen "$1"
  "$GUM" input --header 'Enter to save / Esc to go back' --char-limit 0 --value "${2:-}"
}

tui_confirm() { "$GUM" confirm --default=false --show-help --selected.background 6 --selected.foreground 0 -- "$1"; }

tui_message() {
  tui_choose "$1" "$2" 'Back|back' >/dev/null || true
}

tui_path() {
  case "$1" in
    '~/'*) printf '%s/%s\n' "${MOLT_USER_HOME:-$HOME}" "${1#\~/}" ;;
    '$HOME/'*) printf '%s/%s\n' "${MOLT_USER_HOME:-$HOME}" "${1#\$HOME/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

tui_reload() {
  source "$MOLT_HOME/config"
  MOLT_CONFIG_HOST="$MOLT_HOST"
  export MOLT_SSH_CONFIG
}

tui_stop_action() {
  local pid process
  if [[ -d "${TUI_ACTION_WORK:-}" ]]; then
    managed_file "$TUI_ACTION_WORK/cancel"
    : >"$TUI_ACTION_WORK/cancel"
  fi
  [[ -f "${TUI_ACTION_WORK:-}/pid" ]] || return 0
  IFS= read -r pid <"$TUI_ACTION_WORK/pid" || true
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" -gt 1 ]] || return 1
  process="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$process" in *"$TUI_BIN ui-action $TUI_ACTION_WORK"*) molt_kill_tree "$pid" ;; esac
}

tui_run() {
  local title="$1" rc choice result cancelled=0
  shift
  TUI_ACTION_WORK="$(mktemp -d "$MOLT_HOME/state/tmp/action.XXXXXX")"
  while :; do
    rm -f "$TUI_ACTION_WORK/cancel"
    tui_screen "$title"
    trap 'cancelled=1; tui_stop_action' INT
    trap 'tui_stop_action; exit 143' TERM
    if "$GUM" spin --show-output --show-error --title "$title (Ctrl-C to cancel)" -- "$TUI_BIN" ui-action "$TUI_ACTION_WORK" "$@"; then rc=0; else rc=$?; fi
    tui_stop_action || true
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [[ "$cancelled" == 0 ]] || rc=130
    if [[ -f "$TUI_ACTION_WORK/output" ]]; then
      managed_file "$MOLT_HOME/state/ui/last.log"
      cp "$TUI_ACTION_WORK/output" "$MOLT_HOME/state/ui/last.log"
    fi
    if [[ "$rc" == 0 ]]; then result=Completed; else result="Action failed (exit $rc)"; fi
    if [[ -f "$TUI_ACTION_WORK/output" ]]; then
      result="$result"$'\n\n'"$(awk 'NR <= 6 {print} END {if (NR > 6) print "… View output for the full log."}' "$TUI_ACTION_WORK/output")"
    fi
    while :; do
      choice="$(tui_choose "$title" "$result" 'Back|back' 'View output|output' 'Retry|retry')" || choice=back
      case "$choice" in
        output) if [[ -f "$TUI_ACTION_WORK/output" ]]; then "$GUM" pager <"$TUI_ACTION_WORK/output" || true; fi ;;
        retry) cancelled=0; break ;;
        *) rm -rf -- "$TUI_ACTION_WORK"; TUI_ACTION_WORK=''; return "$rc" ;;
      esac
    done
  done
}

tui_terminal() {
  local title="$1" rc answer
  shift
  tui_end
  printf '\nMOLT / %s\n\n' "$title"
  trap ':' INT
  if "$@"; then rc=0; printf '\nCompleted: %s\n' "$title";
  else rc=$?; printf '\n%s failed (exit %s). Saved records are available for retry.\n' "$title" "$rc"; fi
  trap 'exit 130' INT
  # After removal, the loaded shell functions can restore the terminal without Gum.
  if [[ "$title" == 'Uninstall MOLT' && ! -d "$MOLT_HOME" ]]; then return "$rc"; fi
  printf '\nPress Enter to return to MOLT: '
  read -r answer || true
  tput smcup >&2 2>/dev/null || true
  return "$rc"
}

tui_connect() {
  local host="${1:-$MOLT_HOST}"
  "$TUI_BIN" connection check "$host" >/dev/null 2>&1 && return 0
  tui_terminal "Connect to $host" "$TUI_BIN" connection login "$host"
}

tui_install() (
  local src="$1" bootstrap folder candidate
  [[ -t 0 && -t 1 ]] || { molt_error 'use --non-interactive outside an interactive terminal'; exit 1; }
  bootstrap="$(mktemp -d "${TMPDIR:-/tmp}/molt-bootstrap.XXXXXX")"
  trap 'tui_end; rm -rf -- "$bootstrap"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  candidate="$(molt_dependency gum "${MOLT_GUM_BINARY:-}" 2>/dev/null || true)"
  if [[ -n "$candidate" ]] && molt_gum_version "$candidate"; then GUM="$candidate";
  else
    printf 'MOLT: downloading the verified terminal interface...\n'
    GUM="$(molt_download_tool gum "$bootstrap" "$src/tools.lock")" || exit 1
  fi
  tui_begin || exit 1
  folder="$(tui_input 'Install folder' "$MOLT_HOME")" || exit 0
  MOLT_HOME="$(tui_path "$folder")"
  molt_safe_home || { tui_message 'Install folder' 'Choose a dedicated folder with an existing parent.'; exit 1; }
  tui_screen 'Install MOLT'
  tui_confirm "Install or upgrade MOLT in $MOLT_HOME?" || exit 0
  tui_terminal 'Install MOLT' env MOLT_HOME="$MOLT_HOME" MOLT_BOOTSTRAP_GUM_BINARY="$GUM" /bin/bash "$src/install.sh" --non-interactive || exit 1
  tui_end
  MOLT_GUM_BINARY='' MOLT_BOOTSTRAP_GUM_BINARY='' "$MOLT_HOME/bin/molt" tui
)

tui_connection_form() {
  local source_alias="${1:-}" alias hostname='' user=ubuntu port=22 identity auth initial='' profile=''
  if [[ -n "$source_alias" ]]; then
    profile="$MOLT_HOME/state/ssh/profiles/$source_alias"
    hostname="$(read_value "$profile/hostname")"; user="$(read_value "$profile/user")"; port="$(read_value "$profile/port")"
  fi
  alias="$(tui_input 'Connection name' "${source_alias:-molt-vm}")" || return 0
  hostname="$(tui_input 'VM address' "$hostname")" || return 0
  user="$(tui_input 'SSH username' "$user")" || return 0
  port="$(tui_input 'SSH port' "$port")" || return 0
  auth="$(tui_choose 'SSH authentication' 'Passwords and key passphrases are entered through SSH and are never saved by the console.' \
    'Use an existing private key|existing' 'Create a dedicated MOLT key|new' 'Initial password login, then create a MOLT key|password')" || return 0
  identity=''
  if [[ "$auth" == existing ]]; then
    identity="$(tui_input 'Identity file' "${HOME}/.ssh/id_ed25519")" || return 0
    identity="$(tui_path "$identity")"
  elif [[ "$auth" == new ]]; then
    initial="$(tui_input 'Initial login key (optional; blank uses SSH agent or password)' '')" || return 0
    [[ -z "$initial" ]] || initial="$(tui_path "$initial")"
  fi
  tui_run 'Save connection' "$TUI_BIN" connection add "$alias" "$hostname" "$user" "$port" "$identity" || return 0
  "$TUI_BIN" connection use "$alias" || return 0
  tui_reload
  if [[ "$auth" != existing ]]; then
    tui_terminal 'Create dedicated key' "$TUI_BIN" connection keygen "$alias" || return 0
    tui_terminal 'Install public key using initial login' "$TUI_BIN" connection authorize "$alias" "$initial" || return 0
  fi
  tui_connect "$alias" || return 0
}

tui_connections() {
  local action alias profile choice
  local -a choices
  while :; do
    tui_reload
    action="$(tui_choose 'Connections' "Selected connection: $MOLT_HOST" 'Add / edit a connection|add' 'Use an existing SSH alias|external' 'Saved connections|saved' 'Back|back')" || return 0
    case "$action" in
      add) tui_connection_form ;;
      external)
        alias="$(tui_input 'Existing SSH alias' "$MOLT_HOST")" || continue
        tui_run 'Select SSH connection' "$TUI_BIN" connection use "$alias" || continue
        tui_reload
        tui_connect "$alias" || true ;;
      saved)
        choices=()
        for profile in "$MOLT_HOME/state/ssh/profiles"/*/hostname; do
          [[ -f "$profile" ]] || continue
          alias="$(basename "${profile%/*}")"
          choices+=("$alias  ($(read_value "$profile"))|alias:$alias")
        done
        choices+=('Back|back')
        alias="$(tui_choose 'Saved connections' 'Connections needed by existing resources are retained for cleanup.' "${choices[@]}")" || continue
        [[ "$alias" != back ]] || continue
        alias="${alias#alias:}"
        choice="$(tui_choose "$alias" '' 'Select this connection|use' 'Test connection|test' 'Edit / duplicate profile|edit' 'Authorize dedicated key|authorize' 'Revoke dedicated key|revoke' 'Remove profile|remove' 'Back|back')" || continue
        case "$choice" in
          use) tui_run 'Select connection' "$TUI_BIN" connection use "$alias" || true ;;
          test) tui_connect "$alias" && tui_run 'Test connection' "$TUI_BIN" connection test "$alias" || true ;;
          edit) tui_connection_form "$alias" ;;
          authorize|revoke) tui_terminal 'Manage dedicated access key' "$TUI_BIN" connection "$choice" "$alias" || true ;;
          remove) tui_confirm "Remove connection $alias?" && tui_run 'Remove connection' "$TUI_BIN" connection remove "$alias" || true ;;
        esac ;;
      *) return 0 ;;
    esac
  done
}

tui_setup() {
  local choice folder remote
  choice="$(tui_choose 'Guided setup' 'The console runs on this Mac. It prepares your VM through SSH.' "Use selected connection ($MOLT_HOST)|current" 'Configure a connection|connection' 'Back|back')" || return 0
  case "$choice" in connection) tui_connections ;; current) ;; *) return 0 ;; esac
  tui_reload
  folder="$MOLT_ROOT"
  if [[ ! -d "$folder" ]]; then folder="${MOLT_USER_HOME:-$HOME}"; fi
  folder="$(tui_input 'Project folder' "$folder")" || return 0
  tui_run 'Save project folder' "$TUI_BIN" config set MOLT_ROOT "$(tui_path "$folder")" || return 0
  remote="$(tui_input 'Remote workspace' "$MOLT_REMOTE_HOME")" || return 0
  tui_run 'Save remote workspace' "$TUI_BIN" config set MOLT_REMOTE_HOME "$remote" || return 0
  tui_reload
  tui_connect || return 0
  tui_screen 'Prepare VM'
  tui_confirm "Prepare $MOLT_HOST, installing Docker and granting this user access if needed? Administrator authentication may be required." || return 0
  tui_terminal 'Prepare VM' "$TUI_BIN" bootstrap || return 0
  tui_screen 'Shell activation'
  if tui_confirm 'Enable MOLT commands automatically in new Zsh terminals?'; then tui_run 'Enable shell activation' "$TUI_BIN" shell enable || return 0; fi
  write_value "$MOLT_HOME/state/ui/setup.done" 1
  choice="$(tui_choose 'Setup complete' 'Your VM is ready. Select a project to start its environment.' 'Choose a project|projects' 'Open control center|console')" || return 0
  [[ "$choice" != projects ]] || tui_projects
}

tui_project_ready() {
  local id="$1" state="$MOLT_PROJECTS_HOME/$1"
  tui_connect "$(read_value "$state/host")" || return 1
  if [[ "$(read_value "$state/active")" != 1 ]]; then
    tui_screen 'Start project'
    tui_confirm 'Start the project environment for this action?' || return 1
    tui_run 'Start project' "$TUI_BIN" start "@$id" || return 1
  fi
}

tui_opencode_project() {
  local id="$1" action file
  while :; do
    action="$(tui_choose 'OpenCode' "Project: $(read_value "$MOLT_PROJECTS_HOME/$id/name")" 'Attach to project|attach' 'Log in to a provider|login' 'List providers|list' 'Log out of a provider|logout' 'Available models|models' 'Edit server settings|config' 'Back|back')" || return 0
    [[ "$action" != back ]] || return 0
    tui_project_ready "$id" || continue
    case "$action" in
      attach) tui_terminal 'OpenCode session' "$TUI_BIN" oc-project "@$id" || true ;;
      login|list|logout) tui_terminal 'Provider authentication' "$TUI_BIN" remote-oc "@$id" auth "$action" || true ;;
      models) tui_run 'Available models' "$TUI_BIN" remote-oc "@$id" models || true ;;
      config)
        file="$(mktemp "$MOLT_HOME/state/tmp/opencode.XXXXXX")"
        if "$TUI_BIN" server-config "@$id" get >"$file"; then
          tui_screen 'Server settings / JSON'
          printf 'These settings apply to projects on this VM. Ctrl-D saves / Esc cancels.\n' >&2
          if "$GUM" write --char-limit 0 <"$file" >"$file.next" && tui_confirm 'Save server settings? Restart projects to apply changes.'; then
            tui_run 'Save server settings' "$TUI_BIN" server-config "@$id" set "$file.next" || true
          fi
        else tui_message 'Server settings' 'Could not retrieve the settings. Retry after checking the connection.'; fi
        rm -f "$file" "$file.next" ;;
    esac
  done
}

tui_project_menu() {
  local id="$1" state="$MOLT_PROJECTS_HOME/$1" action value host
  while [[ -f "$state/path" ]]; do
    host="$(read_value "$state/host")"
    action="$(tui_choose "$(read_value "$state/name")" "$(read_value "$state/path")"$'\n'"Host: $host / Active: $(read_value "$state/active")" \
      'Start|start' 'Stop|stop' 'Restart|restart' 'Inspect|inspect' 'Logs|logs' 'Forwarded ports|ports' 'OpenCode|opencode' 'Remote shell|shell' 'Environment file|environment' 'Reset project|reset' 'Back|back')" || return 0
    case "$action" in
      start) tui_connect "$host" && tui_run 'Start project' "$TUI_BIN" start "@$id" || true ;;
      stop)
        if [[ "$(read_value "$state/active")" != 1 ]] || tui_connect "$host"; then tui_run 'Stop project' "$TUI_BIN" stop "@$id" || true; fi ;;
      restart)
        tui_connect "$host" && tui_run 'Stop project' "$TUI_BIN" stop "@$id" && tui_run 'Start project' "$TUI_BIN" start "@$id" || true ;;
      inspect) tui_run 'Inspect project' "$TUI_BIN" inspect "@$id" || true ;;
      logs) tui_connect "$host" && tui_run 'Project logs' "$TUI_BIN" logs "@$id" || true ;;
      ports)
        if [[ "$(read_value "$state/active")" == 1 ]]; then tui_connect "$host" || continue; fi
        value="$(tr '\n' ' ' <"$state/ports")"
        value="$(tui_input 'Ports / separated by spaces' "$value")" || continue
        tui_confirm 'Save ports in the Mac checkout .molt.yml and apply forwarding?' && tui_run 'Save project ports' "$TUI_BIN" ports "@$id" "$value" || true ;;
      opencode) tui_opencode_project "$id" ;;
      shell) tui_project_ready "$id" && tui_terminal 'Project shell' "$TUI_BIN" project-shell "@$id" || true ;;
      environment)
        value="$(tui_choose 'Environment file' 'Changes to the Mac checkout require an explicit action.' 'Inspect environment|review' 'Generate devenv.nix in the Mac checkout|generate' 'Review and commit environment|commit' 'Back|back')" || continue
        case "$value" in
          review) tui_run 'Review environment' "$TUI_BIN" review-env "@$id" || true ;;
          generate) tui_confirm 'Create devenv.nix in this Mac checkout?' && tui_run 'Generate environment' "$TUI_BIN" generate-env "@$id" || true ;;
          commit) tui_terminal 'Review and commit environment' "$TUI_BIN" commit-env "@$id" || true ;;
        esac ;;
      reset)
        tui_confirm 'Remove this project container, image, synchronization, mirror, and MOLT state? The Mac checkout is kept.' || continue
        if [[ -n "$(read_value "$state/remote_path")" ]]; then tui_connect "$host" || continue; fi
        tui_run 'Reset project' env MOLT_ASSUME_YES=1 "$TUI_BIN" reset "@$id" || true ;;
      *) return 0 ;;
    esac
  done
}

tui_scan_projects() {
  local repo selection id label
  local -a choices=()
  tui_run 'Scan repositories' "$TUI_BIN" scan "$MOLT_ROOT" || return 0
  while IFS= read -r repo; do
    [[ -d "$repo" ]] || continue
    label="${repo//|/¦}"
    choices+=("$label|$repo")
  done <"$MOLT_HOME/state/ui/last.log"
  if [[ ${#choices[@]} == 0 ]]; then tui_message 'Add a project' "No Git repositories found under $MOLT_ROOT. Choose a project folder in Settings."; return 0; fi
  choices+=('Back|back')
  selection="$(tui_choose 'Add a project' "Repositories under $MOLT_ROOT" "${choices[@]}")" || return 0
  [[ "$selection" != back ]] || return 0
  tui_run 'Register project' "$TUI_BIN" register "$selection" || return 0
  id="$("$TUI_BIN" project-id "$selection")"
  tui_project_menu "$id"
}

tui_projects() {
  local mode="${1:-projects}" state id label selection title=Projects
  [[ "$mode" != opencode ]] || title='OpenCode projects'
  local -a choices
  while :; do
    choices=()
    for state in "$MOLT_PROJECTS_HOME"/*/path; do
      [[ -f "$state" ]] || continue
      id="$(basename "${state%/*}")"
      label="$(read_value "${state%/*}/name")  [$(read_value "${state%/*}/runtime"), active=$(read_value "${state%/*}/active")]"
      choices+=("${label//|/¦}|$id")
    done
    choices+=('Scan / add repositories|scan' 'Start all registered projects|up' 'Stop all projects|down' 'Back|back')
    selection="$(tui_choose "$title" "Project folder: $MOLT_ROOT" "${choices[@]}")" || return 0
    case "$selection" in
      scan) tui_scan_projects ;;
      up|down) tui_connect_all "$selection" && tui_run 'Manage all projects' "$TUI_BIN" "$selection" || true ;;
      back) return 0 ;;
      *)
        if [[ "$selection" =~ ^[a-f0-9]{12}$ ]]; then
          if [[ "$mode" == opencode ]]; then tui_opencode_project "$selection"; else tui_project_menu "$selection"; fi
        fi ;;
    esac
  done
}

tui_settings() {
  local action key value
  while :; do
    tui_reload
    action="$(tui_choose 'Settings' '' 'Project folder|MOLT_ROOT' 'Remote workspace|MOLT_REMOTE_HOME' 'OpenCode base port|MOLT_OPENCODE_BASE_PORT' 'Blocked ports|MOLT_PORT_DENY' 'Port polling interval|MOLT_PORT_POLL' 'Shell activation|shell' 'Back|back')" || return 0
    case "$action" in
      back) return 0 ;;
      shell)
        value="$(tui_choose 'Shell activation' "$("$TUI_BIN" shell status)" 'Enable in new Zsh terminals|enable' 'Disable|disable' 'Back|back')" || continue
        [[ "$value" == back ]] || tui_run 'Shell activation' "$TUI_BIN" shell "$value" || true ;;
      *)
        key="$action"
        case "$key" in
          MOLT_ROOT) action='Project folder' ;;
          MOLT_REMOTE_HOME) action='Remote workspace' ;;
          MOLT_OPENCODE_BASE_PORT) action='OpenCode port range / base port' ;;
          MOLT_PORT_DENY) action='Blocked ports / separated by spaces' ;;
          MOLT_PORT_POLL) action='Port refresh interval / seconds' ;;
        esac
        value="$(tui_input "$action" "${!key}")" || continue
        [[ "$key" != MOLT_ROOT ]] || value="$(tui_path "$value")"
        tui_run 'Save settings' "$TUI_BIN" config set "$key" "$value" || true ;;
    esac
  done
}

tui_connect_all() {
  local state host
  local -a hosts=()
  for state in "$MOLT_HOME/state/remotes"/*/host "$MOLT_PROJECTS_HOME"/*/host "$MOLT_HOME/state/ssh/profiles"/*/authorized; do
    [[ -f "$state" ]] || continue
    if [[ "$state" == "$MOLT_PROJECTS_HOME/"* && "${1:-}" != up && -z "$(read_value "${state%/*}/remote_path")" && -z "$(read_value "${state%/*}/remote_meta")" ]]; then continue; fi
    if [[ "$(basename "$state")" == authorized ]]; then host="$(basename "${state%/*}")"; else host="$(read_value "$state")"; fi
    case " ${hosts[*]:-} " in *" $host "*) continue ;; esac
    hosts+=("$host")
    tui_connect "$host" || return 1
  done
}

tui_maintenance() {
  local action folder
  while :; do
    action="$(tui_choose 'Maintenance' '' 'Tool versions|tools' 'Diagnostics|doctor' 'Prepare / repair VM|bootstrap' 'Stop local helpers|local-down' 'Reset all projects|reset' 'Remove empty remote workspaces|roots' 'Repair this installation|repair' 'Upgrade from a checkout|upgrade' 'Open installation folder in Finder|finder' 'Back|back')" || return 0
    case "$action" in
      tools|local-down) tui_run 'Maintenance' "$TUI_BIN" "$action" || true ;;
      doctor) tui_connect && tui_run 'Diagnostics' "$TUI_BIN" doctor || true ;;
      bootstrap) tui_connect && tui_confirm 'Prepare Docker and user access on the selected VM?' && tui_terminal 'Prepare VM' "$TUI_BIN" bootstrap || true ;;
      reset) tui_confirm 'Remove all project resources and MOLT state? Mac checkouts are kept.' && tui_connect_all && tui_run 'Reset all projects' env MOLT_ASSUME_YES=1 "$TUI_BIN" reset --all || true ;;
      roots) tui_confirm 'Remove the recorded empty remote workspaces?' && tui_connect_all && tui_run 'Remove remote workspaces' "$TUI_BIN" remove-remote-roots || true ;;
      repair) tui_run 'Repair installation' /bin/bash "$MOLT_HOME/current/install.sh" --non-interactive || true ;;
      upgrade)
        folder="$(tui_input 'MOLT source checkout' "${MOLT_USER_HOME:-$HOME}")" || continue
        folder="$(tui_path "$folder")"
        [[ -f "$folder/install.sh" && -f "$folder/tools.lock" ]] || { tui_message 'Upgrade' 'Select a MOLT checkout containing install.sh and tools.lock.'; continue; }
        tui_confirm "Install MOLT from $folder?" && tui_run 'Upgrade MOLT' /bin/bash "$folder/install.sh" --non-interactive || true ;;
      finder) open "$MOLT_HOME" || true ;;
      *) return 0 ;;
    esac
  done
}

tui_uninstall() {
  local choice inventory output
  local -a options=(--yes)
  inventory="$("$TUI_BIN" cleanup-inventory)" || return 0
  while :; do
    choice="$(tui_choose 'Uninstall' 'Choose the removal scope. Preview shows saved connections and resource locations.' 'Remove MOLT and remote resources|complete' 'Also undo recorded Docker preparation|undo' 'Remove this Mac installation only|local' 'Preview cleanup inventory|preview' 'Back|back')" || return 0
    [[ "$choice" == preview ]] || break
    printf '%s\n' "${inventory:-No remote resources recorded.}" | "$GUM" pager || true
  done
  case "$choice" in
    complete) ;;
    undo) options+=(--undo-vm) ;;
    local)
      output="$(tui_input 'Save remote cleanup inventory' "${MOLT_USER_HOME:-$HOME}/molt-cleanup-$(date +%Y%m%d-%H%M%S).txt")" || return 0
      output="$(molt_canonical "$(tui_path "$output")")" || return 0
      case "$output" in "$MOLT_HOME"|"$MOLT_HOME/"*) tui_message 'Cleanup inventory' 'Choose a file outside the installation.'; return 0 ;; esac
      [[ ! -e "$output" && ! -L "$output" ]] || { tui_message 'Cleanup inventory' 'Choose a new file so existing data is preserved.'; return 0; }
      printf '%s\n' "$inventory" >"$output"
      options+=(--local-only) ;;
    *) return 0 ;;
  esac
  tui_screen 'Remove MOLT'
  tui_confirm 'Remove MOLT with the selected cleanup options? Mac checkouts are kept.' || return 0
  [[ "$choice" == local ]] || tui_connect_all || return 0
  tui_terminal 'Uninstall MOLT' "$MOLT_HOME/bin/molt-uninstall" "${options[@]}" || true
}

tui_main() (
  local action count running state description
  GUM="${MOLT_GUM_BINARY:-$(molt_value "$MOLT_HOME/.install-manifest" GUM_BINARY)}"
  molt_gum_version "$GUM" || { molt_error 'repair the installation to restore Gum 2.0.2'; exit 1; }
  TUI_BIN="$MOLT_HOME/bin/molt"
  molt_state
  mkdir -p "$MOLT_HOME/state/ui"
  TUI_ACTION_WORK=''
  trap 'tui_stop_action; tui_end' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  tui_begin || exit 1
  if [[ ! -f "$MOLT_HOME/state/ui/setup.done" ]]; then
    action="$(tui_choose 'Welcome to MOLT' 'Set up SSH, prepare the VM, and choose your projects from this local console.' 'Guided setup|setup' 'Open control center|console')" || exit 0
    [[ "$action" != setup ]] || tui_setup
  fi
  while [[ -d "$MOLT_HOME" ]]; do
    tui_reload
    count=0; running=0
    for state in "$MOLT_PROJECTS_HOME"/*/active; do
      [[ -f "$state" ]] || continue
      count=$((count + 1))
      [[ "$(read_value "$state")" != 1 ]] || running=$((running + 1))
    done
    description="Installation: $MOLT_HOME"$'\n'"Connection: $MOLT_HOST / Projects: $count / Active: $running"
    action="$(tui_choose 'MOLT Control Center' "$description" 'Overview|overview' 'Projects|projects' 'Connections|connections' 'Guided setup|setup' 'OpenCode|opencode' 'Settings|settings' 'Maintenance|maintenance' 'Uninstall|uninstall' 'Quit|quit')" || exit 0
    case "$action" in
      overview) tui_run 'Overview' "$TUI_BIN" status || true ;;
      projects) tui_projects ;;
      opencode) tui_projects opencode ;;
      connections) tui_connections ;;
      setup) tui_setup ;;
      settings) tui_settings ;;
      maintenance) tui_maintenance ;;
      uninstall) tui_uninstall ;;
      *) exit 0 ;;
    esac
  done
)
