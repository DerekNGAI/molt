#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
node --test "$ROOT/tests/fixtures/development-runtime/host.test.mjs"
