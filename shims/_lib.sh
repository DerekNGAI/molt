#!/usr/bin/env bash
# Shared by command shims. Decide remote vs local.

worker_bin() {
  if command -v worker >/dev/null 2>&1; then
    command -v worker
    return
  fi
  echo "${WORKER_HOME:-$HOME/.worker}/bin/worker"
}

# Return 0 if this invocation should run in the active project container.
should_remote() {
  local cmd="$1"

  if [[ "${WORKER_LOCAL:-0}" == "1" ]]; then
    return 1
  fi
  "$(worker_bin)" project-active "$PWD" >/dev/null 2>&1 || return 1
  [[ "${WORKER_REMOTE_ALL:-0}" == "1" ]] && return 0

  case "$cmd" in
    opencode|node|python|python3|pytest|pip|pip3|pnpm|npm|yarn|bun|cargo|rustc|go|make|cmake|devenv)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# First real binary after this shim directory.
real_bin() {
  local name="$1"
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  local p
  while IFS= read -r p; do
    case "$p" in
      "$here"/*) continue ;;
    esac
    if [[ -x "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done < <(type -aP "$name" 2>/dev/null)
  return 1
}
