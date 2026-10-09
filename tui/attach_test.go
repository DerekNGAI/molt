package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/creack/pty"
)

func TestAttachProcessHelper(t *testing.T) {
	if os.Getenv("MOLT_TEST_ATTACH") != "1" {
		return
	}
	for i, arg := range os.Args {
		if arg == "--" {
			os.Args = append([]string{os.Args[0]}, os.Args[i+1:]...)
			main()
			return
		}
	}
	os.Exit(2)
}

func TestNativeAttachProcessHelper(t *testing.T) {
	if os.Getenv("MOLT_TEST_ATTACH") != "1" {
		return
	}
	var endpoint string
	for i, arg := range os.Args {
		if arg == "attach" {
			endpoint = os.Args[i+1]
			break
		}
	}
	request := func(method, path string) int {
		req, _ := http.NewRequest(method, endpoint+path, strings.NewReader(`{"parts":[]}`))
		req.SetBasicAuth("opencode", "fixture-password")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			os.Exit(3)
		}
		defer resp.Body.Close()
		io.Copy(io.Discard, resp.Body)
		return resp.StatusCode
	}
	// Looking at another terminal's conversation must not take ownership of it.
	request("GET", "/session/ses_other")
	method, action, expected := "POST", "/prompt_async", http.StatusNoContent
	switch os.Getenv("MOLT_TEST_ACTION") {
	case "view":
		method, action, expected = "GET", "", http.StatusOK
	case "abort":
		action, expected = "/abort", http.StatusOK
	}
	if os.Getenv("MOLT_TEST_CONFLICT") == "1" {
		expected = http.StatusConflict
	}
	for _, id := range strings.Split(os.Getenv("MOLT_TEST_SESSIONS"), ",") {
		status := request(method, "/session/"+id+action+"?directory=%2Fworkspace%2Fsrc")
		if status != expected {
			os.Exit(4)
		}
	}
	if err := os.WriteFile(os.Getenv("MOLT_TEST_READY"), []byte("ready"), 0600); err != nil {
		os.Exit(5)
	}
	if os.Getenv("MOLT_TEST_QUIT") == "1" {
		return
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGHUP)
	<-signals
}

