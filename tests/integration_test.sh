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
unset MOLT_SSH_CONFIG MOLT_USER_HOME OPENCODE_CONFIG_DIR
export HOME="$TMP/home" MOLT_HOME="$TMP/home/.molt" PATH="/usr/bin:/bin"
export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state" XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
mkdir -p "$HOME" "$TMP/repo"
if [[ -n "${MOLT_INTEGRATION_TOOLS:-}" ]]; then
  export MOLT_MUTAGEN_BINARY="$MOLT_INTEGRATION_TOOLS/mutagen/mutagen"
  export MOLT_OPENCODE_BINARY="$MOLT_INTEGRATION_TOOLS/opencode/opencode"
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
export OPENCODE_CONFIG_DIR="$TMP/local-opencode"
mkdir -p "$OPENCODE_CONFIG_DIR/commands"
printf '{"$schema":"https://opencode.ai/config.json","model":"openai/gpt-6.1-sol#xhigh",}\n' >"$OPENCODE_CONFIG_DIR/opencode.json"
printf 'Integration instructions\n' >"$OPENCODE_CONFIG_DIR/AGENTS.md"
printf '%s\n' '---' 'description: Integration command' '---' 'Explain the project.' >"$OPENCODE_CONFIG_DIR/commands/explain.md"
mkdir -p "$XDG_DATA_HOME/opencode" "$XDG_STATE_HOME/opencode"
printf '{"openai":{"type":"api","key":"molt-local-fixture"}}\n' >"$XDG_DATA_HOME/opencode/auth.json"
printf '{"recent":[],"favorite":[],"variant":{"openai/gpt-6.1-sol":"xhigh"}}\n' >"$XDG_STATE_HOME/opencode/model.json"
(cd "$TMP" && "$MOLT_HOME/bin/molt" client auth list >"$TMP/local-auth.log")
grep -qi openai "$TMP/local-auth.log" || fail 'local client did not use existing provider credentials'
"$MOLT_HOME/bin/molt" start "$TMP/repo"
[[ ! -e "$TMP/repo/devenv.nix" ]] || fail 'start modified the Mac checkout'
id="$("$MOLT_HOME/bin/molt" project-id "$TMP/repo")"
[[ "$("$DOCKER" exec "$name" cat "/home/molt-test/molt/projects/$id/package.json")" == "$(cat "$TMP/repo/package.json")" ]] || fail 'project did not synchronize'
"$MOLT_HOME/bin/molt" remote-oc "@$id" auth list >"$TMP/remote-auth.log"
grep -Fq '0 credentials' "$TMP/remote-auth.log" || fail 'Mac credentials were copied to the VM'
server_port="$(cat "$MOLT_HOME/projects/$id/opencode_port")"
password="$(cat "$MOLT_HOME/opencode.password")"
healthy=0
[[ "$("$MOLT_HOME/bin/molt" client --version)" == 1.18.34 ]] || fail 'unexpected Mac client version'
for attempt in {1..60}; do
  if "$DOCKER" exec "$name" curl -fsS -u "opencode:$password" "http://127.0.0.1:$server_port/global/health"; then healthy=1; break; fi
  sleep 1
