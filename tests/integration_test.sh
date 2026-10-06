#!/usr/bin/env bash
# Opt-in: creates a disposable SSH host with its own nested Docker daemon.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DOCKER_BIN="$(command -v docker)"
DOCKER_PATH="$PATH"
docker_test() { PATH="$DOCKER_PATH" "$DOCKER_BIN" "$@"; }
DOCKER=docker_test
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/molt-integration.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
name="molt-integration-$(date +%s)-$$"
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ "$rc" != 0 && "${MOLT_INTEGRATION_KEEP_VM:-0}" == 1 ]]; then
    printf 'Debug SSH/Docker host retained: %s\n' "$name" >&2
  else
    "$DOCKER" rm -fv "$name" >/dev/null 2>&1 || true
    "$DOCKER" image rm "$name" >/dev/null 2>&1 || true
  fi
  if [[ -x "${MOLT_HOME:-}/bin/molt" ]]; then "$MOLT_HOME/bin/molt" local-down || true; fi
  if [[ "$rc" == 0 ]]; then rm -rf "$TMP"; else printf 'Integration failed (exit %s). Artifacts retained: %s\n' "$rc" "$TMP" >&2; fi
  exit "$rc"
}
trap cleanup EXIT
export HOME="$TMP/home" MOLT_HOME="$TMP/home/.molt" PATH="/usr/bin:/bin"
mkdir -p "$HOME" "$TMP/repo"
if [[ -n "${MOLT_INTEGRATION_TOOLS:-}" ]]; then
  export MOLT_MUTAGEN_BINARY="$MOLT_INTEGRATION_TOOLS/mutagen/mutagen"
  export MOLT_OPENCODE_BINARY="$MOLT_INTEGRATION_TOOLS/opencode/opencode"
  [[ ! -x "$MOLT_INTEGRATION_TOOLS/gum/gum" ]] || export MOLT_GUM_BINARY="$MOLT_INTEGRATION_TOOLS/gum/gum"
fi
/bin/bash "$ROOT/install.sh" --non-interactive
ssh-keygen -q -t ed25519 -N '' -f "$MOLT_HOME/state/ssh/id_ed25519"
"$DOCKER" build -t "$name" -f "$ROOT/tests/integration.Dockerfile" "$ROOT/tests"
"$DOCKER" run -d --privileged --name "$name" -e DOCKER_TLS_CERTDIR= \
  --mount "type=bind,src=$MOLT_HOME/state/ssh/id_ed25519.pub,dst=/test-key.pub,readonly" \
  -p 127.0.0.1::22 "$name"
port="$("$DOCKER" inspect --format '{{(index (index .NetworkSettings.Ports "22/tcp") 0).HostPort}}' "$name")"
cat >"$MOLT_HOME/state/ssh/config" <<EOF
Host molt-test
  HostName 127.0.0.1
  Port $port
  User molt-test
  IdentityFile "$MOLT_HOME/state/ssh/id_ed25519"
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
printf '\nMOLT_HOST=molt-test\nMOLT_SSH_CONFIG="%s/state/ssh/config"\n' "$MOLT_HOME" "$MOLT_HOME" >>"$MOLT_HOME/config"
for attempt in {1..30}; do
  if "$DOCKER" exec "$name" docker info >/dev/null 2>&1; then break; fi
  sleep 1
done
"$MOLT_HOME/bin/molt" setup
"$MOLT_HOME/bin/molt" doctor
git -C "$TMP/repo" init -q
printf '{"name":"containment-test"}\n' >"$TMP/repo/package.json"
"$MOLT_HOME/bin/molt" start "$TMP/repo"
[[ ! -e "$TMP/repo/devenv.nix" ]] || fail 'start modified the Mac checkout'
id="$("$MOLT_HOME/bin/molt" project-id "$TMP/repo")"
[[ "$("$DOCKER" exec "$name" cat "/home/molt-test/molt/projects/$id/package.json")" == "$(cat "$TMP/repo/package.json")" ]] || fail 'project did not synchronize'
"$MOLT_HOME/bin/molt" remote-oc "@$id" auth list
"$MOLT_HOME/bin/molt" client auth list
server_port="$(cat "$MOLT_HOME/projects/$id/opencode_port")"
password="$(cat "$MOLT_HOME/opencode.password")"
healthy=0
for attempt in {1..60}; do
  if "$DOCKER" exec "$name" curl -fsS -u "opencode:$password" "http://127.0.0.1:$server_port/global/health"; then healthy=1; break; fi
  sleep 1
