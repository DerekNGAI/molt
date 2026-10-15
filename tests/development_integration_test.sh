#!/usr/bin/env bash
# Portable combined entry-point tests. Network/runtime operations use explicit doubles.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
: "${MOLT_DEVELOPMENT_TEST_BINARY:?supply the current compiled molt-tui}"
export MOLT_DEVELOPMENT_SOURCE="$ROOT"
node --test "$ROOT/tests/fixtures/development-integration/cli.test.mjs"
bash "$ROOT/tests/development_tui_test.sh"
