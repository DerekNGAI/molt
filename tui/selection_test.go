package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func clipboardFixture(t *testing.T, fail bool) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "clipboard")
	script := "#!/bin/sh\n/bin/cat > \"$MOLT_TEST_CLIPBOARD\"\n"
	if fail {
		script += "exit 1\n"
	}
	if err := os.WriteFile(filepath.Join(dir, "pbcopy"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("MOLT_TEST_CLIPBOARD", path)
	return path
}

func textPoint(t *testing.T, view, text string) (int, int) {
	t.Helper()
	for y, line := range strings.Split(ansi.Strip(view), "\n") {
		if index := strings.Index(line, text); index >= 0 {
			return ansi.StringWidth(line[:index]), y
		}
	}
	t.Fatalf("text %q missing from view:\n%s", text, ansi.Strip(view))
	return 0, 0
}

func dragText(m *model, x1, y1, x2, y2 int) tea.Cmd {
	m.Update(tea.MouseMsg{X: x1, Y: y1, Button: tea.MouseButtonLeft, Action: tea.MouseActionPress})
	m.Update(tea.MouseMsg{X: x2, Y: y2, Button: tea.MouseButtonLeft, Action: tea.MouseActionMotion})
	_, cmd := m.Update(tea.MouseMsg{X: x2, Y: y2, Button: tea.MouseButtonNone, Action: tea.MouseActionRelease})
	return cmd
}

func finishCopy(t *testing.T, m *model, cmd tea.Cmd, path, want string) {
	t.Helper()
	if cmd == nil {
		t.Fatal("selection did not request clipboard copying")
	}
	m.Update(cmd())
	got, err := os.ReadFile(path)
	if err != nil || string(got) != want {
		t.Fatalf("clipboard = %q, error = %v; want %q", got, err, want)
	}
	if !strings.Contains(ansi.Strip(m.View()), "Copied") {
		t.Fatal("clipboard success is not visible")
	}
}

func TestDragCopiesOutputAndMessagesWithoutBorders(t *testing.T) {
	path := clipboardFixture(t, false)
	for _, overlay := range []string{"", "action", "message"} {
		for _, size := range [][2]int{{100, 32}, {101, 33}, {42, 14}} {
			m := newModel(backend{Context: context.Background()})
			t.Cleanup(m.collectorCancel)
			m.width, m.height, m.focus = size[0], size[1], 3
			m.logs, m.output = true, []string{"ERROR failed"}
			m.overlay = overlay
			m.dialog = dialogState{Title: "Remove project failed", Body: "ERROR failed"}
			x, y := textPoint(t, m.View(), "ERROR failed")
			finishCopy(t, m, dragText(m, x, y, x+11, y), path, "ERROR failed")
		}
	}
}

func TestDragUsesDisplayedSnapshotUntilRelease(t *testing.T) {
	path := clipboardFixture(t, false)
	m := newModel(backend{Context: context.Background()})
	defer m.collectorCancel()
	m.logs, m.focus, m.output = true, 3, []string{"original error"}
	x, y := textPoint(t, m.View(), "original error")
	m.Update(tea.MouseMsg{X: x, Y: y, Button: tea.MouseButtonLeft, Action: tea.MouseActionPress})
	m.output = []string{"new output"}
	m.Update(frameMsg{})
	m.Update(tea.MouseMsg{X: x + 13, Y: y, Button: tea.MouseButtonLeft, Action: tea.MouseActionMotion})
	view := m.View()
	if !strings.Contains(ansi.Strip(view), "original error") {
		t.Fatal("streaming output changed text under an active selection")
	}
	if !strings.Contains(view, "\x1b[7m") {
		t.Fatal("dragged text is not visibly highlighted")
	}
	_, cmd := m.Update(tea.MouseMsg{X: x + 13, Y: y, Button: tea.MouseButtonLeft, Action: tea.MouseActionRelease})
	finishCopy(t, m, cmd, path, "original error")
	if !strings.Contains(ansi.Strip(m.View()), "new output") {
		t.Fatal("output did not resume after mouse release")
	}
}

func TestBackwardMultilineDragIncludesWholeUnicodeCharacters(t *testing.T) {
	path := clipboardFixture(t, false)
	m := newModel(backend{Context: context.Background()})
	defer m.collectorCancel()
	m.showMessage("Failed", "before 界\ne\u0301 👩‍💻 after", m.dashboard)
	view := m.View()
	x1, y1 := textPoint(t, view, "界")
	x2, y2 := textPoint(t, view, "👩‍💻")
	finishCopy(t, m, dragText(m, x2+1, y2, x1+1, y1), path, "界\ne\u0301 👩‍💻")
}

func TestCopyShortcutUsesEntireUnwrappedOutput(t *testing.T) {
	path := clipboardFixture(t, false)
	m := newModel(backend{Context: context.Background()})
	defer m.collectorCancel()
	m.width, m.height = 42, 14
	body := "\x1b[31mERROR\x1b[0m " + strings.Repeat("long path/", 20) + "\nsecond line"
	m.showMessage("Failed", body, m.dashboard)
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'Y'}})
	finishCopy(t, m, cmd, path, ansi.Strip(body))
}

func TestClipboardFailureIsVisibleAndPreservesError(t *testing.T) {
	clipboardFixture(t, true)
	m := newModel(backend{Context: context.Background()})
	defer m.collectorCancel()
	m.showMessage("Failed", "Removal conflict", m.dashboard)
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'Y'}})
	if cmd == nil {
		t.Fatal("copy shortcut did not run")
	}
	m.Update(cmd())
	if m.dialog.Body != "Removal conflict" || !strings.Contains(ansi.Strip(m.View()), "Copy failed") {
		t.Fatal("clipboard failure lost the error or its failure notice")
	}
}

func TestClickResizeAndNavigationDoNotCopy(t *testing.T) {
	path := clipboardFixture(t, false)
	for _, interrupt := range []tea.Msg{nil, tea.WindowSizeMsg{Width: 70, Height: 24}, tea.KeyMsg{Type: tea.KeyEsc}} {
		m := newModel(backend{Context: context.Background()})
		t.Cleanup(m.collectorCancel)
		m.showMessage("Failed", "Removal conflict", m.dashboard)
		x, y := textPoint(t, m.View(), "Removal conflict")
		end := x
		m.Update(tea.MouseMsg{X: x, Y: y, Button: tea.MouseButtonLeft, Action: tea.MouseActionPress})
		if interrupt != nil {
			end = x + 5
			m.Update(tea.MouseMsg{X: x + 5, Y: y, Button: tea.MouseButtonLeft, Action: tea.MouseActionMotion})
			m.Update(interrupt)
		}
		_, cmd := m.Update(tea.MouseMsg{X: end, Y: y, Button: tea.MouseButtonNone, Action: tea.MouseActionRelease})
		if cmd != nil {
			t.Fatal("click or cancelled selection requested clipboard copying")
		}
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("clipboard changed without a completed drag")
	}
}

func TestDragReleaseOutsideBodyExcludesBorders(t *testing.T) {
	path := clipboardFixture(t, false)
	m := newModel(backend{Context: context.Background()})
	defer m.collectorCancel()
	m.showMessage("Failed", "Removal conflict", m.dashboard)
	x, y := textPoint(t, m.View(), "Removal conflict")
	finishCopy(t, m, dragText(m, x, y, m.width+10, y), path, "Removal conflict")
}
