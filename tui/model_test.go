package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

func TestStaticActionsStillStreamOutputAndPausedStateIsVisible(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	m.animation = false
	m.paused = true
	m.work = t.TempDir()
	m.action = "Building"
	if err := os.WriteFile(filepath.Join(m.work, "output"), []byte("Build step completed\n"), 0600); err != nil {
		t.Fatal(err)
	}
	m.Update(pollMsg{})
	if len(m.output) != 1 || m.output[0] != "Build step completed" {
		t.Fatal("static action output did not refresh")
	}
	m.action = ""
	m.syncs["app"] = syncState{Alpha: syncEndpoint{Connected: true}, Beta: syncEndpoint{Connected: true, StagingProgress: &struct{ ReceivedSize, TotalSize uint64 }{1, 2}}}
	if !strings.Contains(m.View(), "PAUSED") {
		t.Fatal("transfer spinner hides paused polling")
	}
}

func TestFocusAndHelpRemainVisibleWithoutColor(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	m.width, m.height = 70, 24
	m.overlay = "help"
	if !strings.Contains(m.View(), "Esc close") {
		t.Fatal("narrow help lost closing instruction")
	}
	m.overlay = ""
	if !strings.Contains(m.View(), "› VM") {
		t.Fatal("focus only indicated by color")
	}
}

func TestTinyOverlaysKeepControlsAndPaletteSelectionVisible(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	m.width, m.height = 42, 14
	m.overlay = "help"
	if !strings.Contains(m.View(), "Esc") {
		t.Fatal("tiny help hides exit controls")
	}
	m.overlay = "palette"
	for i := 0; i < 5; i++ {
		m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	}
	if !strings.Contains(m.View(), "› Maintenance") {
		t.Fatal("palette selection scrolled out of sight")
	}
}

func TestConfirmationKeepsOriginalTargetAfterRegistryChanges(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	m.inv = inventory{Config: map[string]string{}, Projects: []project{{ID: "aaaaaaaaaaaa", Name: "original"}, {ID: "bbbbbbbbbbbb", Name: "other"}}}
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}})
	m.Update(inventoryMsg{inventory{Config: map[string]string{}, Projects: []project{{ID: "bbbbbbbbbbbb", Name: "other"}}}})
	if !strings.Contains(m.View(), "Stop original") {
		t.Fatal("confirmation silently switched to another project")
	}
}

func TestDashboardFitsTerminalAndSearchCannotTriggerActions(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	m.inv = inventory{Config: map[string]string{}, Projects: []project{{ID: "abcdef012345", Name: "myapp", Host: "vm"}, {ID: "012345abcdef", Name: "backend", Host: "vm"}}}
	for _, size := range [][2]int{{140, 42}, {100, 32}, {70, 24}, {42, 14}} {
		m.width, m.height = size[0], size[1]
		v := m.View()
		if lipgloss.Width(v) > size[0] || lipgloss.Height(v) > size[1] {
			t.Fatalf("view %dx%d exceeds terminal %v", lipgloss.Width(v), lipgloss.Height(v), size)
		}
	}
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'/'}})
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("backend")})
	if len(m.filtered()) != 1 || m.filtered()[0].Name != "backend" {
		t.Fatal("filter did not narrow projects")
	}
	if m.action != "" {
		t.Fatal("typing a search triggered a lifecycle action")
	}
}

func TestSelectionSurvivesRefreshAndQuitDoesNotCancelWorkSilently(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	m.inv = inventory{Config: map[string]string{}, Projects: []project{{ID: "aaaaaaaaaaaa", Name: "first"}, {ID: "bbbbbbbbbbbb", Name: "second"}}}
	m.selected = "bbbbbbbbbbbb"
	m.Update(inventoryMsg{inventory{Config: map[string]string{}, Projects: []project{{ID: "bbbbbbbbbbbb", Name: "second"}, {ID: "aaaaaaaaaaaa", Name: "first"}}}})
	if m.current().ID != "bbbbbbbbbbbb" {
		t.Fatal("refresh jumped to a different project")
	}
	m.action = "Start second"
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'q'}})
	if m.overlay != "quit" {
		t.Fatal("quit during an action did not request explicit cancellation")
	}
	m.width, m.height = 100, 32
	if !strings.Contains(m.View(), "Cancel") {
		t.Fatal("quit confirmation is not visible")
	}
}

