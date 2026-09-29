#!/usr/bin/env bash
# Compatibility entry point: preparation is controlled by the local console.
set -euo pipefail
command -v docker >/dev/null 2>&1 && docker info >/dev/null || {
  printf 'molt: open the local MOLT console and choose Setup / prepare VM to install Docker and configure access\n' >&2
  exit 1
}
printf 'Docker is usable. Run molt setup on the Mac to create the owned remote root.\n'