func TestAttachedTerminalsDetachAndResumeRunningSessions(t *testing.T) {
	var mu sync.Mutex
	active := map[string]bool{}
	aborted := map[string]int{}
	prompted := map[string]int{}
	viewed := map[string]int{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, password, ok := r.BasicAuth()
		if !ok || user != "opencode" || password != "fixture-password" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
		mu.Lock()
		defer mu.Unlock()
		if r.Method == "POST" && len(parts) == 3 {
			id := parts[1]
			switch parts[2] {
			case "prompt_async":
				active[id] = true
				prompted[id]++
				w.WriteHeader(http.StatusNoContent)
			case "abort":
				if r.URL.Query().Get("directory") != "/workspace/src" {
					t.Errorf("abort lost session directory: %s", r.URL)
				}
				active[id] = false
				aborted[id]++
				fmt.Fprint(w, "true")
			default:
				t.Errorf("unexpected mutation: %s", r.URL)
			}
		} else if r.Method == "GET" && len(parts) == 2 {
			viewed[parts[1]]++
		} else {
			t.Errorf("history was modified or deleted: %s %s", r.Method, r.URL)
		}
	}))
	defer server.Close()
	work := t.TempDir()
	native := filepath.Join(work, "native-opencode")
	if err := os.WriteFile(native, []byte("#!/bin/sh\nexec \"$MOLT_TEST_BINARY\" -test.run=TestNativeAttachProcessHelper -- \"$@\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	// The first terminal also exercises MOLT's shell signal and worker cleanup.
	if err := os.WriteFile(filepath.Join(work, "molt-tui"), []byte("#!/bin/sh\nexec \"$MOLT_TEST_BINARY\" -test.run=TestAttachProcessHelper -- \"$@\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(work, "home")
	os.Mkdir(home, 0700)
	os.WriteFile(filepath.Join(home, ".install-manifest"), []byte("OPENCODE_BINARY="+native+"\n"), 0600)
	wrapper := filepath.Join(work, "client.sh")
	if err := os.WriteFile(wrapper, []byte(`#!/bin/bash
set -euo pipefail
source "$MOLT_TEST_ROOT/bin/_molt.sh"
source "$MOLT_TEST_ROOT/bin/_opencode.sh"
managed_file() { [[ ! -L "$1" ]]; }
write_value() { printf '%s\n' "$2" >"$1"; }
MOLT_HOME="$MOLT_TEST_WORK/home"
SCRIPT_DIR="$MOLT_TEST_WORK"
PROJECT_STATE="$MOLT_TEST_WORK"
PROJECT_ID=fixture
MOLT_CLIENT_UPSTREAM="$1" MOLT_CLIENT_DIRECTORY=/workspace cmd_client attach "$1" --dir /workspace
`), 0700); err != nil {
		t.Fatal(err)
	}
	root, _ := filepath.Abs("..")
	var firstTerminal *os.File
	start := func(name, ids string, flags ...string) *exec.Cmd {
		t.Helper()
		ready := filepath.Join(work, name)
		cmd := exec.Command(os.Args[0], "-test.run=TestAttachProcessHelper", "--", "attach-client", "--upstream", server.URL,
			"--directory", "/workspace", "--sessions", filepath.Join(work, "sessions"), "--", native, "attach", server.URL, "--dir", "/workspace")
		if name == "first" {
			cmd = exec.Command("/bin/bash", wrapper, server.URL)
		}
		cmd.Env = append(os.Environ(), "MOLT_TEST_ATTACH=1", "MOLT_TEST_BINARY="+os.Args[0], "OPENCODE_SERVER_PASSWORD=fixture-password",
			"MOLT_TEST_SESSIONS="+ids, "MOLT_TEST_READY="+ready, "MOLT_TEST_ROOT="+root, "MOLT_TEST_WORK="+work,
			"TERM=dumb", "NO_COLOR=1", "COLORFGBG=15;0")
		cmd.Env = append(cmd.Env, flags...)
		cmd.Stderr = os.Stderr
		var err error
		if name == "first" {
			firstTerminal, err = pty.Start(cmd)
			t.Cleanup(func() { firstTerminal.Close() })
		} else {
			err = cmd.Start()
		}
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			if _, err := os.Stat(ready); err == nil {
				return cmd
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatal("attached client did not start")
		return nil
	}
	first := start("first", "ses_first,ses_new")
	second := start("second", "ses_other")
	// Explicitly resuming a session owned by another terminal cannot steal it.
	conflict := start("conflict", "ses_other", "MOLT_TEST_CONFLICT=1", "MOLT_TEST_QUIT=1")
	if err := conflict.Wait(); err != nil {
		t.Fatal(err)
	}
	if err := firstTerminal.Close(); err != nil {
		t.Fatal(err)
	}
	first.Wait()
	mu.Lock()
	if !active["ses_first"] || !active["ses_new"] || !active["ses_other"] || len(aborted) != 0 {
		t.Errorf("closing first terminal stopped remote work: active=%v aborted=%v", active, aborted)
	}
	mu.Unlock()
	workers, _ := filepath.Glob(filepath.Join(home, "state", "tmp", "client.*"))
	if len(workers) != 0 {
		t.Errorf("terminal close left worker records: %v", workers)
	}
	second.Process.Signal(syscall.SIGTERM)
	second.Wait()
	mu.Lock()
	if !active["ses_other"] || len(aborted) != 0 {
		t.Errorf("terminating second terminal stopped remote work: active=%v aborted=%v", active, aborted)
	}
	mu.Unlock()
	// Reconnecting reads the same running session without submitting another prompt.
	resumed := start("resumed", "ses_first", "MOLT_TEST_ACTION=view", "MOLT_TEST_QUIT=1")
	if err := resumed.Wait(); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	if !active["ses_first"] || prompted["ses_first"] != 1 || viewed["ses_first"] != 1 || len(aborted) != 0 {
		t.Errorf("reconnecting changed running work: active=%v prompted=%v viewed=%v aborted=%v", active, prompted, viewed, aborted)
	}
	mu.Unlock()
	quit := start("quit", "ses_quit", "MOLT_TEST_QUIT=1")
	if err := quit.Wait(); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	if !active["ses_quit"] || len(aborted) != 0 {
		t.Errorf("normal quit stopped remote work: active=%v aborted=%v", active, aborted)
	}
	mu.Unlock()
	// An explicit abort can claim sessions released by each kind of terminal exit.
	stopped := start("stopped", "ses_first,ses_other,ses_quit", "MOLT_TEST_ACTION=abort", "MOLT_TEST_QUIT=1")
	if err := stopped.Wait(); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	defer mu.Unlock()
	if active["ses_first"] || active["ses_other"] || active["ses_quit"] || !active["ses_new"] ||
		aborted["ses_first"] != 1 || aborted["ses_other"] != 1 || aborted["ses_quit"] != 1 || aborted["ses_new"] != 0 {
		t.Errorf("explicit abort affected wrong sessions: active=%v aborted=%v", active, aborted)
	}
}

func TestSessionProxyRejectsUnauthorizedRequestsAndReportsAbortFailure(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		if strings.HasSuffix(r.URL.Path, "/abort") {
			w.WriteHeader(http.StatusServiceUnavailable)
		}
	}))
	defer server.Close()
	endpoint, _ := url.Parse(server.URL)
	proxy := &sessionProxy{proxy: httputil.NewSingleHostReverseProxy(endpoint),
		lockDir: t.TempDir(), username: "opencode", password: "secret", sessions: map[string]*os.File{}}
	request := func(id, action, password string) int {
		req := httptest.NewRequest("POST", "/session/"+id+"/"+action, nil)
		req.SetBasicAuth("opencode", password)
		response := httptest.NewRecorder()
		proxy.ServeHTTP(response, req)
		return response.Code
	}
	if status := request("ses_test", "command", "wrong"); status != http.StatusUnauthorized {
		t.Fatalf("unauthorized request returned %d", status)
	}
	if status := request("invalid", "command", "secret"); status != http.StatusBadRequest {
		t.Fatalf("invalid session ID returned %d", status)
	}
	if requests.Load() != 0 || len(proxy.sessions) != 0 {
		t.Fatal("rejected requests reached the backend or took session ownership")
	}
	if status := request("ses_test", "command", "secret"); status != http.StatusOK {
		t.Fatalf("valid command returned %d", status)
	}
	if status := request("ses_test", "abort", "secret"); status != http.StatusServiceUnavailable {
		t.Fatalf("explicit abort failure was hidden: HTTP %d", status)
	}
	if err := proxy.close(); err != nil || requests.Load() != 2 {
		t.Fatalf("disconnect contacted the backend: requests=%d err=%v", requests.Load(), err)
	}
	if err := proxy.close(); err != nil || requests.Load() != 2 {
		t.Fatalf("cleanup was not idempotent: requests=%d err=%v", requests.Load(), err)
	}
	if status := request("ses_test", "command", "secret"); status != http.StatusConflict || requests.Load() != 2 {
		t.Fatalf("closed terminal forwarded a mutation: HTTP %d requests=%d", status, requests.Load())
	}
}
