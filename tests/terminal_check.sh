#!/usr/bin/env bash
# Compare all terminal modes, ignoring Darwin's PENDIN pending-input bookkeeping bit.
snapshot() {
  python3 -c 'import termios; state = termios.tcgetattr(0); state[3] &= ~termios.PENDIN; print(state)'
}
before="$(snapshot)" || exit 1
"$@"
rc=$?
after="$(snapshot)" || exit 1
if [[ "$before" != "$after" ]]; then
  printf 'FAIL: terminal modes changed\nBefore: %s\nAfter: %s\n' "$before" "$after" >&2
  exit 99
fi
exit "$rc"