done
[[ "$healthy" == 1 ]] || fail 'OpenCode server did not become healthy'
container="$(cat "$MOLT_HOME/projects/$id/container")"
# Exercise real VM telemetry and Mutagen's public JSON schema.
"$MOLT_HOME/bin/molt" monitor host molt-test >"$TMP/telemetry.txt"
/usr/bin/python3 -c '
import json, sys
lines = open(sys.argv[1]).read().splitlines()
system = next(line.split("\t")[1:] for line in lines if line.startswith("system\t"))
assert len(system) == 11 and int(system[0]) > 0 and int(system[2]) > 0
assert "docker\tready" in lines
containers = [json.loads(line.split("\t", 1)[1]) for line in lines if line.startswith("container\t")]
assert any(c["Names"] == sys.argv[2] and c["State"] == "running" for c in containers)
assert "health\t" + sys.argv[2] + "\tready" in lines
' "$TMP/telemetry.txt" "$container" || fail 'VM telemetry did not report live system, container and server health'
"$MOLT_HOME/bin/molt" monitor sync >"$TMP/sync.json"
/usr/bin/python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert any(x["name"]==sys.argv[2] and not x["paused"] for x in s)' "$TMP/sync.json" "$container" || fail 'Mutagen JSON status did not report the active project'
[[ "$("$DOCKER" exec "$name" docker exec "$container" /opt/opencode/opencode --version)" == 1.18.34 ]] || fail 'VM version differs from the Mac client'
# Provider login/logout is shared; databases and session files stay per repo.
mkdir -p "$TMP/second-repo"
git -C "$TMP/second-repo" init -q
"$MOLT_HOME/bin/molt" start "$TMP/second-repo"
second_id="$("$MOLT_HOME/bin/molt" project-id "$TMP/second-repo")"
second_container="$(cat "$MOLT_HOME/projects/$second_id/container")"
"$DOCKER" exec "$name" docker exec "$second_container" sh -c 'curl -fsS --user "opencode:$(cat /molt-meta/opencode.password)" http://127.0.0.1:4096/provider >/dev/null'
"$DOCKER" exec "$name" docker exec "$container" sh -c 'curl -fsS --user "opencode:$(cat /molt-meta/opencode.password)" -X PUT -H "Content-Type: application/json" --data '\''{"type":"api","key":"molt-shared-fixture"}'\'' http://127.0.0.1:4096/auth/openai >/dev/null'
"$MOLT_HOME/bin/molt" remote-oc "@$second_id" auth list >"$TMP/shared-auth.log"
grep -qi openai "$TMP/shared-auth.log" || fail 'provider login was not shared with the second repo'
"$DOCKER" exec "$name" docker exec "$second_container" sh -c 'curl -fsS --user "opencode:$(cat /molt-meta/opencode.password)" http://127.0.0.1:4096/provider' >"$TMP/shared-provider.json"
/usr/bin/python3 -c 'import json, sys; assert "openai" in json.load(open(sys.argv[1]))["connected"]' "$TMP/shared-provider.json" || fail 'second server retained its unauthenticated provider cache'
"$DOCKER" exec "$name" docker exec "$container" sh -c 'printf "repo-specific session\n" > /molt-cache/data/opencode/session-fixture'
"$DOCKER" exec "$name" docker exec "$second_container" sh -c 'test ! -e /molt-cache/data/opencode/session-fixture' || fail 'session data was shared between repos'
"$MOLT_HOME/bin/molt" stop "$TMP/second-repo"
"$MOLT_HOME/bin/molt" start "$TMP/second-repo"
"$MOLT_HOME/bin/molt" remote-oc "@$second_id" auth list >"$TMP/restarted-auth.log"
grep -qi openai "$TMP/restarted-auth.log" || fail 'shared login did not survive restart'
MOLT_ASSUME_YES=1 "$MOLT_HOME/bin/molt" reset "$TMP/second-repo"
"$MOLT_HOME/bin/molt" remote-oc "@$id" auth list >"$TMP/reset-auth.log"
grep -qi openai "$TMP/reset-auth.log" || fail 'removing a repo deleted shared credentials'
"$DOCKER" exec "$name" docker exec "$container" sh -c 'curl -fsS --user "opencode:$(cat /molt-meta/opencode.password)" -X DELETE http://127.0.0.1:4096/auth/openai >/dev/null'
"$MOLT_HOME/bin/molt" start "$TMP/second-repo"
"$MOLT_HOME/bin/molt" remote-oc "@$second_id" auth list >"$TMP/logged-out-auth.log"
grep -Fq '0 credentials' "$TMP/logged-out-auth.log" || fail 'provider logout was not shared'
MOLT_ASSUME_YES=1 "$MOLT_HOME/bin/molt" reset "$TMP/second-repo"
# Reconnect after logout before measuring reuse with unchanged settings.
"$MOLT_HOME/bin/molt" remote-oc "@$id" auth list
if [[ "$("$DOCKER" exec "$name" cat /home/molt-test/molt/config/opencode/opencode.json)" != "$(cat "$OPENCODE_CONFIG_DIR/opencode.json")" ]]; then
  "$DOCKER" exec "$name" cat /home/molt-test/molt/config/opencode/opencode.json
  fail 'global JSONC configuration did not synchronize'
