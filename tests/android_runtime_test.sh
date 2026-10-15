#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-android.XXXXXX")"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf -- "$TMP"' EXIT
export ROOT TMP MOLT_HOME="$TMP/home" MOLT_DEVELOPMENT_TEST_BINARY
mkdir -p "$MOLT_HOME/projects/aaaaaaaaaaaa" "$TMP/repo/.molt" "$TMP/remote/state" "$TMP/remote/cache/aaaaaaaaaaaa/development/android/data"
printf 'FORMAT=2\nROOT=%s\nINSTALL_ID=0123456789abcdef0123456789abcdef\n' "$MOLT_HOME" >"$MOLT_HOME/.install-manifest"
printf '0123456789abcdef0123456789abcdef\n' >"$TMP/remote/.install-manifest"
printf '{"version":1,"name":"Android fixture","actions":[],"ports":[],"android":{"enabled":false}}\n' >"$TMP/repo/.molt/development.json"
printf 'user definition\n' >"$TMP/repo/devenv.nix"
checks() {
  source "$ROOT/bin/molt" help >/dev/null
  source "$ROOT/bin/_development.sh"
  source "$ROOT/bin/_android.sh"
  PROJECT_STATE="$MOLT_HOME/projects/aaaaaaaaaaaa" PROJECT_PATH="$TMP/repo" PROJECT_ID=aaaaaaaaaaaa PROJECT_NAME=fixture PROJECT_REMOTE_HOME="$TMP/remote" PROJECT_HOST=fixture-vm MOLT_HOST=fixture-vm
  PROJECT_REMOTE_PATH="$TMP/remote/projects/$PROJECT_ID" PROJECT_REMOTE_META="$TMP/remote/meta/$PROJECT_ID" PROJECT_REMOTE_OPENCODE_CONFIG='' PROJECT_CONTAINER=molt-01234567-aaaaaaaaaaaa PROJECT_IMAGE=molt-env-01234567-aaaaaaaaaaaa:latest PROJECT_SYNC=fixture PROJECT_OPENCODE_PORT=4100 PROJECT_ACTIVE=0 PROJECT_LAYOUT=2 PROJECT_SYNC_CREATED=0 PROJECT_RUNTIME_VERSION="$MOLT_RUNTIME_VERSION" PROJECT_OPENCODE_VERSION=1.18.34 PROJECT_SETUP_STATE=complete
  save_project
  development_tools() { "$MOLT_DEVELOPMENT_TEST_BINARY" development-tools "$@"; }
  flush_project_sync() { :; }
  fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
  android_enable
  [[ "$(development_validate_profile "$PROJECT_PATH/.molt/development.json" | development_json 'return String(value.android.enabled)')" == true ]] || fail 'enable did not promote profile'
  [[ "$(<"$PROJECT_PATH/devenv.nix")" == 'user definition' ]] || fail 'enable rewrote toolchain'
  android_stop() { :; }
  android_stop_viewer() { :; }
  android_disable
  [[ "$(development_validate_profile "$PROJECT_PATH/.molt/development.json" | development_json 'return String(value.android.enabled)')" == false ]] || fail 'disable did not promote profile'
}
bash -c "$(declare -f checks); checks" "$ROOT/bin/molt"
# Read-only host check uses command doubles for Linux's kernel interfaces, not real preparation.
host_check() {
  source "$ROOT/bin/_molt.sh"
  uname() { printf '%s\n' "${TEST_ARCH:-aarch64}"; }
  getconf() { printf '%s\n' "${TEST_PAGE:-4096}"; }
  stat() { if [[ "$*" == *'/dev/binder'* ]]; then [[ "${TEST_BINDER:-1}" == 1 ]] && printf 'character special file\n'; else command stat "$@"; fi; }
  grep() { if [[ "$*" == *'/proc/kallsyms'* ]]; then [[ "${TEST_MEMFD:-1}" == 1 ]]; else command grep "$@"; fi; }
  realpath() { [[ "$1" != -m ]] || shift; [[ "$1" != -- ]] || shift; molt_canonical "$1"; }
  docker() { [[ "$1" == info ]] || { printf 'unexpected mutation\n' >&2; return 90; }; }
  source "$ROOT/remote/android.sh" check "$TMP/remote" 0123456789abcdef0123456789abcdef aaaaaaaaaaaa
}
bash -c "$(declare -f host_check); host_check" >"$TMP/check"
grep -Fq supported "$TMP/check"
for values in 'TEST_ARCH=x86_64' 'TEST_PAGE=16384' 'TEST_BINDER=0' 'TEST_MEMFD=0'; do
  if env "$values" bash -c "$(declare -f host_check); host_check" >"$TMP/check" 2>&1; then printf 'FAIL: unsupported host accepted: %s\n' "$values" >&2; exit 1; fi
  grep -Fq unsupported "$TMP/check"
done
[[ ! -d "$TMP/remote/state/development" ]] || { printf 'FAIL: check created resources\n' >&2; exit 1; }
printf 'PASS: profile promotion and read-only Android capability fixtures (kernel/Docker mocked)\n'
if [[ "$(uname -s)" == Darwin ]]; then bash "$ROOT/tests/fixtures/android-runtime/viewer.sh"; fi
