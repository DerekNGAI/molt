#!/usr/bin/env bash
# Small, bounded, read-only probe for Ubuntu/Debian. Tagged JSON for Docker.
set -uo pipefail
installation="${1:?installation ID required}"
[[ "$installation" =~ ^[a-f0-9]{32}$ ]] || exit 2
cpu="$(awk '/^cpu / {for(i=2;i<=9;i++) total+=$i; printf "%.0f\t%.0f",total,$5+$6; exit}' /proc/stat)"
memory="$(awk '/^MemTotal:/ {total=$2} /^MemAvailable:/ {available=$2} END {printf "%d\t%d",total,available}' /proc/meminfo)"
disk="$(df -Pk "$HOME" | awk 'END {printf "%s\t%s",$2,$3}')"
uptime="$(cut -d' ' -f1 /proc/uptime)"
load="$(cut -d' ' -f1-3 /proc/loadavg)"
network="$(awk -F '[: ]+' '!/lo:|veth|docker|br-/ && /:/ {rx+=$3; tx+=$11} END {printf "%.0f\t%.0f",rx,tx}' /proc/net/dev)"
model="$(awk -F ': *' '/model name|Hardware/ {print $2; exit}' /proc/cpuinfo)"
printf 'system\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$cpu" "$memory" "$disk" "$uptime" "$load" "$network" "${model:-$(uname -m)}"
printf 'identity\t%s\n' "$(hostname)"
if ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1; then
  printf 'docker\tunavailable\n'; exit 0
fi
if ! containers="$(docker ps -a --filter "label=io.molt.installation=$installation" --format '{{json .}}' 2>/dev/null)"; then
  printf 'docker\tunavailable\n'; exit 0
fi
printf 'docker\tready\n'
while IFS= read -r line; do [[ -z "$line" ]] || printf 'container\t%s\n' "$line"; done <<<"$containers"
running="$(docker ps --filter "label=io.molt.installation=$installation" --format '{{.Names}}')"
if [[ -n "$running" ]]; then
  # Docker generates these names (no shell expansion or remote user input).
  while IFS= read -r line; do printf 'stats\t%s\n' "$line"; done < <(docker stats --no-stream --format '{{json .}}' $running 2>/dev/null)
  while IFS= read -r name; do
    (
      if docker exec "$name" sh -c 'curl -q --noproxy "*" -fsS --max-time 1 --user "opencode:$(cat /molt-meta/opencode.password)" http://127.0.0.1:4096/global/health >/dev/null' 2>/dev/null; then
        printf 'health\t%s\tready\n' "$name"
      else printf 'health\t%s\tunhealthy\n' "$name"; fi
    ) &
  done <<<"$running"
  wait
fi
