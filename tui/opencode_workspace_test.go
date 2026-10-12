package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestOpenCodeToolProcessHelper(t *testing.T) {
	if os.Getenv("MOLT_TEST_TOOLS_HELPER") != "1" {
		return
	}
	for i, arg := range os.Args {
		if arg != "--" {
			continue
		}
		args := os.Args[i+1:]
		if args[0] == "opencode-tools" {
			os.Exit(runOpenCodeTools(args[1:]))
		}
		if args[0] == "attach-client" {
			os.Exit(runAttachedClient(args[1:]))
		}
	}
	os.Exit(2)
}

func TestOpenCodeWorkspaceUpdateDefersAndPreservesData(t *testing.T) {
	work := t.TempDir()
	home, vm, tools := filepath.Join(work, "home"), filepath.Join(work, "vm"), filepath.Join(work, "tools")
	root, _ := filepath.Abs("..")
	bin := filepath.Join(home, "releases", "test", "bin")
	for _, dir := range []string{bin, vm, tools, filepath.Join(work, "repo"), filepath.Join(home, "state", "tmp")} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	write := func(path, contents string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(contents), 0700); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"molt", "_molt.sh", "_manage.sh", "_docker.sh", "_opencode.sh", "_remote.sh", "_monitor.sh"} {
		data, err := os.ReadFile(filepath.Join(root, "bin", name))
		if err != nil {
			t.Fatal(err)
		}
		write(filepath.Join(bin, name), string(data))
	}
	lockData, _ := os.ReadFile(filepath.Join(root, "tools.lock"))
	write(filepath.Join(home, "releases", "test", "tools.lock"), string(lockData))
	os.Symlink("releases/test/bin", filepath.Join(home, "bin"))
	write(filepath.Join(bin, "molt-tui"), "#!/bin/sh\nexec \"$MOLT_TEST_BINARY\" -test.run=TestOpenCodeToolProcessHelper -- \"$@\"\n")
	write(filepath.Join(tools, "base-client"), "#!/bin/sh\nif [ \"$1\" = --version ]; then printf '1.18.34\\n'; else printf 'client 1.18.34\\n'; fi\n")
	write(filepath.Join(tools, "ssh"), `#!/bin/bash
for arg in "$@"; do [[ "$arg" != -O && "$arg" != -fN ]] || exit 0; done
HOME="$MOLT_TEST_VM" /bin/bash -c "${!#}"
`)
	write(filepath.Join(tools, "mutagen"), `#!/bin/bash
case "$1 ${2:-}" in
  'version ') printf '0.18.1\n' ;;
  'sync list') [[ "$*" == *SessionState* ]] || { [[ ! -f "$MOLT_TEST_VM/sync" ]] || /bin/cat "$MOLT_TEST_VM/sync"; } ;;
  'sync create') while [[ $# -gt 0 ]]; do [[ "$1" != --name ]] || printf '%s\n' "$2" >"$MOLT_TEST_VM/sync"; shift; done ;;
esac
`)
	write(filepath.Join(tools, "curl"), "#!/bin/sh\nprintf '401'\n")
	write(filepath.Join(tools, "docker"), `#!/bin/bash
set -eu
state="$MOLT_TEST_VM"
printf '%s\n' "$*" >>"$state/events"
case "$1 ${2:-}" in
  'info '*) ;;
  'inspect '*)
    [[ -f "$state/container" ]] || exit 1
    case "$*" in
      *State.Running*) /bin/cat "$state/running" ;;
      *io.molt.installation*) printf '%s\n' "$MOLT_INSTALL_ID" ;;
      *io.molt.runtime*) printf 'opencode-5\n' ;;
      *io.molt.config*) /bin/cat "$state/config" ;;
      *io.molt.auth*) /bin/cat "$state/auth" ;;
      *io.molt.opencode*) /bin/cat "$state/version" ;;
      *Image*) /bin/cat "$state/container-image" ;;
    esac ;;
  'image inspect') /bin/cat "$state/image" ;;
  'build '*)
    [[ ! -f "$state/fail-build" ]] || exit 23
    version=1.18.34
    while [[ $# -gt 0 ]]; do [[ "$1" != OPENCODE_VERSION=* ]] || version="${1#*=}"; shift; done
    printf '%s\n' "$version" >"$state/image" ;;
  'run '*)
    : >"$state/container"
    printf 'true\n' >"$state/running"
    cp "$state/image" "$state/container-image"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        io.molt.config=*) printf '%s\n' "${1#*=}" >"$state/config" ;;
        io.molt.auth=*) printf '%s\n' "${1#*=}" >"$state/auth" ;;
        io.molt.opencode=*) printf '%s\n' "${1#*=}" >"$state/version" ;;
      esac
      shift
    done ;;
  'stop '*) printf 'false\n' >"$state/running" ;;
  'start '*) printf 'true\n' >"$state/running" ;;
  'rm '*) rm -f "$state/container" ;;
  'exec '*|'logs '*) ;;
  *) printf 'unexpected Docker operation: %s\n' "$*" >&2; exit 2 ;;
esac
`)
	write(filepath.Join(home, ".install-manifest"), fmt.Sprintf("FORMAT=2\nROOT=%s\nINSTALL_ID=0123456789abcdef0123456789abcdef\nMUTAGEN_BINARY=%s\nOPENCODE_BINARY=%s\nOPENCODE_MANAGED=1\n", home, filepath.Join(tools, "mutagen"), filepath.Join(tools, "base-client")))
	write(filepath.Join(home, "config"), "MOLT_HOST=fixture-vm\nMOLT_REMOTE_HOME='$HOME/molt'\n")
	write(filepath.Join(home, "opencode.password"), "fixture\n")
	var busy atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		version, _ := os.ReadFile(filepath.Join(vm, "version"))
		if user, password, ok := r.BasicAuth(); !ok || user != "opencode" || password != "fixture" {
			w.WriteHeader(401)
			return
		}
		switch r.URL.Path {
		case "/global/health":
			if _, err := os.Stat(filepath.Join(vm, "wrong-health")); err == nil && strings.TrimSpace(string(version)) == "1.19.0" {
				version = []byte("1.18.34")
			}
			json.NewEncoder(w).Encode(map[string]any{"healthy": true, "version": strings.TrimSpace(string(version))})
		case "/experimental/session":
			fmt.Fprint(w, `[{"directory":"/workspace/src"}]`)
		case "/session/status":
			if busy.Load() && r.URL.Query().Get("directory") == "/workspace/src" {
				fmt.Fprint(w, `{"ses_background":{"type":"busy"}}`)
			} else {
				fmt.Fprint(w, `{}`)
			}
		default:
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	endpoint, _ := url.Parse(server.URL)
	env := append(os.Environ(), "MOLT_HOME="+home, "HOME="+work, "MOLT_USER_HOME="+work, "PATH="+tools+":"+os.Getenv("PATH"),
		"MOLT_TEST_VM="+vm, "MOLT_TEST_BINARY="+os.Args[0], "MOLT_TEST_TOOLS_HELPER=1", "OPENCODE_CONFIG_DIR="+filepath.Join(work, "absent-config"), "MOLT_SSH_CONFIG=")
	run := func(args ...string) (string, error) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, filepath.Join(bin, "molt"), args...)
		cmd.Env, cmd.Dir = env, filepath.Join(work, "repo")
		data, err := cmd.CombinedOutput()
		return string(data), err
	}
	command := func(args ...string) string {
		t.Helper()
		data, err := run(args...)
		if err != nil {
			t.Fatalf("molt %v: %v\n%s", args, err, data)
		}
		return data
	}
	if data, err := exec.Command("git", "init", "-q", filepath.Join(work, "repo")).CombinedOutput(); err != nil {
		t.Fatalf("git init: %v %s", err, data)
	}
	command("register", filepath.Join(work, "repo"))
	id := strings.TrimSpace(command("project-id", filepath.Join(work, "repo")))
	project := filepath.Join(home, "projects", id)
	write(filepath.Join(project, "opencode_port"), endpoint.Port()+"\n")
	state, _ := privateOpenCodeDir(home, "releases")
	selectVersion := func(version string) {
		t.Helper()
		write(filepath.Join(home, "state", "opencode", "latest.json"), fmt.Sprintf(`{"version":%q,"checked_at":%d}`, version, time.Now().Unix()))
		if version == "1.19.0" {
			assets := map[string]string{}
			for _, asset := range opencodeAssets {
				assets[asset] = strings.Repeat("a", 64)
			}
			data, _ := json.Marshal(opencodeRelease{Version: version, Assets: assets})
			write(filepath.Join(state, version+".json"), string(data))
			dir, _ := privateOpenCodeDir(home, "clients", version)
			data = []byte("#!/bin/sh\nif [ \"$1\" = --version ]; then printf '1.19.0\\n'; else printf 'client 1.19.0\\n'; fi\n")
			write(filepath.Join(dir, "opencode"), string(data))
			digest := sha256.Sum256(data)
			write(filepath.Join(dir, "opencode.sha256"), hex.EncodeToString(digest[:]))
		}
	}
	selectVersion("1.18.34")
	command("start", "@"+id)
	history := filepath.Join(vm, "molt", "cache", id, "data", "opencode", "history-fixture")
	write(history, "existing session history\n")
	selectVersion("1.19.0")
	busy.Store(true)
	output := command("oc")
	if !strings.Contains(output, "client 1.18.34") {
		t.Fatalf("busy server did not get its matching old client: %s", output)
	}
	version, _ := os.ReadFile(filepath.Join(vm, "version"))
	if strings.TrimSpace(string(version)) != "1.18.34" {
		t.Fatal("busy server was updated")
	}
	busy.Store(false)
	other := filepath.Join(home, "state", "tmp", "client.other")
	os.Mkdir(other, 0700)
	write(filepath.Join(other, "project"), id+"\n")
	write(filepath.Join(other, "parent.pid"), fmt.Sprintf("%d\n", os.Getpid()))
	output = command("oc")
	if !strings.Contains(output, "client 1.18.34") {
		t.Fatalf("attached terminal did not protect its server: %s", output)
	}
	os.RemoveAll(other)
	write(filepath.Join(vm, "fail-build"), "fail")
	output = command("oc")
	if !strings.Contains(output, "client 1.18.34") {
		t.Fatalf("failed image build lost the working pair: %s", output)
	}
	os.Remove(filepath.Join(vm, "fail-build"))
	write(filepath.Join(vm, "wrong-health"), "fail")
	if output, err := run("oc"); err == nil || strings.Contains(output, "client 1.19.0") || !strings.Contains(output, "differs from the selected client version") {
		t.Fatalf("version mismatch allowed attachment: %v %s", err, output)
	}
	os.Remove(filepath.Join(vm, "wrong-health"))
	output = command("oc")
	if !strings.Contains(output, "client 1.19.0") {
		t.Fatalf("idle workspace did not update both ends: %s", output)
	}
	data, _ := os.ReadFile(history)
	if string(data) != "existing session history\n" {
		t.Fatal("update damaged session history")
	}
	backup, _ := os.ReadFile(filepath.Join(project, "opencode_backup"))
	data, err := os.ReadFile(filepath.Join(strings.TrimSpace(string(backup)), "data", "history-fixture"))
	if err != nil || string(data) != "existing session history\n" {
		t.Fatalf("consistent backup missing: %s %v", data, err)
	}
	if _, err := os.Stat(filepath.Join(project, "opencode_pending")); !os.IsNotExist(err) {
		t.Fatal("healthy update remained pending")
	}
}