func TestManagementCommandsStayInsideUI(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'m'}})
	if m.overlay != "palette" {
		t.Fatal("management shortcut hands the terminal to the legacy menu")
	}
	for index, item := range palette() {
		if !item.Interactive {
			continue
		}
		m.overlay, m.paletteIndex = "palette", index
		m.overlayKey(tea.KeyMsg{Type: tea.KeyEnter})
		if m.overlay == "" {
			t.Fatalf("%s left the Bubble Tea UI", item.Title)
		}
	}
	m.overlay = ""
	m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'c'}})
	if m.overlay == "" {
		t.Fatal("connecting without a host leaves the UI")
	}
}

func TestInteractiveActionsKeepMoltScreen(t *testing.T) {
	m := newModel(backend{CLI: "/bin/sh", Context: context.Background()})
	m.terminal("-c", "printf 'interactive session\\n'")
	if m.overlay != "session" {
		t.Fatal("interactive action suspends MOLT instead of opening an embedded pane")
	}
}

func TestStartupMotionWaitsForSavedPreference(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	if m.animation || m.spinner() != "·" {
		t.Fatal("startup animates before the preference is loaded")
	}
	m.Update(inventoryMsg{inventory{Config: map[string]string{"MOLT_ANIMATIONS": "1"}}})
	if os.Getenv("NO_COLOR") == "" && !m.animation {
		t.Fatal("saved animation preference was not applied")
	}
}

func TestAuthorizationSessionUsesConnectionAlias(t *testing.T) {
	for _, identity := range []string{"", "/a/long/private/identity/file"} {
		m := newModel(backend{Context: context.Background()})
		m.terminal("connection", "authorize", "fixture-vm", identity)
		if m.sessionTitle != "SSH / fixture-vm" {
			t.Fatalf("authorization target is hidden by %q", m.sessionTitle)
		}
		m.sessionCancel()
	}
}

func TestTinyFormShowsValidationError(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	m.width, m.height = 42, 14
	m.connectionForm("")
	m.form.Index = len(m.form.Fields) - 1
	m.key(tea.KeyMsg{Type: tea.KeyEnter})
	if !strings.Contains(m.View(), "VM address is required") {
		t.Fatal("required-field error is hidden in a tiny terminal")
	}
}

func TestScanResultsRemainDistinctUnderLongPaths(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	m.inv.Config = map[string]string{"MOLT_ROOT": "/" + strings.Repeat("long-parent/", 12)}
	m.scanForm()
	m.form.Submit([]string{m.inv.Config["MOLT_ROOT"]})
	m.finishQuery(queryMsg{ID: m.queryID, Data: []byte(m.inv.Config["MOLT_ROOT"] + "frontend\n" + m.inv.Config["MOLT_ROOT"] + "backend\n")})
	if !strings.Contains(m.View(), "frontend") || !strings.Contains(m.View(), "backend") {
		t.Fatal("scan results show only their shared parent prefix")
	}
}

func TestUntouchedRemovalDoesNotCheckSSH(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	p := project{ID: "aaaaaaaaaaaa", Name: "offline", Host: "unreachable-vm"}
	m.projectMenu(p)
	for _, item := range m.menu.Items {
		if item.Title == "Remove project" {
			item.Run()
			break
		}
	}
	if m.overlay != "loading" {
		t.Fatal("removal did not check local setup state first")
	}
	m.finishQuery(queryMsg{ID: m.queryID, Data: []byte("untouched\n")})
	if m.overlay != "confirm" || strings.Contains(m.dialog.Body, "VM resources will remain") {
		t.Fatal("untouched removal incorrectly warned about VM leftovers")
	}
	if m.dialog.Yes == nil {
		t.Fatal("offline removal has no confirmation action")
	}
}

