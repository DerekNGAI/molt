#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
node --test "$ROOT/tests/fixtures/development-runtime/runner.test.mjs"
bash "$ROOT/tests/fixtures/development-runtime/cli.sh"
