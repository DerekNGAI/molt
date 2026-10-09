package main

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/vt"
	"github.com/creack/pty"
)

func TestConnectionCheckExplainsTheWaitWithoutMotion(t *testing.T) {
	t.Setenv("NO_COLOR", "1")
	m := newModel(backend{Context: context.Background()})
	defer m.collectorCancel()
	m.fetch("Check connection / fixture-vm", m.dashboard, func([]byte) tea.Cmd { return nil }, "connection", "test", "fixture-vm")
	defer m.queryCancel()
	m.queryStarted = time.Now().Add(-time.Second)
	if _, cmd := m.Update(queryTickMsg(m.queryID)); cmd == nil {
		t.Fatal("connection clock stops when animations are disabled")
	}
	view := m.View()
	for _, text := range []string{"Checking SSH connection", "fixture-vm", "30s", "Elapsed:", "Esc"} {
		if !strings.Contains(view, text) {
			t.Fatalf("connection wait is missing %q:\n%s", text, view)
		}
	}
	if !strings.Contains(view, "Elapsed: 1s") {
		t.Fatal("connection wait does not update elapsed time")
	}
	m.finishQuery(queryMsg{ID: m.queryID, Error: context.DeadlineExceeded})
	if !strings.Contains(m.View(), "Timed out after 30s") || m.dialog.Retry == nil {
		t.Fatalf("timeout has no explanation or retry:\n%s", m.View())
	}
}

func TestCancelledQueryIgnoresLateResultsAndClock(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	defer m.collectorCancel()
	called := false
	m.fetch("Connection", m.dashboard, func([]byte) tea.Cmd { called = true; return nil }, "connection", "test", "vm")
	id := m.queryID
	m.key(tea.KeyMsg{Type: tea.KeyEsc})
	m.finishQuery(queryMsg{ID: id, Data: []byte("ready")})
	_, cmd := m.Update(queryTickMsg(id))
	if called || cmd != nil || m.overlay != "" {
		t.Fatal("cancelled query accepted a stale result or continued its clock")
	}
}

func TestBackendPreservesTimeoutCause(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := (backend{CLI: "/bin/sh", Context: ctx}).output(time.Second, "-c", "exit 0")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("query cancellation lost its cause: %v", err)
	}
}

func TestStartupStageStaysVisibleAboveScrolledOutput(t *testing.T) {
	m := newModel(backend{Home: t.TempDir(), Context: context.Background()})
	defer m.collectorCancel()
	m.action, m.overlay, m.work = "Start app", "action", t.TempDir()
	m.animation, m.paused = false, true
	if err := os.WriteFile(filepath.Join(m.work, "progress"), []byte("Building container image\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(m.work, "output"), []byte(strings.Repeat("Downloading Ubuntu layers\n", 1500)), 0600); err != nil {
		t.Fatal(err)
	}
	m.Update(frameMsg{})
	started := m.stageStarted
	m.Update(frameMsg{})
	if m.stageStarted != started {
		t.Fatal("repeated output polling resets the current step clock")
	}
	m.scroll = 50
	for _, size := range [][2]int{{100, 32}, {70, 24}, {42, 14}} {
		m.width, m.height = size[0], size[1]
		view := m.View()
		for _, text := range []string{"Building", "Elapsed:", "Esc"} {
			if !strings.Contains(view, text) {
				t.Fatalf("startup at %v is missing %q:\n%s", size, text, view)
			}
		}
		if lipgloss.Width(view) > size[0] || lipgloss.Height(view) > size[1] {
			t.Fatalf("startup exceeds terminal %v", size)
		}
	}
	m.Update(actionMsg{Name: m.action, Work: m.work, Error: context.DeadlineExceeded})
	if !strings.Contains(m.dialog.Body, "Failed during: Building container image") {
		t.Fatalf("failure lost its stage: %s", m.dialog.Body)
	}
}

func TestDashboardStartupOffersRetry(t *testing.T) {
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, "state", "tmp"), 0700); err != nil {
		t.Fatal(err)
	}
	m := newModel(backend{Home: home, Context: context.Background()})
	defer m.collectorCancel()
	m.startAction("Start app", "start", "@aaaaaaaaaaaa")
	defer m.cancelAction()
	if m.overlay != "action" {
		t.Fatal("dashboard startup does not show progress in a compact terminal")
	}
	m.Update(actionMsg{Name: m.action, Work: m.work, Error: context.DeadlineExceeded})
	if m.overlay != "message" || m.dialog.Retry == nil || !strings.Contains(m.View(), "retry") {
		t.Fatalf("dashboard startup failure has no retry:\n%s", m.View())
	}
}