done
[[ "$healthy" == 1 ]] || fail 'OpenCode server did not become healthy'
container="$(cat "$MOLT_HOME/projects/$id/container")"
[[ "$("$DOCKER" exec "$name" docker inspect -f '{{.HostConfig.NetworkMode}}' "$container")" == bridge ]] || fail 'container is not network-isolated'
# A server edit must reach the Mac; a one-way replica would erase it.
"$DOCKER" exec "$name" docker exec "$container" sh -c 'printf "edited on server\n" > /workspace/server-edit.txt'
source "$ROOT/bin/_molt.sh"
molt_mutagen sync flush "$container"
[[ "$(cat "$TMP/repo/server-edit.txt")" == 'edited on server' ]] || fail 'remote edits did not synchronize back'
"$DOCKER" exec "$name" docker exec "$container" git -C /workspace status --short
# A previous owned image must also be removed, even after losing its project tag.
"$DOCKER" exec "$name" docker commit "$container" "molt-prior-$id:cleanup-test" >/dev/null
"$MOLT_HOME/bin/molt" stop "$TMP/repo"
# Exercise the real client through the wrapper without requiring interactive input.
# A missing session proves the authenticated attach reached the server after auto-start.
if (cd "$TMP/repo" && "$MOLT_HOME/shims/opencode" --session ses_00000000000000000000000000 >"$TMP/attach.log" 2>&1); then
  fail 'a missing session was unexpectedly accepted'
fi
grep -Eiq 'not.?found|session.*exist' "$TMP/attach.log" || { cat "$TMP/attach.log"; fail 'automatic attachment did not reach the server'; }
[[ "$(cat "$MOLT_HOME/projects/$id/active")" == 1 ]] || fail 'attachment did not auto-start the stopped project'
"$DOCKER" exec "$name" sh -c 'test ! -e /home/molt-test/.mutagen && test ! -e /home/molt-test/.molt && test ! -e /home/molt-test/.config/opencode'
[[ ! -e "$HOME/.mutagen" && ! -e "$HOME/.opencode" && ! -e "$HOME/.config" ]] || fail 'global tool state was created on the Mac'
"$DOCKER" exec "$name" sh -c "mkdir -p /home/molt-test/molt/meta/$id/env/.devenv/protected && touch /home/molt-test/molt/meta/$id/env/.devenv/protected/file && chmod 700 /home/molt-test/molt/meta/$id/env/.devenv/protected"
"$DOCKER" exec "$name" sh -c 'mkdir -p /home/molt-test/molt/config/opencode/node_modules/@opencode-ai/plugin && touch /home/molt-test/molt/config/opencode/node_modules/@opencode-ai/plugin/plugin.d.ts && chmod 700 /home/molt-test/molt/config/opencode/node_modules/@opencode-ai/plugin'
"$MOLT_HOME/bin/molt" stop "$TMP/repo"
"$MOLT_HOME/bin/molt-uninstall" --yes >"$TMP/uninstall.log" 2>&1 || { cat "$TMP/uninstall.log"; fail 'uninstall failed'; }
grep -Fq 'using Docker to remove protected files' "$TMP/uninstall.log" || fail 'uninstall did not recover root-owned files'
grep -Fq '/home/molt-test/molt/config' "$TMP/uninstall.log" || fail 'uninstall did not recover root-owned plugin dependencies'
if grep -Fq 'Permission denied' "$TMP/uninstall.log"; then fail 'successful recovery printed deletion errors'; fi
if grep -Fq 'Started Mutagen daemon' "$TMP/uninstall.log"; then fail 'uninstall restarted Mutagen'; fi
if grep -Fq 'disabling multiplexing' "$TMP/uninstall.log"; then fail 'uninstall raced SSH shutdown'; fi
[[ ! -e "$MOLT_HOME" ]] || fail 'local installation remains'
"$DOCKER" exec "$name" sh -c 'test ! -e /home/molt-test/molt && test -z "$(docker ps -aq --filter label=io.molt.installation)" && test -z "$(docker images -aq --filter label=io.molt.installation)"'
printf 'molt integration tests: ok\n'
