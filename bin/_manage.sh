#!/usr/bin/env bash
# Configuration and access operations shared by the CLI and local control center.

valid_line() { [[ "$1" != *[[:cntrl:]]* ]]; }
valid_host() { [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.:-]*$ ]]; }
valid_alias() { [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

managed_file() {
  [[ "$(molt_canonical "$1")" == "$1" && ! -L "$1" ]] || die "unsafe managed path: $1"
}

cmd_config() {
  local action="${1:-show}" key="${2:-}" value="${3:-}" tmp record
  case "$key" in
    MOLT_HOST|MOLT_ROOT|MOLT_REMOTE_HOME|MOLT_SSH_CONFIG|MOLT_OPENCODE_BASE_PORT|MOLT_ANIMATIONS) ;;
    '') [[ "$action" == show ]] || die 'choose a configuration setting' ;;
    *) die "unsupported setting: $key" ;;
  esac
  case "$action" in
    show)
      for key in MOLT_HOST MOLT_ROOT MOLT_REMOTE_HOME MOLT_SSH_CONFIG MOLT_OPENCODE_BASE_PORT MOLT_ANIMATIONS; do
        printf '%s=%s\n' "$key" "${!key}"
      done ;;
    get) printf '%s\n' "${!key}" ;;
    set)
      [[ $# == 3 ]] || die 'molt config set <setting> <value>'
      molt_owned_home || die 'install molt before saving settings'
      valid_line "$value" || die 'settings cannot contain control characters'
      case "$key" in
        MOLT_HOST) [[ -z "$value" ]] || valid_alias "$value" || die 'invalid SSH host alias' ;;
        MOLT_ROOT) value="$(canonical_path "$value")" ;;
        MOLT_SSH_CONFIG) [[ -f "$value" ]] || die 'SSH configuration file not found'; value="$(molt_canonical "$value")" ;;
        MOLT_REMOTE_HOME)
          case "$value" in ''|/|'$HOME'|'~'|.|..|../*|*/../*|*/..|*/./*) die 'unsafe remote workspace' ;; esac
          record="$MOLT_HOME/state/remotes/$(molt_host_key "$MOLT_CONFIG_HOST")/root"
          [[ ! -f "$record" || "$value" == "$MOLT_REMOTE_HOME" ]] || die 'clean up the recorded remote workspace before changing its location' ;;
        MOLT_OPENCODE_BASE_PORT)
          valid_port "$value" && (( 10#$value >= 1024 && 10#$value <= 65036 )) || die 'OpenCode base port must be between 1024 and 65036'
          value="$((10#$value))" ;;
        MOLT_ANIMATIONS) [[ "$value" == 0 || "$value" == 1 ]] || die 'animations must be 0 or 1' ;;
      esac
      molt_state
      managed_file "$CONFIG_FILE"
      tmp="$(mktemp "$MOLT_HOME/state/tmp/config.XXXXXX")"
      if ! awk -v key="$key" '$0 !~ "^[[:space:]]*(export[[:space:]]+)?" key "=" { print }' "$CONFIG_FILE" >"$tmp"; then rm -f "$tmp"; return 1; fi
      printf '%s=%q\n' "$key" "$value" >>"$tmp"
      chmod 600 "$tmp"
      mv -f "$tmp" "$CONFIG_FILE"
      ;;
    *) die 'molt config [show|get <setting>|set <setting> <value>]' ;;
  esac
}

ssh_string() {
  local value="$1"
  valid_line "$value" || die 'SSH values cannot contain control characters'
  value="${value//\\/\\\\}"; value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

connection_in_use() {
  local alias="$1" state
  [[ ! -f "$MOLT_HOME/state/ssh/profiles/$alias/authorized" ]] || return 0
  [[ ! -f "$MOLT_HOME/state/remotes/$(molt_host_key "$alias")/host" ]] || return 0
  for state in "$MOLT_PROJECTS_HOME"/*/host; do
    [[ ! -f "$state" || "$(read_value "$state")" != "$alias" ]] || return 0
  done
  return 1
}

