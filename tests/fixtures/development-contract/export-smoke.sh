#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
: "${MOLT_DEVELOPMENT_TEST_BINARY:?supply the current compiled molt-tui}"
DOCKER="${MOLT_DEVELOPMENT_DOCKER:-docker}"
command -v "$DOCKER" >/dev/null 2>&1 || { printf 'BLOCKED: disposable Docker CLI/daemon unavailable\n' >&2; exit 1; }
[[ "${MOLT_DEVELOPMENT_DISPOSABLE_DOCKER:-}" == 1 ]] || { printf 'BLOCKED: designate a disposable Docker daemon\n' >&2; exit 1; }
[[ "$(uname -s)/$(uname -m)" == Linux/aarch64 ]] || { printf 'BLOCKED: native Linux ARM64 is required\n' >&2; exit 1; }
"$DOCKER" info >/dev/null
JOB=molt-remote-development-20261013-c8e72a-01-contracts
IMAGE="molt-$JOB"
VOLUME="$JOB-nix"
BUILDER="$JOB-builder"
RUNTIME="$JOB-smoke"
FIXTURE="$ROOT/tests/fixtures/development-contract"
OUTPUT="$ROOT/artifacts/01-contracts/export"
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || { printf 'BLOCKED: existing export output\n' >&2; exit 1; }
ls -ld "$ROOT/artifacts/01-contracts"
mkdir "$OUTPUT"
mkdir "$OUTPUT/snapshot" "$OUTPUT/output" "$OUTPUT/cache"
cp -R "$FIXTURE/existing/." "$OUTPUT/snapshot/"
cp -R "$FIXTURE/node/." "$OUTPUT/snapshot/"
cp "$FIXTURE/existing/devenv.yaml" "$OUTPUT/devenv.yaml.before"
cp "$OUTPUT/snapshot/devenv.nix" "$OUTPUT/snapshot/devenv.original.nix"
cp "$ROOT/templates/development/molt.nix" "$ROOT/templates/development/menu.mjs" "$OUTPUT/snapshot/"
printf '{ imports = [ ./devenv.original.nix ./molt.nix ]; }\n' >"$OUTPUT/snapshot/devenv.nix"
REVISION="$(sha256sum "$FIXTURE/existing/devenv.nix" "$FIXTURE/existing/environment/node.nix" "$FIXTURE/existing/devenv.yaml" | sha256sum | cut -d ' ' -f 1)"
printf '{"image":"%s","revision":"%s"}\n' "$IMAGE" "$REVISION" >"$OUTPUT/snapshot/molt-build.json"
if "$DOCKER" image inspect "$IMAGE:$REVISION" >/dev/null 2>&1 || "$DOCKER" volume inspect "$VOLUME" >/dev/null 2>&1 || "$DOCKER" container inspect "$BUILDER" >/dev/null 2>&1 || "$DOCKER" container inspect "$RUNTIME" >/dev/null 2>&1; then
  printf 'BLOCKED: existing fixture Docker identity\n' >&2; exit 1
