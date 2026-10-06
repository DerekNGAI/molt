#!/usr/bin/env bash
# Sent over SSH; never installed into a system directory on the VM.
set -euo pipefail
umask 077
action="$1"; root="$2"; owner="$3"
shift 3
fail() { printf 'molt: %s\n' "$*" >&2; exit 1; }
[[ "$owner" =~ ^[a-f0-9]{32}$ ]] || fail 'invalid installation identity'
[[ "$root" == /* && "$root" != *$'\n'* && "$root" != *$'\r'* ]] || fail 'invalid remote root'
root="$(realpath -m -- "$root")"
home="$(realpath -m -- "$HOME")"
[[ "$root" != / && "$root" != "$home" && "$home" != "$root/"* ]] || fail 'unsafe remote root'

owned() {
  [[ -f "$root/.install-manifest" && ! -L "$root/.install-manifest" && "$(<"$root/.install-manifest")" == "$owner" ]] || fail "unowned remote root: $root"
  [[ "$(realpath -m -- "$root/state")" == "$root/state" && ! -L "$root/state/docker-resources" && ! -L "$root/state/bootstrap.manifest" ]] || fail 'redirected remote lifecycle state'
}

claim() {
  local fresh=0
  if [[ -e "$root/.install-manifest" ]]; then owned;
  elif [[ -d "$root" && -n "$(ls -A "$root")" ]]; then fail "populated unowned remote root: $root";
  else
    mkdir -p -- "$root"
    printf '%s\n' "$owner" >"$root/.install-manifest"
    fresh=1
  fi
  for directory in projects meta config config/opencode cache state state/home state/home/.mutagen state/tmp; do
    [[ "$(realpath -m -- "$root/$directory")" == "$root/$directory" ]] || fail "symlinked remote directory: $directory"
  done
  mkdir -p -- "$root/"{projects,meta,config/opencode,cache,state/home,state/tmp}
  if [[ "$fresh" == 1 ]]; then printf '0\n' >"$root/state/docker-resources"; fi
}

as_root() { if [[ "$(id -u)" == 0 ]]; then "$@"; else sudo -- "$@"; fi; }
bootstrap_value() { awk -F= -v key="$1" '$1 == key {value=$2} END {print value}' "$root/state/bootstrap.manifest" 2>/dev/null || true; }

remove_path() {
  local path="$1" removal_error
  if removal_error="$(rm -rf -- "$path" 2>&1)"; then return 0; fi
  if [[ ! -d "$path" || -L "$path" || "$(realpath -m -- "$path")" != "$path" ]]; then
    printf '%s\n' "$removal_error" >&2
    return 1
  fi
  # Containers can leave directories owned by root. Mount only the validated path.
  printf 'molt: using Docker to remove protected files in %s\n' "$path" >&2
  if ! { docker run --rm --quiet --network none --label "io.molt.installation=$owner" \
      --mount "type=bind,src=$path,dst=/cleanup" busybox:1.37.0 \
      sh -c 'rm -rf /cleanup/* /cleanup/.[!.]* /cleanup/..?*' && rmdir -- "$path"; }; then
    printf '%s\n' "$removal_error" >&2
    printf 'molt: could not remove %s; retry records retained\n' "$path" >&2
    return 1
  fi
}

case "$action" in
  validate-root)
    if [[ -e "$root/.install-manifest" ]]; then owned;
    elif [[ -d "$root" && -n "$(ls -A "$root")" ]]; then fail "populated unowned remote root: $root";
    elif [[ -e "$root" && ! -d "$root" ]]; then fail 'remote workspace is not a directory'; fi
    printf '%s\n' "$root"
    ;;
  setup)
    command -v docker >/dev/null 2>&1 && docker info >/dev/null || fail 'Docker must already be installed and usable without sudo'
    claim
    printf '%s\n' "$root"
    ;;
  stage-bootstrap)
    claim
    [[ ! -L "$root/state/bootstrap.sh" && ! -L "$root/state/bootstrap.manifest" ]] || fail 'symlinked VM preparation state'
    printf '%s\n' "$root"
    ;;
  bootstrap)
    owned
    distro="$(awk -F= '$1=="ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)"
    [[ "$distro" == ubuntu || "$distro" == debian ]] || fail 'guided Docker preparation supports Ubuntu and Debian'
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      printf 'Docker is already usable.\n'; exit 0
    fi
    [[ ! -L "$root/state/bootstrap.manifest" ]] || fail 'symlinked VM preparation record'
    if ! command -v docker >/dev/null 2>&1; then
      printf 'DOCKER_INSTALLED=1\n' >>"$root/state/bootstrap.manifest"
      as_root apt-get update
      as_root apt-get install -y --no-install-recommends docker.io
    fi
    user="$(id -un)"
    if [[ "$(id -u)" != 0 && " $(id -nG "$user") " != *' docker '* ]]; then
      printf 'DOCKER_GROUP_ADDED=1\n' >>"$root/state/bootstrap.manifest"
      as_root usermod -aG docker "$user"
    fi
    if ! systemctl is-active --quiet docker; then as_root systemctl start docker; fi
    as_root docker info >/dev/null
    printf 'Docker prepared. Reconnecting SSH to apply user access.\n'
    ;;
  unbootstrap)
    owned
    [[ -f "$root/state/bootstrap.manifest" && ! -L "$root/state/bootstrap.manifest" ]] || { printf 'No Docker changes were recorded by molt.\n'; exit 0; }
    if [[ "$(bootstrap_value DOCKER_REMOVED)" != 1 ]] && command -v docker >/dev/null 2>&1; then
      docker info >/dev/null || fail 'Docker unavailable; VM preparation records retained'
      containers="$(docker container ls -aq)"
      volumes="$(docker volume ls -q)"
      [[ -z "$containers" && -z "$volumes" ]] || fail 'Docker contains containers or volumes; remove them before undoing VM preparation'
    fi
    if [[ "$(bootstrap_value DOCKER_INSTALLED)" == 1 && "$(bootstrap_value DOCKER_REMOVED)" != 1 ]]; then
      as_root apt-get remove -y docker.io
      printf 'DOCKER_REMOVED=1\n' >>"$root/state/bootstrap.manifest"
    fi
    if [[ "$(bootstrap_value DOCKER_GROUP_ADDED)" == 1 && " $(id -nG "$(id -un)") " == *' docker '* ]]; then
      as_root gpasswd -d "$(id -un)" docker
    fi
    printf 'Recorded Docker preparation undone. Docker storage is retained.\n'
    ;;
  prepare)
    owned
    id="$1"
    [[ "$id" =~ ^[a-f0-9]{12}$ ]] || fail 'invalid project identity'
    printf '1\n' >"$root/state/docker-resources"
    for directory in "projects/$id" "meta/$id" "cache/$id" "cache/$id/home" "cache/$id/data" "cache/$id/cache" "cache/$id/state" "cache/$id/tmp"; do
      [[ "$(realpath -m -- "$root/$directory")" == "$root/$directory" ]] || fail "symlinked remote project directory: $directory"
      mkdir -p -- "$root/$directory"
    done
    ;;
  config-sync-version|config-sync-stage|config-sync-install)
    owned
    for path in "$root/config" "$root/config/opencode" "$root/state/tmp" "$root/state/opencode-config" "$root/state/opencode-config.previous" "$root/state/opencode-config.lock"; do
      [[ "$(realpath -m -- "$path")" == "$path" ]] || fail 'symlinked OpenCode configuration state'
    done
    if [[ "$action" == config-sync-install ]]; then
      exec 9>"$root/state/opencode-config.lock"
      flock -x 9
    fi
    source_hash=''; revision=none
    if [[ -f "$root/state/opencode-config" ]]; then
      read -r source_hash revision <"$root/state/opencode-config"
      [[ "$source_hash" =~ ^[a-f0-9]{64}$ && "$revision" == opencode-sync.* && "$revision" != *[!a-zA-Z0-9.-]* ]] || fail 'invalid OpenCode configuration state'
    fi
    if [[ "$action" == config-sync-version ]]; then printf '%s\n' "$revision"; exit 0; fi
    if [[ "$action" == config-sync-stage ]]; then mktemp -d "$root/state/tmp/opencode-sync.XXXXXX"; exit 0; fi
    stage="$1"; hash="$2"
    [[ "$stage" == "$root/state/tmp/opencode-sync."* && "${stage##*/}" != *[!a-zA-Z0-9.-]* && -d "$stage" && ! -L "$stage" && "$(realpath -m -- "$stage")" == "$stage" ]] || fail 'invalid OpenCode configuration staging directory'
    trap 'rm -rf -- "$stage"' EXIT
    archive="$stage/config.tar.gz"
    [[ -f "$archive" && ! -L "$archive" && "$hash" =~ ^[a-f0-9]{64}$ && "$(sha256sum "$archive" | cut -d ' ' -f1)" == "$hash" ]] || fail 'OpenCode configuration upload checksum mismatch'
    tar -tzf "$archive" >"$stage/paths"
    while IFS= read -r path; do
      case "$path" in /*|../*|*/../*|*/..) fail 'unsafe OpenCode configuration archive path' ;; esac
    done <"$stage/paths"
    tar -tvzf "$archive" >"$stage/entries"
    while IFS= read -r entry; do
      case "$entry" in -*|d*) ;; *) fail 'OpenCode configuration archive must contain regular files and directories' ;; esac
    done <"$stage/entries"
    mkdir "$stage/files"
    tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$stage/files"
    if [[ "$source_hash" == "$hash" ]] && diff -qr --exclude=node_modules --exclude=package.json --exclude=package-lock.json \
      --exclude=bun.lock --exclude=bun.lockb --exclude=.gitignore "$stage/files" "$root/config/opencode" >/dev/null; then
      printf '%s\n' "$revision"
      exit 0
    fi
    chmod -R go-rwx "$stage/files"
    # Retain Linux dependencies; OpenCode can update them when it loads the new config.
    for file in node_modules package.json package-lock.json bun.lock bun.lockb .gitignore; do
      [[ ! -e "$root/config/opencode/$file" && ! -L "$root/config/opencode/$file" ]] && continue
      [[ "$(realpath -m -- "$root/config/opencode/$file")" == "$root/config/opencode/$file" ]] || fail 'symlinked generated OpenCode dependency'
      [[ -e "$stage/files/$file" ]] || cp -R -- "$root/config/opencode/$file" "$stage/files/$file"
    done
    revision="${stage##*/}"
    printf '%s %s\n' "$hash" "$revision" >"$stage/record"
    remove_path "$root/state/opencode-config.previous"
    mv -- "$root/config/opencode" "$root/state/opencode-config.previous"
    if ! mv -- "$stage/files" "$root/config/opencode"; then
      mv -- "$root/state/opencode-config.previous" "$root/config/opencode"
      fail 'could not install OpenCode configuration'
    fi
    mv -f -- "$stage/record" "$root/state/opencode-config"
    printf '%s\n' "$revision"
    ;;
  config-get|config-stage|config-install)
    owned
    for path in "$root/config/opencode" "$root/config/opencode/opencode.json" "$root/state/tmp"; do
      [[ "$(realpath -m -- "$path")" == "$path" ]] || fail 'symlinked server configuration'
    done
    if [[ "$action" == config-get ]]; then
      if [[ -f "$root/config/opencode/opencode.json" ]]; then cat "$root/config/opencode/opencode.json"; else printf '{}\n'; fi
    elif [[ "$action" == config-stage ]]; then
      mktemp "$root/state/tmp/opencode.XXXXXX"
    else
      file="$1"
      [[ "$file" == "$root/state/tmp/opencode."* && -f "$file" && ! -L "$file" && "$(realpath -m -- "$file")" == "$file" ]] || fail 'invalid server configuration upload'
      chmod 600 "$file"
      mv -f "$file" "$root/config/opencode/opencode.json"
    fi
    ;;
  cleanup)
    id="$1"; container="$2"; image="$3"; project_path="$4"; meta_path="$5"; layout="$6"
    [[ "$id" =~ ^[a-f0-9]{12}$ ]] || fail 'invalid project identity'
    if [[ "$layout" == 2 ]]; then
      owned
      [[ "$container" == "molt-${owner:0:8}-$id" && "$image" == "molt-env-${owner:0:8}-$id:latest" ]] || fail 'invalid owned Docker resource names'
    else
      [[ "$container" == "molt-$id" && "$image" == "molt-env-$id:latest" ]] || fail 'invalid legacy Docker resource names'
    fi
    docker info >/dev/null || fail 'Docker unavailable; cleanup records must be retained'
    failed=0
    containers="$(docker container ls -a --filter "name=^/${container}$" --format '{{.Names}}')" || exit 1
    if [[ -n "$containers" ]]; then
      if [[ "$layout" == 2 ]]; then
        label="$(docker inspect --format '{{ index .Config.Labels "io.molt.installation" }}' "$container")" || exit 1
        [[ "$label" == "$owner" ]] || fail 'container ownership mismatch'
      fi
      docker rm -f "$container" || failed=1
    fi
    if [[ "$layout" != 2 ]]; then
      volumes="$(docker volume ls --filter "name=^molt-cache-${id}$" --format '{{.Name}}')" || exit 1
      [[ -z "$volumes" ]] || docker volume rm "molt-cache-$id" || failed=1
    fi
    # Do not delete bind-mounted files while the container might still be running.
    if [[ "$failed" == 0 ]]; then
      paths=("$project_path" "$meta_path")
      [[ "$layout" != 2 ]] || paths+=("$root/cache/$id")
      for path in "${paths[@]}"; do
        [[ -n "$path" ]] || continue
        [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* && "$(basename "$path")" == "$id" ]] || fail 'invalid recorded project path'
        canonical="$(realpath -m -- "$path")"
        [[ "$canonical" == "$path" && "$canonical" != "$home" && "$home" != "$canonical/"* ]] || fail 'unsafe recorded project path'
        if [[ "$layout" == 2 ]]; then
          case "$path" in "$root/projects/$id"|"$root/meta/$id"|"$root/cache/$id") ;; *) fail 'project path is outside its owned root' ;; esac
        fi
        remove_path "$path" || failed=1
      done
    fi
    images="$(docker image ls --filter "reference=$image" --format '{{.Repository}}:{{.Tag}}')" || exit 1
    if [[ -n "$images" ]]; then
      if [[ "$layout" == 2 ]]; then
        label="$(docker image inspect --format '{{ index .Config.Labels "io.molt.installation" }}' "$image")" || exit 1
        [[ "$label" == "$owner" ]] || fail 'image ownership mismatch'
      fi
      docker image rm "$image" || failed=1
    fi
    if [[ "$layout" == 2 ]]; then
      # Rebuilds can leave earlier images without a tag. Remove only this project's labels.
      images="$(docker image ls -aq --filter "label=io.molt.installation=$owner" --filter "label=io.molt.project=$id")" || exit 1
      for image_id in $images; do
        # Removing a child image can also remove an already-listed untagged parent.
        if docker image inspect "$image_id" >/dev/null 2>&1; then docker image rm "$image_id" || failed=1; fi
      done
      images="$(docker image ls -aq --filter "label=io.molt.installation=$owner" --filter "label=io.molt.project=$id")" || exit 1
      [[ -z "$images" ]] || failed=1
    fi
    exit "$failed"
    ;;
  clean-root|remove-root)
    [[ -e "$root" ]] || exit 0
    owned
    if [[ "$(bootstrap_value DOCKER_REMOVED)" != 1 && !( -f "$root/state/docker-resources" && "$(<"$root/state/docker-resources")" == 0 ) ]]; then
      docker info >/dev/null || fail 'Docker unavailable; remote root record must be retained'
      # Protect against forgotten containers before removing shared state/config.
      containers="$(docker container ls -a --filter "label=io.molt.installation=$owner" --format '{{.Names}}')" || exit 1
      [[ -z "$containers" ]] || fail "owned containers still exist: $containers"
    fi
    for directory in projects meta cache; do
      path="$root/$directory"
      [[ -e "$path" || -L "$path" ]] || continue
      [[ -d "$path" && ! -L "$path" && "$(realpath -m -- "$path")" == "$path" ]] || fail "redirected remote directory: $directory"
      entries="$(ls -A -- "$path")" || fail "could not inspect $path"
      [[ -z "$entries" ]] || fail "untracked files remain in $path"
    done
    # Remove generated files first; ownership and VM preparation records survive failure.
    for path in "$root/"* "$root/".[!.]* "$root/"..?*; do
      [[ -e "$path" || -L "$path" ]] || continue
      case "$path" in "$root/.install-manifest"|"$root/state") continue ;; esac
      remove_path "$path" || exit 1
    done
    for path in "$root/state/"* "$root/state/".[!.]* "$root/state/"..?*; do
      [[ -e "$path" || -L "$path" ]] || continue
      case "$path" in "$root/state/bootstrap.manifest"|"$root/state/docker-resources") continue ;; esac
      remove_path "$path" || exit 1
    done
    [[ "$action" == remove-root ]] || exit 0
    bootstrap_record=''; docker_record=''; has_bootstrap=0; has_resources=0
    if [[ -f "$root/state/bootstrap.manifest" ]]; then has_bootstrap=1; bootstrap_record="$(<"$root/state/bootstrap.manifest")"; fi
    if [[ -f "$root/state/docker-resources" ]]; then has_resources=1; docker_record="$(<"$root/state/docker-resources")"; fi
    if ! { rm -f -- "$root/state/bootstrap.manifest" "$root/state/docker-resources" &&
        { [[ ! -d "$root/state" ]] || rmdir -- "$root/state"; } &&
        rm -f -- "$root/.install-manifest" && rmdir -- "$root"; }; then
      [[ -d "$root" && ! -L "$root" && "$(realpath -m -- "$root")" == "$root" ]] || fail 'remote root changed during removal'
      printf '%s\n' "$owner" >"$root/.install-manifest"
      if [[ "$has_bootstrap" == 1 || "$has_resources" == 1 ]]; then
        mkdir -p -- "$root/state"
        [[ "$has_bootstrap" == 0 ]] || printf '%s\n' "$bootstrap_record" >"$root/state/bootstrap.manifest"
        [[ "$has_resources" == 0 ]] || printf '%s\n' "$docker_record" >"$root/state/docker-resources"
      fi
      fail 'remote root removal failed; retry records retained'
    fi
    ;;
  *) fail "unknown remote action: $action" ;;
esac
