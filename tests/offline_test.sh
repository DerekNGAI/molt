#!/usr/bin/env bash
# Offline recovery uses disposable local/VM directories and tool doubles.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-offline.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/tools" "$TMP/user" "$TMP/vm"
export HOME="$TMP/user" MOLT_USER_HOME="$TMP/user" PATH="$TMP/tools:$PATH"
export TEST_SSH_LOG="$TMP/ssh.log" TEST_SYNC_LOG="$TMP/sync.log" TEST_VM_HOME="$TMP/vm"
unset MOLT_SSH_CONFIG OPENCODE_CONFIG_DIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME
cat >"$TMP/tools/ssh" <<'SSH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_SSH_LOG"
[[ "${TEST_OFFLINE:-1}" == 0 ]] || exit 255
for arg in "$@"; do [[ "$arg" != -O && "$arg" != -fN ]] || exit 0; done
HOME="$TEST_VM_HOME" /bin/bash -c "${!#}" || exit $?
[[ -z "${TEST_FAIL_REMOTE:-}" || "${!#}" != *"bash -s -- $TEST_FAIL_REMOTE "* ]] || exit 1
SSH
cat >"$TMP/tools/mutagen" <<'MUTAGEN'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_SYNC_LOG"
case "$1 ${2:-}" in
  'sync list') [[ "${TEST_FAIL_SYNC:-0}" == 0 ]] || exit 1; [[ "$*" != *SessionState* ]] || exit 0; [[ ! -f "$MOLT_HOME/session" ]] || /bin/cat "$MOLT_HOME/session" ;;
  'sync terminate') [[ "${TEST_FAIL_SYNC:-0}" == 0 ]] || exit 1; rm -f "$MOLT_HOME/session" ;;
  'sync create') while [[ $# -gt 0 ]]; do if [[ "$1" == --name ]]; then printf '%s\n' "$2" >"$MOLT_HOME/session"; fi; shift; done ;;
  'sync flush'|'sync resume') [[ "${TEST_REJECT_FLUSH:-0}" == 0 ]] || exit 1 ;;
esac
MUTAGEN
cat >"$TMP/tools/docker" <<'DOCKER'
#!/usr/bin/env bash
case "$1" in inspect) exit 1 ;; esac
DOCKER
cat >"$TMP/tools/curl" <<'CURL'
#!/usr/bin/env bash
printf '401'
CURL
cat >"$TMP/tools/opencode" <<'CLIENT'
#!/usr/bin/env bash
if [[ "${!#}" == --hold ]]; then
  if [[ "${TEST_TOUCH_ON_EXIT:-0}" == 1 ]]; then
    trap 'record="$MOLT_HOME/state/remotes/late-change"; mkdir -p "$record"; printf "offline-vm\n" >"$record/host"; printf "/remote/molt\n" >"$record/root"; printf "started\n" >"$record/setup_state"; exit 143' TERM
  fi
  : >"$MOLT_HOME/client.ready"
  sleep 60 & wait
  exit
