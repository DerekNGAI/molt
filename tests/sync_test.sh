#!/usr/bin/env bash
# Real archives and CLI helpers, isolated Mac/VM directories and transport doubles.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-sync.XXXXXX")"
cleanup() {
  if [[ -x "${MOLT_HOME:-}/bin/molt" ]]; then "$MOLT_HOME/bin/molt" local-down >/dev/null 2>&1 || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/vm" "$TMP/repo"
GO_BIN="$(command -v go)"
"$GO_BIN" -C "$ROOT/tui" build -trimpath -o "$TMP/molt-tui" .
unset MOLT_SSH_CONFIG MOLT_USER_HOME OPENCODE_CONFIG_DIR
export HOME="$TMP/home" MOLT_HOME="$TMP/home/.molt" SYNC_VM_HOME="$TMP/vm" SYNC_TMP="$TMP"
export MOLT_MUTAGEN_BINARY="$TMP/bin/mutagen" MOLT_OPENCODE_BINARY="$TMP/bin/opencode" MOLT_TUI_BINARY="$TMP/molt-tui"
cat >"$TMP/bin/opencode" <<'TOOL'
#!/usr/bin/env bash
printf '1.18.34\n'
TOOL
cat >"$TMP/bin/ssh" <<'SSH'
#!/usr/bin/env bash
for arg in "$@"; do [[ "$arg" != -O && "$arg" != -fN ]] || exit 0; done
if [[ -f "$SYNC_TMP/fail-upload" && "${!#}" == 'cat > '*'/replacement.tar' ]]; then
  HOME="$SYNC_VM_HOME" /bin/bash -c "${!#}" <<< 'interrupted archive'
  exit 1
fi
HOME="$SYNC_VM_HOME" /bin/bash -c "${!#}"
SSH
cat >"$TMP/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  'info '*) ;;
  'inspect '*)
    if [[ "$*" == *State.Running* ]]; then
      if [[ -f "$SYNC_TMP/running" ]]; then printf 'true\n'; else printf 'false\n'; fi
    elif [[ -f "$SYNC_TMP/wrong-owner" ]]; then printf 'other-installation\n';
    else printf '%s\n' "$MOLT_INSTALL_ID"; fi ;;
  'stop '*) rm -f "$SYNC_TMP/running"; touch "$SYNC_TMP/stopped" ;;
  'container ls'|'image ls'|'volume ls'|'rm '*|'image rm') ;;
  *) exit 1 ;;
esac
DOCKER
cat >"$TMP/bin/mutagen" <<'MUTAGEN'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOLT_SYNC_REAL_MUTAGEN:-}" ]]; then
  [[ "$*" != 'sync flush'* || ! -f "$SYNC_TMP/fail-cycle" ]] || exit 1
  exec "$MOLT_SYNC_REAL_MUTAGEN" "$@"
fi
if [[ "$*" == version ]]; then printf '0.18.1\n'; exit 0; fi
conflict=0
diff -qr -- "$SYNC_TMP/repo/$SYNC_PATH" "$SYNC_REMOTE/$SYNC_PATH" >/dev/null 2>&1 || conflict=1
case "$*" in
  version) printf '0.18.1\n' ;;
  'sync list'*)
    if [[ "$*" == *'json .'* ]]; then
      python3 - "$SYNC_SESSION" "$SYNC_PATH" "$conflict" <<'PY'
import json, sys
name, path, conflict = sys.argv[1:]
print(json.dumps([dict(name=name, status='watching', alpha=dict(connected=True), beta=dict(connected=True), conflicts=[dict(root=path)] if conflict=='1' else [])]))
PY
    elif [[ "$*" == *SessionState* ]]; then [[ "$conflict" == 0 ]] || printf 'blocked\n';
    else printf '%s\n' "$SYNC_SESSION"; fi ;;
  'sync pause'*) touch "$SYNC_TMP/paused" ;;
  'sync resume'*) rm -f "$SYNC_TMP/paused" ;;
  'sync flush'*) [[ ! -f "$SYNC_TMP/paused" && ! -f "$SYNC_TMP/fail-cycle" ]] ;;
  'sync terminate'*) ;;