fi
BUILDER_PIN="$("$MOLT_DEVELOPMENT_TEST_BINARY" development-tools artifact "$ROOT/development-tools.lock.json" builder linux arm64 | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const a=JSON.parse(s);console.log(a.image+"@"+a.digest);});')"
"$DOCKER" volume create --label "io.molt.job=$JOB" --label io.molt.task=01-contracts "$VOLUME"
cleanup() {
  local rc=$?
  trap - EXIT
  for name in "$RUNTIME" "$BUILDER"; do
    if [[ "$("$DOCKER" container inspect -f '{{index .Config.Labels "io.molt.job"}}' "$name" 2>/dev/null || true)" == "$JOB" ]]; then
      "$DOCKER" rm -f "$name" >/dev/null || rc=1
    fi
  done
  if [[ "$("$DOCKER" volume inspect -f '{{index .Labels "io.molt.job"}}' "$VOLUME" 2>/dev/null || true)" == "$JOB" ]]; then
    "$DOCKER" volume rm "$VOLUME" >/dev/null || rc=1
  fi
  if [[ -f "$OUTPUT/image.id" ]]; then
    image_id="$(<"$OUTPUT/image.id")"
    [[ "$image_id" =~ ^sha256:[a-f0-9]{64}$ ]] || exit 1
    if [[ "$("$DOCKER" image inspect -f '{{.Id}}' "$IMAGE:$REVISION" 2>/dev/null || true)" == "$image_id" ]]; then
      "$DOCKER" image rm "$IMAGE:$REVISION" >/dev/null || rc=1
    else
      printf 'BLOCKED: exported image identity changed; retained for recovery\n' >&2
      rc=1
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT
timeout 1800 "$DOCKER" run --name "$BUILDER" --label "io.molt.job=$JOB" --label io.molt.task=01-contracts \
  --env 'NIX_CONFIG=extra-substituters = https://devenv.cachix.org
extra-trusted-public-keys = devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=' \
  --mount "type=volume,source=$VOLUME,target=/nix" \
  --mount "type=bind,source=$OUTPUT/snapshot,target=/workspace" \
  --mount "type=bind,source=$OUTPUT/output,target=/output" \
  --mount "type=bind,source=$OUTPUT/cache,target=/molt-cache/development" \
  --workdir /workspace "$BUILDER_PIN" /bin/sh -eu -c '
    ref=github:cachix/devenv/b904dcb51fe48c30db250038241507f60752f222#devenv
    nix --extra-experimental-features "nix-command flakes" run "$ref" -- inputs add nix2container github:nlewo/nix2container/4e83e6724dcb9eb1b3e855426fa4c8cd19f5ce5a --follows nixpkgs
    nix --extra-experimental-features "nix-command flakes" run "$ref" -- inputs add mk-shell-bin github:rrbutani/nix-mk-shell-bin/ff5d8bd4d68a347be5042e2f16caee391cd75887
    nix --extra-experimental-features "nix-command flakes" run "$ref" -- container build molt
    nix --extra-experimental-features "nix-command flakes" run "$ref" -- container copy --registry docker-archive:/output/environment.tar: molt
  '
cmp "$FIXTURE/existing/devenv.nix" "$OUTPUT/snapshot/devenv.original.nix"
cmp "$FIXTURE/existing/environment/node.nix" "$OUTPUT/snapshot/environment/node.nix"
cmp "$FIXTURE/existing/devenv.yaml" "$OUTPUT/devenv.yaml.before"
"$DOCKER" load --input "$OUTPUT/output/environment.tar"
"$DOCKER" image inspect -f '{{.Id}}' "$IMAGE:$REVISION" >"$OUTPUT/image.id"
# This runner stub covers packaging/routing only; persistent services belong to task 99's real check.
mkdir "$OUTPUT/runner"
cat >"$OUTPUT/runner/development.mjs" <<'JS'
import assert from 'node:assert/strict';
assert.deepEqual(process.argv.slice(2, 8), ['--root', '/workspace', '--state', '/molt-cache/development', '--profile', '/molt-meta/development/profile.json']);
console.log(process.argv[8]);
JS
timeout 60 "$DOCKER" run --name "$RUNTIME" --label "io.molt.job=$JOB" --label io.molt.task=01-contracts \
  --user "$(id -u):$(id -g)" \
  --mount "type=bind,source=$OUTPUT/snapshot,target=/workspace" \
  --mount "type=bind,source=$OUTPUT/cache,target=/molt-cache/development" \
  --mount "type=bind,source=$OUTPUT/runner/development.mjs,target=/opt/molt/development.mjs,readonly" \
  "$IMAGE:$REVISION" /bin/bash -eu -c '
    node -e "require(\"node:assert/strict\").equal(process.arch, \"arm64\")"
    fixture-check
    npm test
    test "$(menu --list)" = list
    test "$(menu test)" = run
  '
"$DOCKER" image inspect "$IMAGE:$REVISION"
printf 'PASS: native ARM64 devenv export/activation and disclosed menu stub\n'