connection_config() {
  local file="$MOLT_HOME/state/ssh/config" includes="$MOLT_HOME/state/ssh/includes" tmp profile include
  molt_state
  managed_file "$file"; managed_file "$includes"
  if [[ -n "$MOLT_SSH_CONFIG" && "$MOLT_SSH_CONFIG" != "$file" ]]; then
    include="$MOLT_SSH_CONFIG"
  else include="${MOLT_USER_HOME:-$HOME}/.ssh/config"; fi
  if [[ -f "$include" ]]; then
    valid_line "$include" || die 'invalid external SSH configuration path'
    grep -Fxq -- "$include" "$includes" 2>/dev/null || printf '%s\n' "$include" >>"$includes"
  fi
  tmp="$(mktemp "$MOLT_HOME/state/tmp/ssh-config.XXXXXX")"
  printf '# Managed by molt. External SSH configuration is included below.\n' >"$tmp"
  for profile in "$MOLT_HOME/state/ssh/profiles"/*/config; do
    [[ -f "$profile" ]] || continue
    managed_file "$profile"
    cat "$profile" >>"$tmp"
  done
  if [[ -f "$includes" ]]; then
    while IFS= read -r include; do
      [[ -f "$include" ]] || continue
      printf 'Host *\nInclude %s\n' "$(ssh_string "$include")" >>"$tmp"
    done <"$includes"
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
  cmd_config set MOLT_SSH_CONFIG "$file"
}

connection_aliases() {
  local config="${MOLT_SSH_CONFIG:-${MOLT_USER_HOME:-$HOME}/.ssh/config}" aliases alias settings detail
  [[ -f "$config" ]] || return 0
  # Discover literal names; OpenSSH resolves their effective settings below.
  aliases="$(/usr/bin/perl -MText::ParseWords=shellwords -MFile::Glob=bsd_glob,GLOB_TILDE -MCwd=abs_path -e '
    my ($config) = @ARGV;
    my (%files, %hosts);
    sub scan {
      my ($path, $depth) = @_;
      $path = abs_path($path);
      return unless defined $path && -f $path;
      return if $files{$path}++;
      die "Too many SSH configuration includes\n" if $depth > 16;
      open my $file, "<", $path or die "Cannot read SSH configuration $path: $!\n";
      while (my $line = <$file>) {
        next unless $line =~ /^\s*(Host|Include)(?:\s*=\s*|\s+)(.*)/i;
        my ($directive, $args) = (lc($1), $2);
        ($args) = $args =~ /^((?:[^"#\\]|\\.|"(?:[^"\\]|\\.)*")*)/;
        for my $value (shellwords($args)) {
          if ($directive eq "host") {
            next if $value =~ /[!*?]/ || $hosts{$value}++;
            print "$value\n";
          } else {
            $value =~ s/\$\{(\w+)\}/exists $ENV{$1} ? $ENV{$1} : "\${$1}"/ge;
            $value = "~/.ssh/$value" unless $value =~ m{^/|^~};
            scan($_, $depth + 1) for bsd_glob($value, GLOB_TILDE);
          }
        }
      }
    }
    scan($config, 0);
  ' "$config")" || return 1
  [[ -n "$aliases" ]] || return 0
  while IFS= read -r alias; do
    valid_alias "$alias" || continue
    settings="$(command ssh -G -T -F "$config" "$alias")" || return 1
    detail="$(printf '%s\n' "$settings" | awk '
      $1 == "user" { user=$2 } $1 == "hostname" { host=$2 } $1 == "port" { port=$2 }
      END { printf "%s@%s:%s", user, host, port }
    ')"
    valid_line "$detail" && [[ "$detail" != *'|'* ]] || die "cannot display SSH settings for $alias"
    printf '%s\t%s\n' "$alias" "$detail"
  done <<<"$aliases"
}

cmd_connection() {
  local action="${1:-list}" alias="${2:-$MOLT_CONFIG_HOST}" profile hostname user port identity tmp
  molt_owned_home || die 'install molt before managing connections'
  case "$action" in
    list|aliases|cleanup) ;;
    *) need_connection "$alias"; valid_alias "$alias" || die 'invalid SSH host alias' ;;
  esac
  profile="$MOLT_HOME/state/ssh/profiles/$alias"
  case "$action" in
    aliases) connection_aliases ;;
    list)
      for profile in "$MOLT_HOME/state/ssh/profiles"/*/hostname; do
        [[ -f "$profile" ]] || continue
        printf '%s  %s@%s:%s\n' "$(basename "$(dirname "$profile")")" "$(read_value "${profile%/*}/user")" "$(read_value "$profile")" "$(read_value "${profile%/*}/port")"
      done ;;
    add)
      [[ $# == 6 ]] || die 'molt connection add <alias> <hostname> <user> <port> <identity-file>'
      hostname="$3"; user="$4"; port="$5"; identity="$6"
      valid_host "$hostname" && [[ "$user" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$ ]] && valid_port "$port" || die 'invalid SSH hostname, username, or port'
      if [[ -n "$identity" ]]; then
        valid_line "$identity" && [[ -f "$identity" ]] || die 'identity file not found'
        identity="$(molt_canonical "$identity")"
      fi
      connection_in_use "$alias" && die 'this connection is recorded by existing resources; add a new alias or clean those resources first'
      molt_state
      managed_file "$profile"
      mkdir -p "$profile"
      for field in hostname user port identity config; do managed_file "$profile/$field"; done
      tmp="$(mktemp "$MOLT_HOME/state/tmp/ssh-profile.XXXXXX")"
      {
        printf 'Host %s\n  HostName %s\n  User %s\n  Port %s\n' "$alias" "$hostname" "$user" "$port"
        if [[ -n "$identity" ]]; then printf '  IdentityFile %s\n  IdentitiesOnly yes\n' "$(ssh_string "${identity//%/%%}")"; fi
      } >"$tmp"
      write_value "$profile/hostname" "$hostname"
      write_value "$profile/user" "$user"
      write_value "$profile/port" "$port"
      write_value "$profile/identity" "$identity"
      mv -f "$tmp" "$profile/config"
      connection_config
      log "saved connection $alias" ;;
    use)
      connection_config
      cmd_config set MOLT_HOST "$alias" ;;
    remove)
      connection_in_use "$alias" && die 'this connection is needed for resource cleanup'
      [[ ! -f "$profile/authorized" ]] || die 'remove the dedicated remote access key before removing this profile'
      managed_file "$profile"
      rm -rf -- "$profile"
      if [[ "$alias" == "$MOLT_CONFIG_HOST" ]]; then
        tmp=''
        for profile in "$MOLT_HOME/state/ssh/profiles"/*/hostname; do
          [[ -f "$profile" ]] || continue
          tmp="$(basename "${profile%/*}")"
          break
        done
        cmd_config set MOLT_HOST "$tmp"
      fi
      connection_config ;;
    keygen)
      [[ -f "$profile/hostname" ]] || die 'save the connection before generating its key'
      connection_in_use "$alias" && die 'add a new profile before changing a key used by existing resources'
      identity="$MOLT_HOME/state/ssh/keys/$alias"
      molt_state
      mkdir -p "$MOLT_HOME/state/ssh/keys"
      managed_file "$identity"; managed_file "$identity.pub"
      [[ ! -e "$identity" && ! -e "$identity.pub" ]] || die 'a dedicated key already exists for this connection'
      ssh-keygen -t ed25519 -f "$identity" -C "molt:$MOLT_INSTALL_ID:$alias"
      cmd_connection add "$alias" "$(read_value "$profile/hostname")" "$(read_value "$profile/user")" "$(read_value "$profile/port")" "$identity"
      ;;
    authorize|revoke)
      identity="$MOLT_HOME/state/ssh/keys/$alias"
      managed_file "$profile/authorized"
      local -a extra=()
      if [[ "$action" == authorize && -n "${3:-}" ]]; then
        [[ -f "$3" ]] && valid_line "$3" || die 'initial identity file not found'
        extra=(-i "$3")
      fi
      if [[ "$action" == authorize ]]; then
        [[ -f "$identity.pub" && "$(read_value "$profile/identity")" == "$identity" ]] || die 'this connection does not have a dedicated molt key'
        managed_file "$identity.pub"
        ssh-keygen -lf "$identity.pub" >/dev/null || die 'invalid dedicated public key'
        tmp="$(read_value "$identity.pub")"
        [[ ! -f "$profile/authorized" || "$(read_value "$profile/authorized")" == "$tmp" ]] || die 'revoke the recorded access key before replacing it'
      else
        [[ -f "$profile/authorized" ]] || return 0
        tmp="$(read_value "$profile/authorized")"
      fi
      [[ "$tmp" == "ssh-ed25519 "*" molt:$MOLT_INSTALL_ID:$alias" ]] && valid_line "$tmp" || die 'dedicated public key ownership mismatch'
      # Snapshot the exact key before upload; cleanup must survive a changed/missing .pub file.
      if [[ "$action" == authorize ]]; then write_value "$profile/authorized" "$tmp"; fi
      MOLT_HOST="$alias"
      ssh -o IdentitiesOnly=no ${extra[@]+"${extra[@]}"} "$alias" "bash -s -- $(quote_remote "$action" "$MOLT_INSTALL_ID" "$alias" "$tmp")" <"$SCRIPT_DIR/_access.sh" || return 1
      if [[ "$action" == revoke ]]; then rm -f "$profile/authorized"; fi
      log "${action}d dedicated access key for $alias" ;;
    cleanup)
      local failed=0
      for tmp in "$MOLT_HOME/state/ssh/profiles"/*/authorized; do
        [[ -f "$tmp" ]] || continue
        cmd_connection revoke "$(basename "${tmp%/*}")" || failed=1
      done
      return "$failed" ;;
    login) MOLT_HOST="$alias"; ssh -o BatchMode=no -o StrictHostKeyChecking=ask "$alias" true ;;
    test) MOLT_HOST="$alias"; ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$alias" 'printf "SSH connection ready\n"' ;;
    check) MOLT_HOST="$alias"; ssh_ok ;;
    *) die 'molt connection [list|aliases|add|use|remove|login|test|check|keygen|authorize|revoke]' ;;
  esac
}

cmd_shell() {
  local action="${1:-status}" record="$MOLT_HOME/state/shell" rc target line tmp
  molt_owned_home || die 'install molt before managing shell integration'
  molt_state
  managed_file "$record"
  for field in target line backup enabled_checksum created; do managed_file "$record/$field"; done
  case "$action" in
    status) if [[ -f "$record/target" ]]; then printf 'enabled: %s\n' "$(read_value "$record/target")"; else printf 'disabled\n'; fi ;;
    enable)
      rc="${ZDOTDIR:-${MOLT_USER_HOME:-$HOME}}/.zshrc"
      target="$(molt_canonical "$rc")" || die 'shell configuration parent does not exist'
      valid_line "$target" || die 'invalid shell configuration path'
      [[ ! -f "$record/target" || "$(read_value "$record/target")" == "$target" ]] || die 'disable the previous shell integration before changing ZDOTDIR'
      if [[ -f "$record/target" ]] && grep -Fxq -- "$(read_value "$record/line")" "$target"; then
        log 'shell activation is already enabled'
        return 0
      fi
      mkdir -p "$record"
      managed_file "$record/target"; managed_file "$record/line"
      printf -v line '[[ ! -f %q ]] || source %q # molt:%s' "$MOLT_HOME/activate.zsh" "$MOLT_HOME/activate.zsh" "$MOLT_INSTALL_ID"
      write_value "$record/target" "$target"
      write_value "$record/line" "$line"
      [[ -f "$target" ]] || { write_value "$record/created" 1; : >"$target"; }
      if ! grep -Fxq -- "$line" "$target"; then
        cp -p "$target" "$record/backup"
        # Save intent before editing; the expected hash also preserves concurrent user edits.
        write_value "$record/enabled_checksum" "$({ cat "$record/backup"; printf '\n%s\n' "$line"; } | shasum -a 256 | cut -d ' ' -f1)"
        printf '\n%s\n' "$line" >>"$target"
      fi
      log 'shell activation enabled for new terminals' ;;
    disable)
      [[ -f "$record/target" ]] || return 0
      target="$(read_value "$record/target")"; line="$(read_value "$record/line")"
      [[ "$(molt_canonical "$target")" == "$target" && ! -L "$target" ]] || die 'the recorded shell target was redirected; inspect it before retrying'
      [[ -f "$target" ]] || { rm -rf "$record"; return 0; }
      if ! grep -Fxq -- "$line" "$target"; then
        grep -Fq -- "# molt:$MOLT_INSTALL_ID" "$target" && die "shell activation was edited; remove its molt:$MOLT_INSTALL_ID entry in $target before retrying"
        if [[ -f "$record/created" && ! -s "$target" ]]; then rm -f "$target"; fi
        rm -rf "$record"
        return 0
      fi
      if [[ "$(shasum -a 256 "$target" | cut -d ' ' -f1)" == "$(read_value "$record/enabled_checksum")" && -f "$record/backup" ]]; then
        cat "$record/backup" >"$target"
      else
        tmp="$(mktemp "$MOLT_HOME/state/tmp/shell.XXXXXX")"
        MOLT_SHELL_LINE="$line" awk '$0 != ENVIRON["MOLT_SHELL_LINE"] { print }' "$target" >"$tmp"
        cat "$tmp" >"$target"; rm -f "$tmp"
      fi
      if [[ -f "$record/created" && ! -s "$target" ]]; then rm -f "$target"; fi
      rm -rf "$record"
      log 'shell activation removed' ;;
    *) die 'molt shell [status|enable|disable]' ;;
  esac
}

cmd_bootstrap() {
  local home root record rc
  molt_owned_home || die 'install molt before preparing a VM'
  ssh_up
  home="$(remote_home)"
  root="$(expand_remote_path "$MOLT_REMOTE_HOME" "$home")"
  root="$(remote_script validate-root "$root" "$MOLT_INSTALL_ID")" || die 'invalid remote workspace; configuration can be corrected before retrying'
  record="$MOLT_HOME/state/remotes/$(molt_host_key "$MOLT_HOST")"
  [[ ! -f "$record/root" || "$(read_value "$record/root")" == "$root" ]] || die 'clean up the recorded remote workspace before changing its location'
  write_value "$record/host" "$MOLT_HOST"
  write_value "$record/root" "$root"
  root="$(remote_script stage-bootstrap "$root" "$MOLT_INSTALL_ID")" || return 1
  write_value "$record/root" "$root"
  upload_file "$SCRIPT_DIR/_remote.sh" "$root/state/bootstrap.sh"
  if ssh -t "$MOLT_HOST" "bash $(quote_remote "$root/state/bootstrap.sh" bootstrap "$root" "$MOLT_INSTALL_ID")"; then rc=0; else rc=$?; fi
  ssh_down || true
  [[ "$rc" == 0 ]] || return "$rc"
  cmd_setup
}

cmd_unprepare_vm() {
  local state root failed=0
  for state in "$MOLT_HOME/state/remotes"/*/host; do
    [[ -f "$state" ]] || continue
    MOLT_HOST="$(read_value "$state")"
    root="$(read_value "${state%/*}/root")"
    remote_script stage-bootstrap "$root" "$MOLT_INSTALL_ID" >/dev/null || { failed=1; continue; }
    upload_file "$SCRIPT_DIR/_remote.sh" "$root/state/bootstrap.sh" || { failed=1; continue; }
    ssh -t "$MOLT_HOST" "bash $(quote_remote "$root/state/bootstrap.sh" unbootstrap "$root" "$MOLT_INSTALL_ID")" || failed=1
    ssh_down || failed=1
  done
  return "$failed"
}

cmd_ui_action() {
  local work="$1" worker
  shift
  molt_owned_home || die 'not an owned installation'
  case "$work" in "$MOLT_HOME/state/tmp/action."*) ;; *) die 'invalid action directory' ;; esac
  managed_file "$work"; managed_file "$work/pid"; managed_file "$work/output"
  [[ -d "$work" ]] || die 'action directory not found'
  printf '%s\n' "$$" >"$work/pid"
  capture_cleanup() {
    local rc="$1" directory="$2" child
    trap - EXIT
    for child in $(pgrep -P "$$" || true); do
      molt_kill_tree "$child"
      wait "$child" 2>/dev/null || true
    done
    rm -f "$directory/pid"
    exit "$rc"
  }
  trap "capture_cleanup \$? $(quote_remote "$work")" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [[ ! -f "$work/cancel" ]] || exit 130
  ( "$@" <&0 2>&1 | tee "$work/output" ) &
  worker=$!
  wait "$worker"
}

cmd_tools() {
  local name binary
  for name in MUTAGEN OPENCODE; do
    binary="$(molt_value "$MOLT_HOME/.install-manifest" "${name}_BINARY")"
    printf '%s: %s\n' "$name" "$binary"
    if [[ "$name" == MUTAGEN ]]; then molt_isolated "$binary" version; else molt_isolated "$binary" --version; fi
  done
  printf 'TUI: Bubble Tea (%s/bin/molt-tui)\n' "$MOLT_HOME"
}

cmd_remote_oc() {
  local ref="$1"
  shift
  load_project "$ref" || die 'project is not registered'
  run_loaded_project "$PROJECT_PATH" /opt/opencode/opencode "$@"
}

cmd_server_config() {
  local ref="$1" action="${2:-get}" file="${3:-}" stage
  load_project "$ref" || die 'project is not registered'
  [[ -n "$PROJECT_REMOTE_HOME" ]] || die 'start the project before configuring its server'
  ssh_up
  case "$action" in
    get) remote_script config-get "$PROJECT_REMOTE_HOME" "$MOLT_INSTALL_ID" ;;
    set)
      [[ -f "$file" ]] && validate_opencode_config "$file" || die 'server settings must be a valid JSONC object'
      stage="$(remote_script config-stage "$PROJECT_REMOTE_HOME" "$MOLT_INSTALL_ID")"
      upload_file "$file" "$stage"
      remote_script config-install "$PROJECT_REMOTE_HOME" "$MOLT_INSTALL_ID" "$stage"
      ;;
    *) die 'molt server-config <repo|@id> [get|set <json-file>]' ;;
  esac
}