esac
MUTAGEN
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$(dirname "$GO_BIN"):/usr/bin:/bin"
/bin/bash "$ROOT/install.sh" --non-interactive >/dev/null
git -C "$TMP/repo" init -q
"$MOLT_HOME/bin/molt" config set MOLT_HOST sync-vm
"$MOLT_HOME/bin/molt" register "$TMP/repo" >/dev/null
id="$("$MOLT_HOME/bin/molt" project-id "$TMP/repo")"
state="$MOLT_HOME/projects/$id"
export SYNC_SESSION="$(<"$state/sync")" SYNC_REMOTE="$TMP/vm/molt/projects/$id" SYNC_PATH=file.txt
mkdir -p "$SYNC_REMOTE" "$TMP/vm/molt/state/tmp" "$TMP/vm/molt/meta/$id"
owner="$(/usr/bin/awk -F= '$1=="INSTALL_ID" {print $2}' "$MOLT_HOME/.install-manifest")"
printf '%s\n' "$owner" >"$TMP/vm/molt/.install-manifest"
printf '%s\n' "$TMP/vm/molt" >"$state/remote_home"
printf '%s\n' "$SYNC_REMOTE" >"$state/remote_path"
printf '%s\n' "$TMP/vm/molt/meta/$id" >"$state/remote_meta"
printf 'complete\n' >"$state/setup_state"
printf '1\n' >"$state/sync_created"
printf 'two-way-safe\n' >"$state/sync_mode"
printf 'Deleted on the selected side\n' >"$SYNC_REMOTE/deleted.txt"
"$MOLT_HOME/bin/molt" sync-endpoint "@$id" read deleted.txt >"$TMP/deleted.tar"
deleted_hash="$(shasum -a 256 "$TMP/deleted.tar" | cut -d ' ' -f1)"
"$MOLT_HOME/bin/molt" sync-endpoint "@$id" write deleted.txt "$deleted_hash" </dev/null
[[ ! -e "$SYNC_REMOTE/deleted.txt" ]] || { printf 'FAIL: VM deletion choice was rolled back\n' >&2; exit 1; }
source "$ROOT/bin/_molt.sh"
if [[ -n "${MOLT_SYNC_REAL_MUTAGEN:-}" ]]; then
  molt_mutagen daemon start
  molt_mutagen sync create --name "$SYNC_SESSION" --mode two-way-safe "$TMP/repo" "$SYNC_REMOTE"
  molt_mutagen sync flush "$SYNC_SESSION"
fi
conflict_round=0
make_conflict() {
  conflict_round=$((conflict_round + 1))
  if [[ -n "${MOLT_SYNC_REAL_MUTAGEN:-}" ]]; then molt_mutagen sync pause "$SYNC_SESSION"; fi
  printf 'Mac version %s\n' "$conflict_round" >"$TMP/repo/file.txt"
  printf 'VM version %s\n' "$conflict_round" >"$SYNC_REMOTE/file.txt"
  if [[ -n "${MOLT_SYNC_REAL_MUTAGEN:-}" ]]; then molt_mutagen sync resume "$SYNC_SESSION"; molt_mutagen sync flush "$SYNC_SESSION"; fi
}
preview() {
  "$MOLT_HOME/bin/molt" sync-preview "@$id" "$SYNC_PATH" >"$TMP/preview.json"
  backup="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Directory"])' "$TMP/preview.json")"
}
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for side in mac vm; do
  make_conflict
  preview
  if [[ "$side" == mac ]]; then touch "$TMP/running"; fi
  "$MOLT_HOME/bin/molt" sync-resolve "@$id" "$backup" "$side"
  cmp -s "$TMP/repo/file.txt" "$SYNC_REMOTE/file.txt" || fail 'resolution did not align endpoints'
  [[ -s "$backup/mac.tar" && -s "$backup/vm.tar" && ! -f "$TMP/paused" ]] || fail 'resolution lost backups or left sync paused'
  if [[ "$side" == mac ]]; then /usr/bin/grep -q Mac "$SYNC_REMOTE/file.txt" || fail 'wrong winner';
  else /usr/bin/grep -q VM "$TMP/repo/file.txt" || fail 'wrong winner'; fi