fi
printf 'local client\n'
CLIENT
cat >"$TMP/tools/molt-tui" <<'CLIENT'
#!/usr/bin/env bash
while [[ "$1" != -- ]]; do shift; done
shift
exec "$@"
CLIENT
chmod +x "$TMP/tools/"*
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
fixture() {
  export MOLT_HOME="$TMP/$1" TEST_OFFLINE=1 TEST_FAIL_REMOTE='' TEST_FAIL_SYNC=0 TEST_REJECT_FLUSH=0
  mkdir -p "$MOLT_HOME/releases/test/bin" "$MOLT_HOME/state/tmp" "$TMP/$1-repo"
  cp "$ROOT/bin/"*.sh "$ROOT/bin/molt" "$MOLT_HOME/releases/test/bin/"
  cp "$TMP/tools/molt-tui" "$MOLT_HOME/releases/test/bin/"
  cp "$ROOT/uninstall.sh" "$MOLT_HOME/releases/test/bin/molt-uninstall"
  cp "$ROOT/tools.lock" "$MOLT_HOME/releases/test/tools.lock"
  ln -s releases/test/bin "$MOLT_HOME/bin"
  printf 'FORMAT=2\nROOT=%s\nINSTALL_ID=0123456789abcdef0123456789abcdef\nMUTAGEN_BINARY=%s\nOPENCODE_BINARY=%s\n' "$MOLT_HOME" "$TMP/tools/mutagen" "$TMP/tools/opencode" >"$MOLT_HOME/.install-manifest"
  printf 'MOLT_HOST=offline-vm\n' >"$MOLT_HOME/config"
  git -C "$TMP/$1-repo" init -q
  MOLT="$MOLT_HOME/bin/molt"
  "$MOLT" register "$TMP/$1-repo" >/dev/null
  ID="$("$MOLT" project-id "$TMP/$1-repo")"
  STATE="$MOLT_HOME/projects/$ID"
  REPO="$TMP/$1-repo"
  : >"$TEST_SSH_LOG"; : >"$TEST_SYNC_LOG"
}
remote_project() {
  printf '/remote/molt\n' >"$STATE/remote_home"
  printf '/remote/molt/projects/%s\n' "$ID" >"$STATE/remote_path"
  printf '/remote/molt/meta/%s\n' "$ID" >"$STATE/remote_meta"
  printf '1\n' >"$STATE/sync_created"
  printf 'two-way-safe\n' >"$STATE/sync_mode"
  cp "$STATE/sync" "$MOLT_HOME/session"
}
test_untouched() (
  fixture untouched
  [[ "$("$MOLT" setup-state)" == untouched && "$("$MOLT" setup-state "@$ID")" == untouched ]] || fail 'registration counted as VM setup'
  if "$MOLT" start "@$ID" >"$TMP/start.log" 2>&1; then fail 'unreachable startup succeeded'; fi
  [[ "$("$MOLT" setup-state)" == untouched ]] || fail 'failed SSH counted as VM changes'
  if (cd "$REPO" && "$MOLT" oc) >"$TMP/attach.log" 2>&1; then fail 'unreachable attachment succeeded'; fi
  grep -Fq 'MOLT_LOCAL=1 opencode' "$TMP/attach.log" || fail 'failed attachment did not explain local recovery'
  : >"$TEST_SSH_LOG"
  MOLT_ASSUME_YES=1 "$MOLT" reset --all
  [[ ! -d "$STATE" && ! -s "$TEST_SSH_LOG" ]] || fail 'untouched removal contacted the VM'
  "$MOLT_HOME/bin/molt-uninstall" --yes >"$TMP/uninstall.log" 2>&1
  [[ ! -d "$MOLT_HOME" && ! -s "$TEST_SSH_LOG" ]] || fail 'untouched uninstall required SSH'
  [[ -d "$REPO/.git" ]] || fail 'removed the Mac checkout'
)
test_local_project() (
  fixture local-project
  remote_project
  [[ "$("$MOLT" setup-state "@$ID")" == started ]] || fail 'legacy resource records appeared untouched'
  printf 'n\n' | "$MOLT" reset --local-only "@$ID" >"$TMP/cancel.log" 2>&1
  [[ -d "$STATE" && -f "$MOLT_HOME/session" && ! -s "$TEST_SSH_LOG" && ! -s "$TEST_SYNC_LOG" ]] || fail 'cancelled local removal changed resources'
  grep -Fq 'WARNING' "$TMP/cancel.log" || fail 'local removal omitted the warning'
  export TEST_REJECT_FLUSH=1
  MOLT_ASSUME_YES=1 "$MOLT" reset "@$ID" --local-only >"$TMP/remove.log" 2>&1
  [[ ! -d "$STATE" && ! -f "$MOLT_HOME/session" && ! -s "$TEST_SSH_LOG" ]] || fail 'offline removal required the VM or left registration/sync'
  if grep -Eq 'sync (flush|resume)' "$TEST_SYNC_LOG"; then fail 'offline removal tried to synchronize'; fi
  [[ "$("$MOLT" setup-state)" != untouched ]] || fail 'forgetting a project erased the VM warning'
  if "$MOLT" project-find "$REPO"; then fail 'removed project still routes to the VM'; fi
  [[ "$("$MOLT" client)" == 'local client' && -d "$REPO/.git" ]] || fail 'offline removal damaged local work'
)
test_local_sync_failure() (
  fixture sync-failure
  remote_project
  export TEST_FAIL_SYNC=1
  if MOLT_ASSUME_YES=1 "$MOLT" reset --local-only "@$ID"; then fail 'failed local sync cleanup succeeded'; fi
  [[ -d "$STATE" && -f "$MOLT_HOME/session" ]] || fail 'failed local cleanup discarded records'
)
test_local_record_containment() (
  fixture record-containment
  remote_project
  local record="$MOLT_HOME/state/remotes/$(printf offline-vm | shasum -a 256 | cut -c1-20)"
  mkdir -p "$record"
  printf 'keep\n' >"$TMP/outside-record"
  ln -s "$TMP/outside-record" "$record/host"
  if MOLT_ASSUME_YES=1 "$MOLT" reset --local-only "@$ID"; then fail 'local removal wrote through a redirected VM record'; fi
  [[ "$(<"$TMP/outside-record")" == keep && -d "$STATE" ]] || fail 'unsafe VM record damaged external data or registration'
)
test_local_project_workers() (
  fixture project-workers
  export TEST_OFFLINE=0
  "$MOLT" start "@$ID" >/dev/null
  "$MOLT" client --hold >"$TMP/local-client.log" 2>&1 &
  local local_client=$! project_client='' attempt ready=0
  trap 'kill "$local_client" ${project_client:+"$project_client"} 2>/dev/null || true; wait 2>/dev/null || true' EXIT
  (cd "$REPO" && "$MOLT" oc --hold) >"$TMP/project-client.log" 2>&1 &
  project_client=$!
  for attempt in {1..100}; do
    for file in "$MOLT_HOME/state/tmp"/client.*/project; do
      [[ ! -f "$file" || "$(<"$file")" != "$ID" ]] || ready=1
    done
    [[ "$ready" == 0 ]] || break
    sleep 0.05
  done
  [[ "$ready" == 1 ]] || fail 'project client did not start'
  export TEST_OFFLINE=1 TEST_REJECT_FLUSH=1
  : >"$TEST_SSH_LOG"; : >"$TEST_SYNC_LOG"
  MOLT_ASSUME_YES=1 "$MOLT" reset --local-only "@$ID"
  if kill -0 "$project_client" 2>/dev/null; then fail 'local project removal left its client running'; fi
  kill -0 "$local_client" 2>/dev/null || fail 'project removal stopped an unrelated local client'
  [[ -d "$TEST_VM_HOME/molt/projects/$ID" && ! -d "$STATE" ]] || fail 'local project removal changed VM files or retained registration'
  if grep -Eq 'sync (flush|resume)' "$TEST_SYNC_LOG"; then fail 'stopping a project client flushed to an unavailable VM'; fi
)
test_local_uninstall() (
  fixture local-uninstall
  remote_project
  printf 'n\n' | "$MOLT_HOME/bin/molt-uninstall" --local-only >"$TMP/uninstall-cancel.log" 2>&1
  [[ -d "$MOLT_HOME" && ! -s "$TEST_SYNC_LOG" ]] || fail 'cancelled uninstall stopped local helpers'
  grep -Fq 'WARNING' "$TMP/uninstall-cancel.log" || fail 'uninstall warning appeared after confirmation'
  "$MOLT_HOME/bin/molt-uninstall" --yes --local-only >"$TMP/local-uninstall.log" 2>&1
  grep -Fq 'WARNING' "$TMP/local-uninstall.log" || fail 'explicit local uninstall omitted the warning'
  [[ ! -d "$MOLT_HOME" && -d "$REPO/.git" && ! -s "$TEST_SSH_LOG" ]] || fail 'local uninstall depended on the VM'
)
test_uninstall_state_change() (
  fixture uninstall-race
  TEST_TOUCH_ON_EXIT=1 "$MOLT" client --hold >"$TMP/race-client.log" 2>&1 &
  local client=$! attempt
  trap 'kill "$client" 2>/dev/null || true; wait 2>/dev/null || true' EXIT
  for attempt in {1..100}; do [[ ! -f "$MOLT_HOME/client.ready" ]] || break; sleep 0.05; done
  [[ -f "$MOLT_HOME/client.ready" ]] || fail 'late-change client did not start'
  printf 'y\n' | "$MOLT_HOME/bin/molt-uninstall" --local-only >"$TMP/race-uninstall.log" 2>&1
  [[ -d "$MOLT_HOME" ]] || fail 'uninstall discarded VM changes recorded after its first confirmation'
  grep -Fq 'WARNING' "$TMP/race-uninstall.log" || fail 'late VM changes did not trigger a warning'
  "$MOLT_HOME/bin/molt-uninstall" --yes --local-only >/dev/null 2>&1
  [[ ! -d "$MOLT_HOME" ]] || fail 'explicit acceptance did not remove the installation'
)
test_ui_uninstall_state_change() (
  fixture ui-uninstall-race
  TEST_TOUCH_ON_EXIT=1 "$MOLT" client --hold >"$TMP/ui-race-client.log" 2>&1 &
  local client=$! attempt
  trap 'kill "$client" 2>/dev/null || true; wait 2>/dev/null || true' EXIT
  for attempt in {1..100}; do [[ ! -f "$MOLT_HOME/client.ready" ]] || break; sleep 0.05; done
  [[ -f "$MOLT_HOME/client.ready" ]] || fail 'late-change UI client did not start'
  if MOLT_UI_BATCH=1 "$MOLT_HOME/bin/molt-uninstall" --yes --local-only >"$TMP/ui-race-uninstall.log" 2>&1; then fail 'UI silently accepted VM changes after its confirmation'; fi
  [[ -d "$MOLT_HOME" ]] || fail 'UI uninstall discarded late VM changes'
  grep -Fq 'retry local-only removal' "$TMP/ui-race-uninstall.log" || fail 'UI did not explain how to review the new warning'
  MOLT_UI_BATCH=1 "$MOLT_HOME/bin/molt-uninstall" --yes --local-only >/dev/null 2>&1
  [[ ! -d "$MOLT_HOME" ]] || fail 'UI confirmation could not proceed after reviewing VM changes'
)
test_mixed_reset_all() (
  fixture mixed-projects
  remote_project
  local other="$TMP/untouched-other" other_id
  mkdir -p "$other"
  git -C "$other" init -q
  "$MOLT" register "$other" >/dev/null
  other_id="$("$MOLT" project-id "$other")"
  if MOLT_ASSUME_YES=1 "$MOLT" reset --all; then fail 'remote cleanup succeeded while SSH was offline'; fi
  [[ -d "$STATE" && ! -d "$MOLT_HOME/projects/$other_id" ]] || fail 'one unreachable project blocked untouched project removal or lost retry records'
  : >"$TEST_SSH_LOG"
  MOLT_ASSUME_YES=1 "$MOLT" reset --all --local-only
  [[ ! -d "$STATE" && ! -s "$TEST_SSH_LOG" ]] || fail 'local reset-all required SSH or retained registration'
)
test_vm_and_key_records() (
  fixture vm-record
  local record="$MOLT_HOME/state/remotes/recorded"
  mkdir -p "$record"
  printf 'other-vm\n' >"$record/host"
  printf '/remote/molt\n' >"$record/root"
  [[ "$("$MOLT" setup-state "@$ID")" == untouched && "$("$MOLT" setup-state)" != untouched ]] || fail 'VM/project setup states were conflated'
  MOLT_ASSUME_YES=1 "$MOLT" reset "@$ID"
  [[ ! -s "$TEST_SSH_LOG" ]] || fail 'untouched project required its prepared VM'
  rm -rf "$record"
  mkdir -p "$MOLT_HOME/state/ssh/profiles/key-vm"
  printf 'fixture public key\n' >"$MOLT_HOME/state/ssh/profiles/key-vm/authorized"
  [[ "$("$MOLT" setup-state)" != untouched ]] || fail 'SSH authorization appeared untouched'
)
test_setup_transitions() (
  fixture transitions
  export TEST_OFFLINE=0 TEST_FAIL_REMOTE=stage-bootstrap
  if "$MOLT" bootstrap; then fail 'partial bootstrap succeeded'; fi
  local record="$MOLT_HOME/state/remotes/$(printf offline-vm | shasum -a 256 | cut -c1-20)"
  [[ "$(<"$record/setup_state")" == started && -f "$TEST_VM_HOME/molt/.install-manifest" ]] || fail 'partial VM setup was not recorded'
  export TEST_FAIL_REMOTE=prepare
  if "$MOLT" start "@$ID"; then fail 'partial project setup succeeded'; fi
  [[ "$(<"$STATE/setup_state")" == started && "$(<"$record/setup_state")" == complete ]] || fail 'partial project setup lost setup states'
  export TEST_FAIL_REMOTE=''
  "$MOLT" start "@$ID"
  [[ "$(<"$STATE/setup_state")" == complete && "$("$MOLT" setup-state "@$ID")" == complete ]] || fail 'successful project setup was not recorded'
)
for test in ${*:-test_untouched test_local_project test_local_sync_failure test_local_record_containment test_local_uninstall test_uninstall_state_change test_ui_uninstall_state_change test_mixed_reset_all test_vm_and_key_records test_setup_transitions test_local_project_workers}; do
  "$test"
  printf 'PASS: %s\n' "$test"
done