fi
[[ "$("$DOCKER" exec "$name" cat /home/molt-test/molt/config/opencode/AGENTS.md)" == 'Integration instructions' ]] || fail 'global instructions did not synchronize'
"$DOCKER" exec "$name" docker exec "$container" sh -c 'node --version && npm --version && npx --version'
container_before="$("$DOCKER" exec "$name" docker inspect -f '{{.Id}}' "$container")"
"$MOLT_HOME/bin/molt" remote-oc "@$id" auth list
[[ "$("$DOCKER" exec "$name" docker inspect -f '{{.Id}}' "$container")" == "$container_before" ]] || fail 'unchanged configuration recreated the container'
printf 'Updated integration instructions\n' >"$OPENCODE_CONFIG_DIR/AGENTS.md"
rm "$OPENCODE_CONFIG_DIR/commands/explain.md"
"$MOLT_HOME/bin/molt" remote-oc "@$id" auth list
[[ "$("$DOCKER" exec "$name" docker inspect -f '{{.Id}}' "$container")" != "$container_before" ]] || fail 'configuration updates did not recreate the container'
"$DOCKER" exec "$name" sh -c 'test ! -e /home/molt-test/molt/config/opencode/commands/explain.md'
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
[[ ! -e "$HOME/.mutagen" ]] || fail 'Mutagen created global state on the Mac'
grep -Fq '"openai/gpt-6.1-sol":"xhigh"' "$XDG_STATE_HOME/opencode/model.json" || fail 'attached client lost the saved xhigh preference'
"$DOCKER" exec "$name" sh -c "mkdir -p /home/molt-test/molt/meta/$id/env/.devenv/protected && touch /home/molt-test/molt/meta/$id/env/.devenv/protected/file && chmod 700 /home/molt-test/molt/meta/$id/env/.devenv/protected"
"$DOCKER" exec "$name" sh -c 'mkdir -p /home/molt-test/molt/config/opencode/node_modules/@opencode-ai/plugin && touch /home/molt-test/molt/config/opencode/node_modules/@opencode-ai/plugin/plugin.d.ts && chown -R 0:0 /home/molt-test/molt/config/opencode/node_modules/@opencode-ai/plugin && chmod 700 /home/molt-test/molt/config/opencode/node_modules/@opencode-ai/plugin'
"$MOLT_HOME/bin/molt" stop "$TMP/repo"
"$MOLT_HOME/bin/molt-uninstall" --yes >"$TMP/uninstall.log" 2>&1 || { cat "$TMP/uninstall.log"; fail 'uninstall failed'; }
grep -Fq 'using Docker to remove protected files' "$TMP/uninstall.log" || fail 'uninstall did not recover root-owned files'
grep -Fq '/home/molt-test/molt/config' "$TMP/uninstall.log" || fail 'uninstall did not recover root-owned plugin dependencies'
if grep -Fq 'Permission denied' "$TMP/uninstall.log"; then fail 'successful recovery printed deletion errors'; fi
if grep -Fq 'Started Mutagen daemon' "$TMP/uninstall.log"; then fail 'uninstall restarted Mutagen'; fi
if grep -Fq 'disabling multiplexing' "$TMP/uninstall.log"; then fail 'uninstall raced SSH shutdown'; fi
[[ ! -e "$MOLT_HOME" ]] || fail 'local installation remains'
grep -Fq molt-local-fixture "$XDG_DATA_HOME/opencode/auth.json" || fail 'uninstall removed existing local credentials'
grep -Fq '"openai/gpt-6.1-sol":"xhigh"' "$XDG_STATE_HOME/opencode/model.json" || fail 'uninstall removed saved model preferences'
"$DOCKER" exec "$name" sh -c 'test ! -e /home/molt-test/molt && test -z "$(docker ps -aq --filter label=io.molt.installation)" && test -z "$(docker images -aq --filter label=io.molt.installation)"'
printf 'molt integration tests: ok\n'