done
make_conflict
preview
touch "$TMP/running" "$TMP/wrong-owner"
if "$MOLT_HOME/bin/molt" sync-resolve "@$id" "$backup" vm; then fail 'stopped another installation container'; fi
rm "$TMP/wrong-owner"
[[ -f "$TMP/running" && -f "$TMP/stopped" ]] || fail 'container ownership or writer shutdown was ignored'
cmp -s "$TMP/repo/file.txt" "$SYNC_REMOTE/file.txt" && fail 'ownership failure changed a conflict'
printf 'New local edit\n' >"$TMP/repo/file.txt"
if "$MOLT_HOME/bin/molt" sync-resolve "@$id" "$backup" vm; then fail 'overwrote a new local edit'; fi
/usr/bin/grep -q 'New local edit' "$TMP/repo/file.txt" || fail 'lost a local edit'
/usr/bin/grep -q 'VM version' "$SYNC_REMOTE/file.txt" || fail 'changed the VM on a stale choice'
[[ ! -f "$TMP/paused" ]] || fail 'failed resolution left sync paused'
preview
touch "$TMP/fail-upload"
if "$MOLT_HOME/bin/molt" sync-resolve "@$id" "$backup" mac; then fail 'upload failure succeeded'; fi
rm "$TMP/fail-upload"
/usr/bin/grep -q 'VM version' "$SYNC_REMOTE/file.txt" || fail 'failed upload changed the VM'
[[ -f "$state/path" && -s "$backup/vm.tar" ]] || fail 'failed upload lost recovery data'
# A successful replacement followed by a sync failure must retain backups and records.
touch "$TMP/fail-cycle"
if "$MOLT_HOME/bin/molt" sync-resolve "@$id" "$backup" mac; then fail 'failed synchronization was reported as complete'; fi
rm "$TMP/fail-cycle"
[[ -f "$state/path" && -s "$backup/vm.tar" ]] || fail 'failed flush lost recovery data'
# Grouped Git metadata is backed up in full, including the version losing the choice.
export SYNC_PATH=.git/index
if [[ -n "${MOLT_SYNC_REAL_MUTAGEN:-}" ]]; then molt_mutagen sync pause "$SYNC_SESSION"; fi
mkdir -p "$SYNC_REMOTE/.git"
printf 'Mac index\n' >"$TMP/repo/.git/index"
printf 'VM index\n' >"$SYNC_REMOTE/.git/index"
if [[ -n "${MOLT_SYNC_REAL_MUTAGEN:-}" ]]; then molt_mutagen sync resume "$SYNC_SESSION"; molt_mutagen sync flush "$SYNC_SESSION"; fi
"$MOLT_HOME/bin/molt" sync-preview "@$id" .git >"$TMP/preview.json"
backup="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Directory"])' "$TMP/preview.json")"
"$MOLT_HOME/bin/molt" sync-resolve "@$id" "$backup" mac
cmp -s "$TMP/repo/.git/index" "$SYNC_REMOTE/.git/index" || fail 'Git group choice was not applied'
tar -tf "$backup/mac.tar" | /usr/bin/grep -q '.git/HEAD' || fail 'Git backup lost non-conflicting metadata'
# Project removal leaves durable snapshots available.
export SYNC_PATH=file.txt
make_conflict
"$MOLT_HOME/bin/molt" config set MOLT_ANIMATIONS 0
export TERM=xterm-256color
/usr/bin/expect "$ROOT/tests/sync_test.exp"
grep -q 'VM version' "$TMP/repo/file.txt" || fail 'TUI applied the wrong choice'
[[ ! -d "$state" && -s "$backup/mac.tar" && -s "$backup/vm.tar" ]] || fail 'removal discarded backups'
printf 'molt synchronization recovery tests: ok\n'
