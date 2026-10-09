package main

import (
	"bufio"
	bytebuf "bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/creack/pty"
)

func TestRealOpenCodeDetachAndResume(t *testing.T) {
	clientBinary := os.Getenv("MOLT_TEST_OPENCODE_CLIENT")
	if clientBinary == "" {
		t.Skip("set MOLT_TEST_OPENCODE_CLIENT to run the real-client attachment test")
	}
	serverBinary := os.Getenv("MOLT_TEST_OPENCODE_SERVER")
	if serverBinary == "" {
		serverBinary = clientBinary
	}
	work := t.TempDir()
	repo, config := filepath.Join(work, "repo"), filepath.Join(work, "config")
	for _, path := range []string{repo, config} {
		if err := os.MkdirAll(path, 0700); err != nil {
			t.Fatal(err)
		}
	}
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var input struct{ Model string }
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil || input.Model != "slow" {
			http.Error(w, "invalid fixture request", http.StatusBadRequest)
			return
		}
		r.Body.Close()
		t.Logf("model request: %s %s", r.Method, r.URL.Path)
		w.Header().Set("Content-Type", "text/event-stream")
		ticker := time.NewTicker(100 * time.Millisecond)
		defer ticker.Stop()
		for tick := 0; ; tick++ {
			select {
			case <-r.Context().Done():
				return
			case <-ticker.C:
				chunk := fmt.Sprintf(`{"id":"chatcmpl-fixture","object":"chat.completion.chunk","created":1,"model":"slow","choices":[{"index":0,"delta":{"content":"tick %d\n"},"finish_reason":null}]}`, tick)
				if _, err := fmt.Fprintf(w, "data: %s\n\n", chunk); err != nil {
					return
				}
				w.(http.Flusher).Flush()
			}
		}
	}))
	t.Cleanup(provider.Close)
	settings := fmt.Sprintf(`{"model":"molt-fixture/slow","provider":{"molt-fixture":{"npm":"@ai-sdk/openai-compatible","name":"Fixture","options":{"baseURL":%q,"apiKey":"fixture"},"models":{"slow":{"name":"Slow fixture","limit":{"context":32768,"output":128}}}}}}`, provider.URL+"/v1")
	if err := os.WriteFile(filepath.Join(config, "opencode.json"), []byte(settings), 0600); err != nil {
		t.Fatal(err)
	}
	env := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + filepath.Join(work, "home"),
		"XDG_CONFIG_HOME=" + config, "XDG_DATA_HOME=" + filepath.Join(work, "data"),
		"XDG_CACHE_HOME=" + filepath.Join(work, "cache"), "XDG_STATE_HOME=" + filepath.Join(work, "state"),
		"OPENCODE_CONFIG_DIR=" + config, "OPENCODE_SERVER_PASSWORD=fixture-password", "OPENCODE_SERVER_USERNAME=opencode",
		"OPENCODE_PURE=1", "OPENCODE_DISABLE_AUTOUPDATE=1", "OPENCODE_DISABLE_MODELS_FETCH=1", "OPENCODE_DISABLE_PROJECT_CONFIG=1",
		"TERM=xterm-256color", "NO_COLOR=1", "COLORFGBG=15;0", "MOLT_TEST_ATTACH=1", "MOLT_TEST_BINARY=" + os.Args[0]}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	log, err := os.Create(filepath.Join(work, "server.log"))
	if err != nil {
		t.Fatal(err)
	}
	server := exec.Command(serverBinary, "serve", "--hostname", "127.0.0.1", "--port", fmt.Sprint(port))
	server.Env, server.Dir, server.Stdout, server.Stderr = env, repo, log, log
	if err := server.Start(); err != nil {
		log.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { server.Process.Kill(); server.Wait(); log.Close() })
	endpoint := fmt.Sprintf("http://127.0.0.1:%d", port)
	api := func(path string, body any, result any) error {
		var input io.Reader
		method := "GET"
		if body != nil {
			data, err := json.Marshal(body)
			if err != nil {
				return err
			}
			input, method = bytebuf.NewReader(data), "POST"
		}
		req, _ := http.NewRequest(method, endpoint+path, input)
		req.SetBasicAuth("opencode", "fixture-password")
		req.Header.Set("Content-Type", "application/json")
		resp, err := (&http.Client{Timeout: 3 * time.Second}).Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("%s: HTTP %d", path, resp.StatusCode)
		}
		if result != nil {
			return json.NewDecoder(resp.Body).Decode(result)
		}
		_, err = io.Copy(io.Discard, resp.Body)
		return err
	}
	wait := func(t *testing.T, description string, ready func() bool) {
		t.Helper()
		deadline := time.Now().Add(15 * time.Second)
		for time.Now().Before(deadline) {
			if ready() {
				return
			}
			time.Sleep(20 * time.Millisecond)
		}
		data, _ := os.ReadFile(filepath.Join(work, "server.log"))
		details, _ := os.ReadFile(filepath.Join(work, "data", "opencode", "log", "opencode.log"))
		t.Fatalf("timed out waiting for %s\n%s\n%s", description, data, details)
	}
	wait(t, "server health", func() bool { return api("/global/health", nil, nil) == nil })
	eventRequest, _ := http.NewRequest("GET", endpoint+"/global/event", nil)
	eventRequest.SetBasicAuth("opencode", "fixture-password")
	eventStream, err := http.DefaultClient.Do(eventRequest)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { eventStream.Body.Close() })
	var deltas atomic.Int32
	go func() {
		scanner := bufio.NewScanner(eventStream.Body)
		for scanner.Scan() {
			if strings.Contains(scanner.Text(), `"type":"message.part.delta"`) {
				deltas.Add(1)
			}
		}
	}()
	upstream, _ := url.Parse(endpoint)
	proxy := httputil.NewSingleHostReverseProxy(upstream)
	proxy.FlushInterval = -1
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		if r.Context().Err() != nil {
			return
		}
		t.Errorf("observer request failed: %s %s: %v", r.Method, r.URL.Path, err)
		http.Error(w, "fixture upstream unavailable", http.StatusBadGateway)
	}
	var prompts, aborts atomic.Int32
	observer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "POST" {
			t.Logf("client request: %s %s", r.Method, r.URL.Path)
			if strings.HasSuffix(r.URL.Path, "/message") {
				prompts.Add(1)
			}
			if strings.HasSuffix(r.URL.Path, "/abort") {
				aborts.Add(1)
			}
		}
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(observer.Close)
	start := func(t *testing.T, session string) (*os.File, <-chan struct{}, func() string) {
		t.Helper()
		args := []string{"-test.run=TestAttachProcessHelper", "--", "attach-client", "--upstream", observer.URL,
			"--directory", repo, "--sessions", filepath.Join(work, "locks"), "--", clientBinary, "attach", observer.URL,
			"--dir", repo, "--session", session}
		binary := os.Args[0]
		if installed := os.Getenv("MOLT_TUI_BINARY"); installed != "" {
			binary, args = installed, args[2:]
		}
		cmd := exec.Command(binary, args...)
		cmd.Env, cmd.Dir = env, repo
		master, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: 35, Cols: 120})
		if err != nil {
			t.Fatal(err)
		}
		var mu sync.Mutex
		var output bytebuf.Buffer
		done := make(chan struct{})
		go func() { cmd.Wait(); close(done) }()
		go func() {
			buffer := make([]byte, 65536)
			for {
				n, err := master.Read(buffer)
				if n > 0 {
					mu.Lock()
					output.Write(buffer[:n])
					mu.Unlock()
					if bytebuf.Contains(buffer[:n], []byte("\x1b[5n")) {
						io.WriteString(master, "\x1b[0n")
					}
					if bytebuf.Contains(buffer[:n], []byte("\x1b[6n")) {
						io.WriteString(master, "\x1b[1;1R")
					}
				}
				if err != nil {
					return
				}
			}
		}()
		screen := func() string { mu.Lock(); defer mu.Unlock(); return output.String() }
		t.Cleanup(func() {
			select {
			case <-done:
			default:
				syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
			}
			master.Close()
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				cmd.Process.Kill()
			}
		})
		wait(t, "client readiness", func() bool { return strings.Contains(screen(), "Slow fixture") })
		return master, done, screen
	}
	for _, mode := range []string{"exit", "terminal-close"} {
		t.Run(mode, func(t *testing.T) {
			var session struct{ ID string }
			if err := api("/session", map[string]string{"title": "MOLT detach fixture"}, &session); err != nil {
				t.Fatal(err)
			}
			status := func() string {
				var states map[string]struct{ Type string }
				if err := api("/session/status", nil, &states); err != nil {
					return "unavailable"
				}
				return states[session.ID].Type
			}
			beforePrompts, beforeAborts, beforeDeltas := prompts.Load(), aborts.Load(), deltas.Load()
			master, done, screen := start(t, session.ID)
			io.WriteString(master, "Keep responding until explicitly stopped.\r")
			wait(t, "streaming task", func() bool { return status() == "busy" && deltas.Load() > beforeDeltas+1 })
			if mode == "exit" {
				io.WriteString(master, "/exit")
				wait(t, "exit command completion", func() bool { return strings.Contains(screen(), "Exit the app") })
				io.WriteString(master, "\r")
			} else {
				master.Close()
			}
			wait(t, "client exit", func() bool {
				select {
				case <-done:
					return true
				default:
					return false
				}
			})
			if aborts.Load() != beforeAborts || status() != "busy" {
				t.Fatal("terminal exit interrupted remote work")
			}
			progress := deltas.Load()
			wait(t, "progress after disconnect", func() bool { return deltas.Load() > progress+1 })
			resumed, _, _ := start(t, session.ID)
			progress = deltas.Load()
			wait(t, "progress after reconnect", func() bool { return status() == "busy" && deltas.Load() > progress+1 })
			if prompts.Load() != beforePrompts+1 {
				t.Fatal("reconnecting submitted another prompt")
			}
			io.WriteString(resumed, "\x1b")
			time.Sleep(100 * time.Millisecond)
			io.WriteString(resumed, "\x1b")
			wait(t, "explicit stop", func() bool {
				state := status()
				return aborts.Load() == beforeAborts+1 && (state == "" || state == "idle")
			})
		})
	}
}
