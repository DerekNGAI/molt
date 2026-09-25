#!/usr/bin/env bash
# Kept as a manual fallback. The normal path is `molt setup` over SSH.
set -euo pipefail

if command -v apt-get >/dev/null 2>&1; then
  if [[ "$(id -u)" -eq 0 ]]; then SUDO=""; else SUDO=sudo; fi
  $SUDO apt-get update
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y \
    ca-certificates curl git iproute2 procps docker.io
  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl enable --now docker
  fi
  $SUDO usermod -aG docker "$USER" 2>/dev/null || true
else
  echo "molt: automatic bootstrap currently supports Ubuntu/Debian" >&2
  exit 1
fi

mkdir -p "$HOME/molt/projects" "$HOME/molt/meta" "$HOME/.molt" "$HOME/.config/opencode"
printf 'VM ready. Reconnect SSH if Docker group membership was just added.\n'
