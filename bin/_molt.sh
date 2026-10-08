#!/usr/bin/env bash
# Shared installation ownership, dependency isolation, and SSH settings.

molt_error() { printf 'molt: %s\n' "$*" >&2; }
molt_value() {
  [[ -f "$1" ]] || return 1
  awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$1"
}

molt_canonical() {
  local path="$1" parent leaf target
  [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
  if [[ -d "$path" ]]; then (cd "$path" && pwd -P); return; fi
  if [[ -L "$path" ]]; then
    target="$(readlink "$path")" || return 1
    case "$target" in /*) molt_canonical "$target" ;; *) molt_canonical "$(dirname "$path")/$target" ;; esac
    return
  fi
  path="${path%/}"
  parent="$(dirname "$path")"; leaf="$(basename "$path")"
  [[ "$leaf" != . && "$leaf" != .. ]] || return 1
  parent="$(molt_canonical "$parent")" || return 1
  printf '%s/%s\n' "${parent%/}" "$leaf"
}

molt_safe_home() {
  local home
  MOLT_HOME="$(molt_canonical "$MOLT_HOME")" || { molt_error 'invalid MOLT_HOME'; return 1; }
  [[ ! -e "$MOLT_HOME" || -d "$MOLT_HOME" ]] || { molt_error 'MOLT_HOME is not a directory'; return 1; }
  home="$(molt_canonical "${MOLT_USER_HOME:-$HOME}")" || return 1
  [[ "$MOLT_HOME" != / && "$MOLT_HOME" != "$home" && "$home" != "$MOLT_HOME/"* ]] || {
    molt_error "refusing unsafe MOLT_HOME=$MOLT_HOME"; return 1;
  }
  export MOLT_HOME
}

molt_owned_home() {
  molt_safe_home || return 1
  [[ ! -L "$MOLT_HOME/.install-manifest" ]] || return 1
  [[ "$(molt_value "$MOLT_HOME/.install-manifest" FORMAT)" == 2 &&
     "$(molt_value "$MOLT_HOME/.install-manifest" ROOT)" == "$MOLT_HOME" ]] || {
    molt_error "not an owned molt installation: $MOLT_HOME"; return 1;
  }
  MOLT_INSTALL_ID="$(molt_value "$MOLT_HOME/.install-manifest" INSTALL_ID)" || return 1
  [[ "$MOLT_INSTALL_ID" =~ ^[a-f0-9]{32}$ ]] || return 1
  export MOLT_INSTALL_ID
}

molt_id() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]';
  else openssl rand -hex 16; fi
}

molt_state() {
  local path
  molt_safe_home || return 1
  for path in state projects; do
    [[ ! -L "$MOLT_HOME/$path" ]] || { molt_error "symlinked $path directory"; return 1; }
  done
  for path in home config data cache run tmp ssh remotes ui shell ssh/profiles ssh/keys home/.mutagen config/opencode data/opencode cache/opencode run/opencode; do
    [[ "$(molt_canonical "$MOLT_HOME/state/$path")" == "$MOLT_HOME/state/$path" ]] || {
      molt_error "state/$path points outside its contained location"; return 1;
    }
  done
  mkdir -p "$MOLT_HOME/state/"{home,config,data,cache,run,tmp,ssh,remotes}
}

molt_isolated() {
  molt_state || return 1
  env HOME="$MOLT_HOME/state/home" MOLT_USER_HOME="${MOLT_USER_HOME:-$HOME}" MOLT_HOME="$MOLT_HOME" \
    XDG_CONFIG_HOME="$MOLT_HOME/state/config" XDG_DATA_HOME="$MOLT_HOME/state/data" \
    XDG_CACHE_HOME="$MOLT_HOME/state/cache" XDG_STATE_HOME="$MOLT_HOME/state/run" \
    TMPDIR="$MOLT_HOME/state/tmp" OPENCODE_CONFIG_DIR="$MOLT_HOME/state/config/opencode" \
    OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_PROJECT_CONFIG=1 "$@"
}

molt_dependency() {
  local name="$1" explicit="${2:-}" candidate
  if [[ -n "$explicit" ]]; then
    [[ -x "$explicit" && ! -d "$explicit" ]] || { molt_error "invalid $name executable: $explicit"; return 1; }
    candidate="$(molt_canonical "$explicit")" || return 1
    case "$candidate" in */shims/*) molt_error "a shim is not a $name dependency"; return 1 ;; esac
    printf '%s\n' "$candidate"; return
  fi
  while IFS= read -r candidate; do
    case "$candidate" in "$MOLT_HOME/"*|*/shims/*) continue ;; esac
    [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return; }
  done < <(type -aP "$name" 2>/dev/null || true)
  return 1
}

molt_download_tool() {
  local name="$1" destination="$2" lock="$3" asset repo version checksum archive
  case "$(uname -s)/$(uname -m)/$name" in
    Darwin/arm64/mutagen) asset=mutagen_darwin_arm64_v0.18.1.tar.gz ;;
    Darwin/x86_64/mutagen) asset=mutagen_darwin_amd64_v0.18.1.tar.gz ;;
    Darwin/arm64/opencode) asset=opencode-darwin-arm64.zip ;;
    Darwin/x86_64/opencode) asset=opencode-darwin-x64-baseline.zip ;;
    *) molt_error 'automatic downloads support macOS arm64 and x86_64'; return 1 ;;
  esac
  case "$name" in
    mutagen) version=v0.18.1; repo=mutagen-io/mutagen ;;
    opencode) version=v1.18.34; repo=anomalyco/opencode ;;
  esac
  checksum="$(awk -v asset="$asset" '$2==asset {print $1}' "$lock")"
  [[ "$checksum" =~ ^[a-f0-9]{64}$ ]] || { molt_error "missing checksum for $asset"; return 1; }
  archive="$destination/$asset"
  curl -fsSL --retry 2 "https://github.com/$repo/releases/download/$version/$asset" -o "$archive" || return 1
  [[ "$(shasum -a 256 "$archive" | cut -d ' ' -f1)" == "$checksum" ]] || {
    molt_error "checksum mismatch for $asset"; return 1;
  }
  mkdir -p "$destination/tools/$name"
  if [[ "$asset" == *.zip ]]; then unzip -q "$archive" -d "$destination/tools/$name" || return 1;
  else tar -xzf "$archive" -C "$destination/tools/$name" || return 1; fi
  rm -f "$archive"
  [[ -x "$destination/tools/$name/$name" ]] || { molt_error "missing executable in $asset"; return 1; }
  printf '%s\n' "$destination/tools/$name/$name"
}


molt_mutagen() (
  local binary
  binary="${MOLT_MUTAGEN_BINARY:-$(molt_value "$MOLT_HOME/.install-manifest" MUTAGEN_BINARY 2>/dev/null || true)}"
  [[ -n "$binary" ]] || binary="$(molt_dependency mutagen "${MOLT_MUTAGEN_BINARY:-}")" || return 1
  molt_state || exit 1
  cd "$MOLT_HOME/state/home" || exit 1
  # Mutagen's default data path follows HOME. Keeping HOME relative to this
  # private working directory also keeps its Unix socket below macOS's limit.
  molt_isolated env -u MUTAGEN_DATA_DIRECTORY HOME=. \
    MUTAGEN_SSH_PATH="$MOLT_HOME/bin/transport" "$binary" "$@"
)

molt_legacy_mutagen() {
  local binary
  binary="$(molt_value "$MOLT_HOME/.install-manifest" MUTAGEN_BINARY)" || return 1
  env -u MUTAGEN_SSH_PATH HOME="${MOLT_USER_HOME:-$HOME}" \
    MUTAGEN_DATA_DIRECTORY="${MOLT_USER_HOME:-$HOME}/.mutagen" "$binary" "$@"
}

molt_stop_daemon() {
  local socket="$MOLT_HOME/state/home/.mutagen/daemon/daemon.sock" attempt
  [[ -S "$socket" ]] || return 0
  molt_mutagen daemon stop || return 1
  for attempt in {1..30}; do
    [[ -S "$socket" ]] || return 0
    sleep 0.1
  done
  molt_error 'Mutagen daemon did not close its socket'
  return 1
}

molt_client() {
  local binary
  binary="$(molt_value "$MOLT_HOME/.install-manifest" OPENCODE_BINARY)" || return 1
  "$binary" "$@"
}

molt_kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" || true); do molt_kill_tree "$child"; done
  kill -TERM "$pid" 2>/dev/null || true
}

molt_stop_workers() {
  local file pid script process attempt
  for file in "$MOLT_HOME/state/tmp"/{run,client,start}.*/parent.pid; do
    [[ -f "$file" ]] || continue
    pid="$(<"$file")"
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" -gt 1 ]] || return 1
    process="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ -n "$process" ]] || continue
    [[ -f "${file%/*}/script" ]] || { molt_error 'incomplete worker record'; return 1; }
    script="$(<"${file%/*}/script")"
    case "$(molt_canonical "$script")" in "$MOLT_HOME/releases/"*/bin/molt) ;; *) molt_error 'invalid worker ownership'; return 1 ;; esac
    case "$process" in
      *"$script "*)
        molt_kill_tree "$pid"
        for attempt in {1..30}; do
          kill -0 "$pid" 2>/dev/null || break
          sleep 0.1
        done
        if kill -0 "$pid" 2>/dev/null; then molt_error "owned process $pid did not stop"; return 1; fi
        ;;
    esac
  done
}

