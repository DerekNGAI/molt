#!/usr/bin/env bash
# Linux-only Redroid backend. Check/status never claim paths or prepare the host.
set -euo pipefail
umask 077
action="${1:-}" root="${2:-}" owner="${3:-}" project="${4:-}" pin="${5:-}"
fail() { printf 'molt: %s\n' "$*" >&2; exit 1; }
[[ "$owner" =~ ^[a-f0-9]{32}$ && "$project" =~ ^[a-f0-9]{12}$ && "$root" == /* ]] || fail 'invalid Android identity'
[[ "$(realpath -m -- "$root")" == "$root" && ! -L "$root" && ! -L "$root/.install-manifest" && "$(<"$root/.install-manifest")" == "$owner" ]] || fail 'Android root ownership mismatch'
state="$root/state/development/$project/android"
data="$root/cache/$project/development/android/data"
container="molt-android-${owner:0:8}-$project"
network="$container"
prep="$root/state/android-preparation"
safe() { [[ ! -L "$1" && "$(realpath -m -- "$1")" == "$1" ]] || fail 'redirected Android ownership path'; }
for path in "$state" "$data" "$prep" "$root/state/development"; do safe "$path"; done
case "$action" in
  start|stop|reset|cleanup)
    if [[ -d "$root/state/development" ]]; then
      safe "$root/state/development/android.lock"; exec 8>"$root/state/development/android.lock"; flock -x 8
    fi ;;
esac
value() { local REPLY=''; safe "$state/$1"; [[ ! -f "$state/$1" ]] || IFS= read -r REPLY <"$state/$1"; printf '%s' "$REPLY"; }
record() { safe "$state/$1"; printf '%s\n' "$2" >"$state/$1"; }
owned_state() { [[ ! -d "$state" || "$(value owner)" == "$owner" && "$(value project)" == "$project" ]] || fail 'Android state ownership mismatch'; }
owned_container() {
  local object="${1:-$container}"
  [[ "$(docker inspect -f '{{index .Config.Labels "io.molt.installation"}}' "$object")" == "$owner" && "$(docker inspect -f '{{index .Config.Labels "io.molt.project"}}' "$object")" == "$project" ]] || fail 'Android/workspace container ownership mismatch'
  if [[ "$object" == "$container" ]]; then
    [[ "$(docker inspect -f '{{index .Config.Labels "io.molt.role"}}' "$object")" == android && "$(docker inspect -f '{{.Config.Image}}' "$object")" == "$(value pin)" ]] || fail 'Android role/image mismatch'
  fi
}
exists_container() { docker container ls --all --filter "name=^/${container}$" --format '{{.Names}}'; }
owned_network() {
  [[ "$(docker network inspect -f '{{index .Labels "io.molt.installation"}}' "$network")" == "$owner" && "$(docker network inspect -f '{{index .Labels "io.molt.project"}}' "$network")" == "$project" && "$(docker network inspect -f '{{index .Labels "io.molt.role"}}' "$network")" == android ]] || fail 'Android network ownership mismatch'
}
capability() {
  case "$(uname -m)" in aarch64|arm64) ;; *) printf 'unsupported: Redroid requires native ARM64; Linux ARM AVD/cross-architecture emulation is unavailable\n'; return 1 ;; esac
  [[ "$(getconf PAGESIZE)" == 4096 ]] || { printf 'unsupported: Redroid requires 4KB kernel pages; kernel replacement is refused\n'; return 1; }
  local binder=0 path
  for path in /dev/binder /dev/binderfs/binder; do
    [[ "$(stat -Lc '%F' "$path" 2>/dev/null || true)" == 'character special file' ]] && binder=1
  done
  [[ "$binder" == 1 ]] || { printf 'unsupported: usable Binder devices are absent; inspect Android prepare-host\n'; return 1; }
  grep -q 'memfd_create' /proc/kallsyms || { printf 'unsupported: memfd support cannot be verified on this kernel\n'; return 1; }
  docker info >/dev/null 2>&1 || { printf 'unknown: Docker access unavailable\n'; return 1; }
  printf 'supported: ARM64, 4KB pages, Binder, memfd and Docker; privileged Android shares the host kernel\n'
}
claim() {
  owned_state
  for path in "$root/state/development" "$root/state/development/$project" "$state"; do safe "$path"; mkdir -p -- "$path"; done
  record owner "$owner"; record project "$project"
}
stop_device() {
  owned_state
  if [[ -n "$(exists_container)" ]]; then owned_container; docker stop "$container" >/dev/null || fail 'Android stop failed; data and records retained'; fi
  [[ ! -d "$state" ]] || record desired 0
}
remove_data() {
  owned_state
  [[ ! -e "$data" ]] || [[ "$(value data)" == "$data" ]] || fail 'unrecorded Android data'
  safe "$data"
  if ! rm -rf -- "$data"; then
    local helper
    helper="$("$root/state/development/node/bin/node" -e 'const fs=require("fs");const l=JSON.parse(fs.readFileSync(process.argv[1]));const a=l.artifacts.find(a=>a.role==="builder"&&a.os==="linux"&&a.arch==="arm64");if(!a)process.exit(1);console.log(a.image+"@"+a.digest)' "$root/meta/$project/development/development-tools.lock.json")"
    [[ "$helper" =~ ^[a-z0-9._:/-]+@sha256:[a-f0-9]{64}$ ]] || fail 'invalid private data cleanup helper'
    record data_cleanup_intent 1
    docker run --rm --network none --label "io.molt.installation=$owner" --label "io.molt.project=$project" --label io.molt.role=builder --mount "type=bind,source=$data,target=/cleanup" "$helper" /bin/sh -eu -c 'rm -rf /cleanup/* /cleanup/.[!.]* /cleanup/..?*' || fail 'Android data cleanup failed; retry records retained'
    rmdir -- "$data" || fail 'Android data removal failed'
  fi
}
case "$action" in
  check) capability ;;
  prepare-host)
    # Only an already available module can be loaded. No package or kernel replacement.
    [[ "$(uname -m)" == aarch64 || "$(uname -m)" == arm64 ]] && [[ "$(getconf PAGESIZE)" == 4096 ]] || fail 'native ARM64 with 4KB pages is required; kernel replacement refused'
    grep -q memfd_create /proc/kallsyms || fail 'memfd support unavailable; no host changes made'
    safe "$root/state/android-preparation.lock"; exec 9>"$root/state/android-preparation.lock"; flock -x 9
    if [[ -d /sys/module/binder_linux ]]; then capability; exit $?; fi
    modinfo binder_linux >/dev/null 2>&1 || fail 'Binder module not available for this kernel; kernel replacement refused'
    mkdir -p -- "$prep"; safe "$prep/owner"; printf '%s\n' "$owner" >"$prep/owner"
    safe "$prep/module_intent"; printf 'binder_linux\n' >"$prep/module_intent"
    if [[ "$(id -u)" == 0 ]]; then modprobe binder_linux devices=binder,hwbinder,vndbinder;
    else sudo -- modprobe binder_linux devices=binder,hwbinder,vndbinder; fi
    for field in module_loaded boot devices; do safe "$prep/$field"; done
    printf '1\n' >"$prep/module_loaded"
    cat /proc/sys/kernel/random/boot_id >"$prep/boot"
    cat /sys/module/binder_linux/parameters/devices >"$prep/devices"
    capability
    ;;
  unprepare-host)
    [[ -f "$prep/module_loaded" ]] || exit 0
    for field in owner module_loaded boot devices; do safe "$prep/$field"; done
    [[ "$(<"$prep/owner")" == "$owner" ]] || fail 'foreign Android preparation record'
    [[ -d /sys/module/binder_linux ]] || { rm -f -- "$prep/module_loaded"; exit 0; }
    [[ "$(<"$prep/boot")" == "$(cat /proc/sys/kernel/random/boot_id)" && "$(<"$prep/devices")" == "$(cat /sys/module/binder_linux/parameters/devices)" ]] || fail 'Binder changed since preparation; module and records retained'
    [[ "$(cat /sys/module/binder_linux/refcnt)" == 0 && -z "$(ls -A /sys/module/binder_linux/holders)" ]] || fail 'Binder is in use; module and records retained'
    if [[ "$(id -u)" == 0 ]]; then modprobe -r binder_linux; else sudo -- modprobe -r binder_linux; fi
    rm -f -- "$prep/module_loaded" "$prep/module_intent" "$prep/boot" "$prep/devices" "$prep/owner"
    rmdir -- "$prep"
    ;;
  start)
    capability >&2 || exit 1
    [[ "$pin" =~ ^redroid/redroid:[a-zA-Z0-9._-]+@sha256:[a-f0-9]{64}$ ]] || fail 'locked Android image required'
    if [[ -e "$data" ]]; then owned_state; [[ -d "$state" && "$(value data)" == "$data" ]] || fail 'unrecorded Android data; preserve it before preparing a device'; fi
    claim
    if [[ -n "$(exists_container)" ]]; then owned_container; [[ "$(value pin)" == "$pin" ]] || fail 'Android pin changed; preserve the device and inspect its recorded revision'; fi
    record pin "$pin"; record container "$container"; record network "$network"; record data "$data"; record desired 1
    if [[ -n "$(exists_container)" ]]; then
      owned_container
      [[ "$(docker inspect -f '{{.State.Running}}' "$container")" == true ]] || docker start "$container" >/dev/null
    else
      "$root/state/development/node/bin/node" "$root/state/development/development.mjs" --control image-intent --root "$root" --owner "$owner" --project "$project" "$pin" >/dev/null
      docker pull "$pin" >&2
      "$root/state/development/node/bin/node" "$root/state/development/development.mjs" --control image-acquired --root "$root" --owner "$owner" --project "$project" "$pin" >/dev/null
      if docker network inspect "$network" >/dev/null 2>&1; then owned_network;
      else docker network create --label "io.molt.installation=$owner" --label "io.molt.project=$project" --label io.molt.role=android "$network" >/dev/null; fi
      for path in "$root/cache/$project/development/android" "$data"; do safe "$path"; mkdir -p -- "$path"; done
      docker run -d --name "$container" --privileged --restart unless-stopped --label "io.molt.installation=$owner" --label "io.molt.project=$project" --label io.molt.role=android --network "$network" --publish 127.0.0.1::5555 --mount "type=bind,source=$data,target=/data" "$pin" androidboot.use_memfd=1 androidboot.redroid_gpu_mode=guest >/dev/null || fail 'Android creation failed; intent retained'
    fi
    workspace="molt-${owner:0:8}-$project"; owned_container "$workspace"
    if [[ "$(docker inspect -f "{{index .NetworkSettings.Networks \"$network\"}}" "$workspace")" == '<no value>' ]]; then docker network connect "$network" "$workspace"; fi
    docker exec "$workspace" /opt/molt/workspace-entrypoint /bin/sh -c 'command -v flutter >/dev/null && command -v adb >/dev/null && adb version >/dev/null' || fail 'native Flutter/ADB toolchain unavailable; no cross-architecture SDK fallback'
    port="$(docker port "$container" 5555/tcp)"
    [[ "$port" =~ ^127\.0\.0\.1:([0-9]{1,5})$ ]] || fail 'Android device ADB is not VM loopback'
    port="${BASH_REMATCH[1]}"; record adb_vm_port "$port"
    ready=0
    for attempt in {1..60}; do
      if [[ "$(docker exec "$container" getprop sys.boot_completed)" == 1 && "$(docker exec "$container" getprop init.svc.adbd)" == running ]]; then ready=1; break; fi
      sleep 1
    done
    [[ "$ready" == 1 ]] || { record boot_failed 1; fail 'Android boot timed out; userdata and records retained'; }
    docker exec "$workspace" /opt/molt/workspace-entrypoint adb connect "$container:5555" >/dev/null || fail 'Flutter ADB connection failed'
    record boot_failed 0
    printf 'Android ready on VM loopback:%s; device %s:5555\n' "$port" "$container"
    ;;
  stop) stop_device ;;
  reset) stop_device; remove_data ;;
  logs) owned_state; owned_container; docker logs --tail 200 "$container" >&2 ;;
  status)
    owned_state; enabled=false; status=disabled; reason=''; port=0
    profile="$root/meta/$project/development/profile.json"
    if [[ -f "$profile" && ! -L "$profile" ]]; then
      enabled="$("$root/state/development/node/bin/node" -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1]));console.log(p.android.enabled===true)' "$profile")"
    fi
    if [[ "$enabled" == true ]]; then
      status=stopped
      capability_result="$(capability 2>/dev/null)" || {
        case "$capability_result" in unsupported:*) status=unsupported; reason="${capability_result#unsupported: }" ;; *) status=unknown; reason='Host capability observation unavailable' ;; esac
      }
      if [[ -n "$(exists_container)" ]]; then
        owned_container
        if [[ "$(docker inspect -f '{{.State.Running}}' "$container")" == true ]]; then
          status=starting
          if [[ "$(docker exec "$container" getprop sys.boot_completed)" == 1 && "$(docker exec "$container" getprop init.svc.adbd)" == running ]]; then status=ready; fi
          mapping="$(docker port "$container" 5555/tcp)"
          [[ "$mapping" =~ ^127\.0\.0\.1:([0-9]{1,5})$ ]] || fail 'invalid ADB publication'
          port="${BASH_REMATCH[1]}"
        fi
      fi
    fi
    printf '{"enabled":%s,"state":"%s","reason":"%s","container":"%s","adb_vm_port":%s,"adb_local_port":0,"adb_server_local_port":0,"viewer_state":"closed"}\n' "$enabled" "$status" "$reason" "$container" "$port"
    ;;
  cleanup)
    stop_device
    if [[ -n "$(exists_container)" ]]; then owned_container; docker rm "$container" >/dev/null; fi
    if docker network inspect "$network" >/dev/null 2>&1; then
      owned_network
      workspace="molt-${owner:0:8}-$project"
      if [[ -n "$(docker container ls --all --filter "name=^/${workspace}$" --format '{{.Names}}')" ]]; then
        owned_container "$workspace"
        docker network disconnect "$network" "$workspace" >/dev/null 2>&1 || true
      fi
      docker network rm "$network" >/dev/null || fail 'Android network remains referenced; records retained'
    fi
    remove_data
    if [[ -d "$state" ]]; then owned_state; rm -rf -- "$state"; fi
    ;;
  *) printf 'molt: unknown Android operation\n' >&2; exit 2 ;;
esac