func TestStartupDashboardProcessHelper(t *testing.T) {
	if os.Getenv("MOLT_TEST_STARTUP_UI") != "1" {
		return
	}
	for i, arg := range os.Args {
		if arg == "--" {
			os.Args = append([]string{os.Args[0]}, os.Args[i+1:]...)
			main()
			os.Exit(0)
		}
	}
	os.Exit(2)
}

func TestStartupDashboardPTY(t *testing.T) {
	home := t.TempDir()
	state := filepath.Join(home, "projects", "aaaaaaaaaaaa")
	for _, dir := range []string{state, filepath.Join(home, "state", "tmp")} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	for key, value := range map[string]string{"name": "app", "host": "fixture-vm", "path": home} {
		if err := os.WriteFile(filepath.Join(state, key), []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
	}
	cli := filepath.Join(home, "cli")
	fixture := `#!/bin/bash
set -euo pipefail
case "$1" in
  config) printf 'MOLT_HOST=fixture-vm\nMOLT_ANIMATIONS=0\n' ;;
  connection)
    while [[ ! -f "$MOLT_HOME/connected" ]]; do sleep .05 & wait; done ;;
  ui-action)
    printf 'Building container image\n' >"$2/progress"
    printf 'Downloading Ubuntu layers\n' >"$2/output"
    while [[ ! -f "$MOLT_HOME/finish" ]]; do sleep .05 & wait; done
    printf 'Download failed; retry startup.\n' >>"$2/output"
    exit 23 ;;
  monitor) [[ "$2" != sync ]] || printf '[]\n' ;;
esac
`
	if err := os.WriteFile(cli, []byte(fixture), 0700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestStartupDashboardProcessHelper$", "--", "--cli", cli, "--home", home)
	cmd.Env = append(os.Environ(), "MOLT_TEST_STARTUP_UI=1", "NO_COLOR=1", "TERM=xterm-256color")
	master, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: 100, Rows: 32})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { cmd.Process.Signal(os.Interrupt); master.Close(); cmd.Wait() }()
	term := vt.NewEmulator(100, 32)
	defer term.InputPipe().(io.Closer).Close()
	go func() { _, _ = io.Copy(master, term) }()
	chunks := make(chan []byte, 64)
	go func() {
		defer close(chunks)
		for {
			buf := make([]byte, 32*1024)
			n, err := master.Read(buf)
			if err != nil {
				return
			}
			select {
			case chunks <- buf[:n]:
			case <-ctx.Done():
				return
			}
		}
	}()
	wait := func(text string) {
		t.Helper()
		deadline := time.NewTimer(5 * time.Second)
		defer deadline.Stop()
		for !strings.Contains(term.String(), text) {
			select {
			case data, ok := <-chunks:
				if !ok {
					t.Fatalf("dashboard exited before %q:\n%s", text, term.String())
				}
				term.Write(data)
			case <-deadline.C:
				t.Fatalf("dashboard did not show %q:\n%s", text, term.String())
			}
		}
	}
	send := func(keys string) {
		t.Helper()
		if _, err := io.WriteString(master, keys); err != nil {
			t.Fatal(err)
		}
	}
	touch := func(name string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(home, name), nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	wait("app")
	send("s")
	wait("Checking SSH connection")
	wait("Elapsed: 1s")
	touch("connected")
	wait("Building container image")
	wait("Downloading Ubuntu layers")
	send("k")
	term.Resize(42, 14)
	term.Write([]byte("\x1b[2J"))
	if err := pty.Setsize(master, &pty.Winsize{Cols: 42, Rows: 14}); err != nil {
		t.Fatal(err)
	}
	wait("Esc cancel")
	if !strings.Contains(term.String(), "Building") || !strings.Contains(term.String(), "Esc") {
		t.Fatalf("compact startup lost its stage or controls:\n%s", term.String())
	}
	touch("finish")
	wait("retry")
	if !strings.Contains(term.String(), "Failed during: Building") {
		t.Fatalf("startup failure lost its stage:\n%s", term.String())
	}
	if err := os.Remove(filepath.Join(home, "finish")); err != nil {
		t.Fatal(err)
	}
	send("r")
	wait("Building container image")
	send("\x1b")
	wait("Cancel")
	send("y")
	wait("retry")
	send("\x1b")
	wait(": commands")
	send("q")
	if err := cmd.Wait(); err != nil {
		t.Fatal(err)
	}
}
