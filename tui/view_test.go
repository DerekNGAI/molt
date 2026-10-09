package main

import (
	"context"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

func TestContextualFooterRemainsOnScreen(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	m.inv.Projects = []project{{ID: "aaaaaaaaaaaa", Name: "app", Path: "/repos/app"}}
	for _, size := range [][2]int{{140, 42}, {100, 32}, {70, 24}, {60, 19}, {42, 14}} {
		m.width, m.height = size[0], size[1]
		for focus, action := range []string{"c connect", "R refresh", "Enter details", "↑↓ scroll"} {
			m.focus = focus
			view := ansi.Strip(m.View())
			lines := strings.Split(view, "\n")
			footer := lines[len(lines)-2]
			for _, hint := range []string{": commands", "? help", action} {
				if !strings.Contains(footer, hint) {
					t.Fatalf("size %v focus %d lost %q in footer: %q", size, focus, hint, footer)
				}
			}
			if lipgloss.Width(view) > m.width || len(lines) > m.height {
				t.Fatalf("dashboard exceeded terminal %v", size)
			}
		}
	}
}

func TestGroupedHelpIsReachableInCompactTerminal(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	m.width, m.height = 42, 14
	m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'?'}})
	for _, section := range []string{"NAVIGATION", "WORKSPACES", "MONITORING", "COMMANDS & SESSIONS"} {
		found := false
		for i := 0; i < 60; i++ {
			view := ansi.Strip(m.View())
			if !strings.Contains(view, "Esc close") || !strings.Contains(view, "↑↓ scroll") {
				t.Fatal("help lost its navigation controls")
			}
			if strings.Contains(view, section) {
				found = true
				break
			}
			m.key(tea.KeyMsg{Type: tea.KeyDown})
		}
		if !found {
			t.Fatalf("help section %q is unreachable", section)
		}
	}
	m.key(tea.KeyMsg{Type: tea.KeyEsc})
	if m.overlay != "" {
		t.Fatal("Escape did not return to the dashboard")
	}
}

func TestMenuSelectionAndDetailsSurviveResize(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	path := "/" + strings.Repeat("long-parent/", 12) + "project-folder"
	m.inv.Config["MOLT_ROOT"] = path
	m.openScreen("settings")
	if m.menu.Items[0].Title != "Project folder" {
		t.Fatal("settings value is still packed into the command label")
	}
	for _, screen := range []string{"settings", "maintenance", "uninstall"} {
		m.openScreen(screen)
		for _, size := range [][2]int{{140, 42}, {100, 32}, {70, 24}, {42, 14}} {
			m.width, m.height = size[0], size[1]
			for i := range m.menu.Items {
				m.menu.Index = i
				view := ansi.Strip(m.View())
				if !strings.Contains(view, "› "+m.menu.Items[i].Title) || !strings.Contains(view, "i info") {
					t.Fatalf("%s size %v hid menu item %d or its details control", screen, size, i)
				}
				if lipgloss.Width(view) > m.width || lipgloss.Height(view) > m.height {
					t.Fatalf("menu exceeded terminal %v", size)
				}
			}
		}
	}
	m.openScreen("settings")
	m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'i'}})
	if m.overlay != "message" || !strings.Contains(m.dialog.Body, path) {
		t.Fatal("full setting value was lost")
	}
	for i := 0; i < 30; i++ {
		m.key(tea.KeyMsg{Type: tea.KeyDown})
	}
	visible := strings.NewReplacer("\n", "", "│", "", " ", "").Replace(ansi.Strip(m.View()))
	if !strings.Contains(visible, "project-folder") {
		t.Fatal("end of a long setting value is unreachable")
	}
	m.key(tea.KeyMsg{Type: tea.KeyEsc})
	if m.overlay != "native-menu" || m.menu.Index != 0 {
		t.Fatal("inspecting details lost the menu selection")
	}
}

func TestEveryCommandAndDescriptionIsReachable(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	m.width, m.height = 42, 14
	m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{':'}})
	for i, item := range palette() {
		view := ansi.Strip(m.View())
		if !strings.Contains(view, "› "+item.Title) || !strings.Contains(view, "Esc back") {
			t.Fatalf("command %d is hidden: %s", i, view)
		}
		m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'i'}})
		if m.overlay != "message" || m.dialog.Body != item.Description {
			t.Fatalf("command %d lost its description", i)
		}
		m.key(tea.KeyMsg{Type: tea.KeyEsc})
		if m.overlay != "palette" || m.paletteIndex != i {
			t.Fatal("inspecting a command lost its selection")
		}
		m.key(tea.KeyMsg{Type: tea.KeyDown})
	}
	m.key(tea.KeyMsg{Type: tea.KeyHome})
	if m.paletteIndex != 0 {
		t.Fatal("Home did not select the first command")
	}
	m.key(tea.KeyMsg{Type: tea.KeyEnd})
	if m.paletteIndex != len(palette())-1 {
		t.Fatal("End did not select the last command")
	}
}

func TestLongConfirmationCanBeReadBeforeCancelling(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	m.width, m.height = 42, 14
	confirmed := false
	m.confirm("Remove resources?", strings.Repeat("Remote resources may remain running. ", 10)+"Cleanup records will be deleted.", m.dashboard, func() tea.Cmd {
		confirmed = true
		return nil
	})
	for i := 0; i < 30; i++ {
		m.key(tea.KeyMsg{Type: tea.KeyDown})
	}
	view := ansi.Strip(m.View())
	visible := strings.NewReplacer("\n", "", "│", "", " ", "").Replace(view)
	if !strings.Contains(visible, "Cleanuprecordswillbedeleted.") {
		t.Fatal("end of the confirmation text is unreachable")
	}
	for _, text := range []string{"n/Esc cancel", "y confirm"} {
		if !strings.Contains(view, text) {
			t.Fatalf("confirmation lost %q: %s", text, view)
		}
	}
	m.key(tea.KeyMsg{Type: tea.KeyEsc})
	if confirmed || m.overlay != "" {
		t.Fatal("reading and cancelling a confirmation executed its action")
	}
}
