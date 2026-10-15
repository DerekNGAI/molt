#!/usr/bin/env bash
set -euo pipefail
fixture=${MOLT_DEVELOPMENT_FIXTURE:?}
if [[ ${1:-} == ui-action ]]; then
  work=$2
  shift 2
  printf 'Fixture action\n' >"$work/progress"
  exec "$@" >"$work/output" 2>&1
fi
{ printf '%s' "${1:-}"; for arg in "${@:2}"; do printf '\t%s' "$arg"; done; printf '\n'; } >>"$fixture/commands"
case "$*" in
  'config show') printf 'MOLT_ANIMATIONS=0\n' ;;
  'monitor sync') printf '[]\n' ;;
  'connection test '*) exit 0 ;;
  'dev @'*' status --json') /bin/cat "$fixture/status-${2#@}.json" ;;
  'dev @'*' ports --json') /bin/cat "$fixture/ports-${2#@}.json" ;;
  'dev @'*' cache --json') /bin/cat "$fixture/cache-${2#@}.json" ;;
  'dev @'*' shell'|'dev @'*' run test'|'dev @'*' run setup'|'dev @'*' run extra')
    printf 'Fixture terminal ready\n'
    IFS= read -r value
    printf 'Fixture input: %s\n' "$value"
    ;;
  'dev @'*' android prepare-host')
    printf 'Fixture administrator password: '
    stty -echo
    IFS= read -r value
    stty echo
    printf '\nFixture host preparation recorded\n'
    ;;
  'dev @'*' clean-cache --yes --revision '*)
    if [[ -f "$fixture/cache-stale" ]]; then
      cp "$fixture/cache-changed.json" "$fixture/cache-${2#@}.json"
      printf 'Cache inventory changed; preview again\n' >&2
      exit 1
    fi
    printf 'Fixture cache cleanup complete\n'
    ;;
  'dev @'*' android enable')
    [[ ! -f "$fixture/android-ready.json" ]] || cp "$fixture/android-ready.json" "$fixture/status-${2#@}.json"
    printf 'Fixture Android enabled\n'
    ;;
  'dev @'*' android view')
    [[ ! -f "$fixture/viewer-running.json" ]] || cp "$fixture/viewer-running.json" "$fixture/status-${2#@}.json"
    printf 'Fixture viewer launched\n'
    ;;
  'dev @'*)
    if [[ -f "$fixture/hold-action" ]]; then
      printf '%s\n' "$$" >"$fixture/held.pid"
      printf 'Fixture action waiting\n'
      while [[ -f "$fixture/hold-action" ]]; do sleep .1 & wait; done
    fi
    printf 'Fixture completed: %s\n' "$*"
    if [[ -f "$fixture/fail-action" ]]; then printf 'Fixture action failed\n' >&2; exit 1; fi
    ;;
  *) exit 0 ;;
esac
