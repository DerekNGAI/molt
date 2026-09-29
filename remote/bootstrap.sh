#!/usr/bin/env bash
# Host provisioning is intentionally external to molt.
set -euo pipefail
command -v docker >/dev/null 2>&1 && docker info >/dev/null || {
  printf 'molt: install Docker separately and grant your SSH user access, then run molt setup\n' >&2
  exit 1
}
printf 'Docker is usable. Run molt setup on the Mac to create the owned remote root.\n'