func TestLocalUninstallWarnsWithoutSavingAFile(t *testing.T) {
	for _, state := range []string{"untouched", "started", "complete"} {
		m := newModel(backend{Context: context.Background()})
		m.uninstallMenu()
		for _, item := range m.menu.Items {
			if item.Title == "Remove Mac installation only" {
				item.Run()
				break
			}
		}
		if m.overlay != "loading" {
			t.Fatal("local uninstall still requires saving an external inventory file")
		}
		m.finishQuery(queryMsg{ID: m.queryID, Data: []byte(state + "\n")})
		if m.overlay != "confirm" {
			t.Fatal("local uninstall did not reach confirmation")
		}
		if warned := strings.Contains(m.dialog.Body, "VM resources"); warned != (state != "untouched") {
			t.Fatalf("incorrect local uninstall warning for %s: %s", state, m.dialog.Body)
		}
	}
}

func TestCompleteUninstallOnlyAuthenticatesHostsWithVMChanges(t *testing.T) {
	home := t.TempDir()
	state := filepath.Join(home, "projects", "bbbbbbbbbbbb")
	if err := os.MkdirAll(state, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(state, "remote_path"), []byte("/vm/molt/projects/bbbbbbbbbbbb\n"), 0600); err != nil {
		t.Fatal(err)
	}
	m := newModel(backend{Home: home, Context: context.Background()})
	m.inv.Projects = []project{{ID: "aaaaaaaaaaaa", Host: "untouched-vm"}, {ID: "bbbbbbbbbbbb", Host: "provisioned-vm"}}
	m.confirmUninstall(false, false)
	m.finishQuery(queryMsg{ID: m.queryID, Data: []byte("started\n")})
	m.dialog.Yes()
	if m.overlay != "loading" || m.dialog.Title != "Check connection / provisioned-vm" {
		t.Fatalf("complete uninstall did not authenticate only the provisioned host: %s", m.dialog.Title)
	}
}

func TestEmbeddedPTYQueriesInputAndResize(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	m := newModel(backend{CLI: "/usr/bin/python3", Context: ctx})
	code := `import os,tty,select,struct,fcntl,termios
assert all(os.isatty(fd) for fd in (0,1,2))
tty.setraw(0)
os.write(1,b'\x1b[?1049h\x1b[2J\x1b[H\x1b[5n')
reply=b''
while not reply.endswith(b'n'):
 if not select.select([0],[],[],2)[0]: raise RuntimeError('query timeout')
 reply+=os.read(0,32)
assert reply==b'\x1b[0n',repr(reply)
os.write(1,b'PTY ready\r\n')
text=b''
while not text.endswith(b'\r'): text+=os.read(0,32)
rows,cols,_,_=struct.unpack('HHHH',fcntl.ioctl(0,termios.TIOCGWINSZ,b'\0'*8))
os.write(1,('Input: '+text.decode().strip()+' Size: '+str(cols)+'x'+str(rows)+'\r\n').encode())
os.write(1,b'Modifier ready\r\n')
key=b''
while not key.endswith(b'D'): key+=os.read(0,32)
assert key==b'\x1b[1;6D',repr(key)
os.write(1,b'Modifier OK\r\n')
`
	started := m.terminal("-c", code)().(sessionStartedMsg)
	if started.Error != nil {
		t.Fatal(started.Error)
	}
	m.sessionStarted(started)
	defer started.Session.close()
	inputSent, modifierSent := false, false
	for {
		msg := started.Session.read()().(sessionOutputMsg)
		m.sessionOutput(msg)
		if msg.Done {
			if msg.Error != nil {
				t.Fatalf("PTY child: %v\n%s", msg.Error, m.dialog.Body)
			}
			if !strings.Contains(m.dialog.Body, "Input: quiet Size: 56x11") || !strings.Contains(m.dialog.Body, "Modifier OK") {
				t.Fatal(m.dialog.Body)
			}
			break
		}
		if !inputSent && strings.Contains(m.session.term.String(), "PTY ready") {
			m.Update(tea.WindowSizeMsg{Width: 60, Height: 18})
			m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("quiet")})
			m.key(tea.KeyMsg{Type: tea.KeyEnter})
			inputSent = true
		}
		if !modifierSent && strings.Contains(m.session.term.String(), "Modifier ready") {
			m.key(tea.KeyMsg{Type: tea.KeyCtrlShiftLeft})
			modifierSent = true
		}
	}
}