molt_host_key() { printf '%s' "$1" | shasum -a 256 | cut -c1-20; }

molt_ssh() (
  molt_state || exit 1
  local known_hosts
  [[ ! -L "$MOLT_HOME/state/ssh/known_hosts" ]] || { molt_error 'symlinked known-hosts file'; exit 1; }
  known_hosts="${MOLT_HOME//%/%%}/state/ssh/known_hosts"
  known_hosts="${known_hosts//\\/\\\\}"; known_hosts="${known_hosts//\"/\\\"}"
  local -a options
  options=(-o ControlMaster=auto -o 'ControlPath=./c-%C' -o ControlPersist=60
    -o "UserKnownHostsFile=\"$known_hosts\"" -o "ConnectTimeout=${MOLT_SSH_CONNECT_TIMEOUT:-10}"
    -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
  # Background TUI actions cannot borrow the outer terminal for authentication.
  # Interactive authentication runs in the control center's embedded PTY.
  if [[ "${MOLT_UI_BATCH:-0}" == 1 ]]; then options+=(-o BatchMode=yes -o StrictHostKeyChecking=yes); fi
  if [[ -n "${MOLT_SSH_CONFIG:-}" ]]; then options+=(-F "$MOLT_SSH_CONFIG");
  elif [[ -f "${MOLT_USER_HOME:-$HOME}/.ssh/config" ]]; then options+=(-F "${MOLT_USER_HOME:-$HOME}/.ssh/config");
  else options+=(-F /dev/null); fi
  # Relative sockets avoid the Unix socket path limit for long installation paths.
  cd "$MOLT_HOME/state/ssh" || exit 1
  command ssh "${options[@]}" "$@"
)

molt_remove_legacy_shell() {
  local manifest="$1" rc home_line path_line target tmp
  [[ "$(molt_value "$manifest" PATH_ADDED 2>/dev/null || true)" == 1 ]] || return 0
  [[ ! -f "$MOLT_HOME/legacy-shell-cleaned" ]] || return 0
  rc="$(molt_value "$manifest" ZSHRC)" || return 1
  [[ -f "$rc" ]] || return 0
  home_line="$(molt_value "$manifest" MOLT_HOME_LINE 2>/dev/null || true)"
  path_line="$(molt_value "$manifest" PATH_LINE)" || return 1
  if ! grep -Fxq "$path_line" "$rc"; then
    molt_error "legacy PATH entry was edited; remove remaining molt entries from $rc manually"
    return 0
  fi
  # Replace the target atomically, preserving a dotfile symlink and a recovery copy.
  target="$(molt_canonical "$rc")" || return 1
  cp -p "$rc" "$MOLT_HOME/legacy-zshrc.backup" || return 1
  tmp="$(mktemp "$MOLT_HOME/state/tmp/zshrc.XXXXXX")" || return 1
  MOLT_OLD_HOME_LINE="$home_line" MOLT_OLD_PATH_LINE="$path_line" awk '
    { lines[NR]=$0 }
    END {
      for(i=1;i<=NR;i++) if(lines[i]==ENVIRON["MOLT_OLD_PATH_LINE"] ||
        (ENVIRON["MOLT_OLD_HOME_LINE"]!="" && lines[i]==ENVIRON["MOLT_OLD_HOME_LINE"])) {
        removed[i]=1
        if(i>1 && lines[i-1]=="# molt") { removed[i-1]=1; if(i>2 && lines[i-2]=="") removed[i-2]=1 }
      }
      for(i=1;i<=NR;i++) if(!removed[i]) print lines[i]
    }' "$rc" >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod "$(stat -f '%Lp' "$target")" "$tmp" || return 1
  mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
  : >"$MOLT_HOME/legacy-shell-cleaned"
}
