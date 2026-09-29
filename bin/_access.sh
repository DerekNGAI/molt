#!/usr/bin/env bash
# Only add/remove the exact public key generated for this installation.
set -euo pipefail
umask 077
action="$1"; owner="$2"; alias="$3"; key="$4"
[[ "$owner" =~ ^[a-f0-9]{32}$ && "$alias" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$ ]] || exit 2
[[ "$key" != *[[:cntrl:]]* && "$key" == "ssh-ed25519 "*" molt:$owner:$alias" ]] || exit 2
directory="$HOME/.ssh"; file="$directory/authorized_keys"
[[ ! -L "$directory" && ! -L "$file" ]] || { printf 'molt: symlinked SSH authorization requires manual review\n' >&2; exit 1; }
case "$action" in
  authorize)
    mkdir -p "$directory"
    chmod 700 "$directory"
    if ! grep -Fxq -- "$key" "$file" 2>/dev/null; then printf '%s\n' "$key" >>"$file"; fi
    chmod 600 "$file" ;;
  revoke)
    [[ -f "$file" ]] || exit 0
    grep -Fxq -- "$key" "$file" || exit 0
    tmp="$(mktemp "$directory/authorized_keys.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    MOLT_ACCESS_KEY="$key" awk '$0 != ENVIRON["MOLT_ACCESS_KEY"] { print }' "$file" >"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$file" ;;
  *) exit 2 ;;
esac
