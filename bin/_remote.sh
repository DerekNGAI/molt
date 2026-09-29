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
}

case "$action" in
  setup)
    command -v docker >/dev/null 2>&1 && docker info >/dev/null || fail 'Docker must already be installed and usable without sudo'
    if [[ -e "$root/.install-manifest" ]]; then owned;
    elif [[ -d "$root" && -n "$(ls -A "$root")" ]]; then fail "populated unowned remote root: $root";
    else
      mkdir -p -- "$root"
      printf '%s\n' "$owner" >"$root/.install-manifest"
    fi
    for directory in projects meta config config/opencode cache state state/home state/home/.mutagen state/tmp; do
      [[ "$(realpath -m -- "$root/$directory")" == "$root/$directory" ]] || fail "symlinked remote directory: $directory"
    done
    mkdir -p -- "$root/"{projects,meta,config/opencode,cache,state/home,state/tmp}
    printf '%s\n' "$root"
    ;;
  prepare)
    owned
    id="$1"
    [[ "$id" =~ ^[a-f0-9]{12}$ ]] || fail 'invalid project identity'
    for directory in "projects/$id" "meta/$id" "meta/$id/env" "cache/$id" "cache/$id/home" "cache/$id/data" "cache/$id/cache" "cache/$id/state" "cache/$id/tmp"; do
      [[ "$(realpath -m -- "$root/$directory")" == "$root/$directory" ]] || fail "symlinked remote project directory: $directory"
      mkdir -p -- "$root/$directory"
    done
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
    docker info >/dev/null || fail 'Docker unavailable; remote root record must be retained'
    # Protect against forgotten containers before removing shared state/config.
    containers="$(docker container ls -a --filter "label=io.molt.installation=$owner" --format '{{.Names}}')" || exit 1
    [[ -z "$containers" ]] || fail "owned containers still exist: $containers"
    for directory in projects meta cache; do
      [[ -z "$(ls -A "$root/$directory")" ]] || fail "untracked files remain in $root/$directory"
    done
    rm -rf -- "$root"
    ;;
  *) fail "unknown remote action: $action" ;;
esac
