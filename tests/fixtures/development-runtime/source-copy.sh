#!/usr/bin/env bash
# Installation fixtures need a source sibling, keeping all outputs inside the task artifact root.
development_test_source_copy() {
  case "$TMP" in "$ROOT/"*) ;; *) return 0 ;; esac
  local original="$ROOT" path
  mkdir "$TMP/source"
  for path in bin remote shims macos templates tui tests install.sh uninstall.sh config.example tools.lock development-tools.lock.json; do
    [[ ! -e "$original/$path" ]] || cp -R -- "$original/$path" "$TMP/source/$path"
  done
  ROOT="$TMP/source"
}

development_test_linux_tools() {
  [[ "$(uname -s)" == Darwin ]] || return 0
  local directory="$1"
  mkdir -p "$directory"
  {
    printf '#!/usr/bin/env bash\nsource %q\n' "$ROOT/bin/_molt.sh"
    printf '[[ "${1:-}" != -m ]] || shift\n[[ "${1:-}" != -- ]] || shift\nmolt_canonical "$1"\n'
  } >"$directory/realpath"
  printf '#!/usr/bin/env bash\nexec /usr/bin/shasum -a 256 "$@"\n' >"$directory/sha256sum"
  # These VM transport fixtures execute sequentially; the feature tests exercise real locks.
  printf '#!/usr/bin/env bash\nexit 0\n' >"$directory/flock"
  cat >"$directory/tar" <<'TAR'
#!/usr/bin/env bash
# GNU tar pads both regular-file and pipe archives to 20 blocks.
args=(-b 20)
for arg in "$@"; do
  [[ "$arg" != --format=gnu ]] || arg=--format=gnutar
  args+=("$arg")
done
exec /usr/bin/tar "${args[@]}"
TAR
  chmod +x "$directory/realpath" "$directory/sha256sum" "$directory/flock" "$directory/tar"
}
