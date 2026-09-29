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
    for directory in "projects/$id" "meta/$id" "meta/$id/env" "cache/$id" "cache/$id/home" "cache/$id/data" "cache/$id/cache" "cache/$id/state" "cache/$id/tmp"; do
      [[ "$(realpath -m -- "$root/$directory")" == "$root/$directory" ]] || fail "symlinked remote project directory: $directory"
      mkdir -p -- "$root/$directory"
    done
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
        if ! rm -rf -- "$path"; then
          # Containers can leave directories owned by root; Docker access already
          # permits this narrowly scoped helper. Its base image remains Docker cache.
          docker run --rm --network none --label "io.molt.installation=$owner" \
            --mount "type=bind,src=$path,dst=/cleanup" busybox:1.37.0 \
            sh -c 'rm -rf /cleanup/* /cleanup/.[!.]* /cleanup/..?*' && rmdir -- "$path" || failed=1
        fi
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
    exit "$failed"
    ;;
  remove-root)
    [[ -e "$root" ]] || exit 0
    owned
    if [[ "$(bootstrap_value DOCKER_REMOVED)" != 1 && !( -f "$root/state/docker-resources" && "$(<"$root/state/docker-resources")" == 0 ) ]]; then
      docker info >/dev/null || fail 'Docker unavailable; remote root record must be retained'
      # Protect against forgotten containers before removing shared state/config.
      containers="$(docker container ls -a --filter "label=io.molt.installation=$owner" --format '{{.Names}}')" || exit 1
      [[ -z "$containers" ]] || fail "owned containers still exist: $containers"
    fi
    for directory in projects meta cache; do
      [[ -z "$(ls -A "$root/$directory")" ]] || fail "untracked files remain in $root/$directory"
    done
    rm -rf -- "$root"
    ;;
  *) fail "unknown remote action: $action" ;;
esac
