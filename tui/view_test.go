package main

import (
	"context"
	"fmt"
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
		for focus, action := range map[int]string{0: "c connect", 2: "Enter details", 3: "↑↓ scroll"} {
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
			if len(lines) != m.height {
				t.Fatalf("dashboard left unused terminal rows at size %v", size)
			}
		}
	}
}

func resourceModel(t *testing.T) *model {
	t.Helper()
	m := newModel(backend{Context: context.Background()})
	t.Cleanup(m.collectorCancel)
	m.inv.Hosts = []string{"vm", "other"}
	h := remote{Name: "vm", Docker: "ready", Metrics: metrics{CPU: 15, Load: "2.00 1.50 0.80"}}
	for i := 0; i < 18; i++ {
		name := fmt.Sprintf("molt-%02d", i)
		h.Containers = append(h.Containers, container{Names: name, State: "running", CPU: "12.5%", Memory: "256MiB / 2GiB"})
		m.inv.Projects = append(m.inv.Projects, project{ID: fmt.Sprintf("%012x", i+1), Name: fmt.Sprintf("app-%02d", i), Host: "vm", Container: name})
	}
	h.Containers = append(h.Containers, container{Names: "molt-unregistered", State: "exited"})
	m.remotes["vm"] = h
	m.remotes["other"] = remote{Name: "other", Docker: "ready", Containers: []container{{Names: "other-only", State: "running"}}}
	m.local.Load = "0.10 0.20 0.30"
	m.selected = m.inv.Projects[0].ID
	return m
}

func TestPassiveDashboardPanelsCannotTakeFocus(t *testing.T) {
	m := resourceModel(t)
	for _, want := range []int{2, 3, 0, 2} {
		m.key(tea.KeyMsg{Type: tea.KeyTab})
		if m.focus != want {
			t.Fatalf("Tab focused %d, want %d", m.focus, want)
		}
	}
	m.key(tea.KeyMsg{Type: tea.KeyShiftTab})
	if m.focus != 0 {
		t.Fatal("reverse navigation did not skip passive panels")
	}
	m.focus = 2
	m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'2'}})
	for _, point := range [][2]int{{75, 5}, {30, 2 + m.layout().top - 1}} {
		for _, button := range []tea.MouseButton{tea.MouseButtonLeft, tea.MouseButtonWheelDown} {
			m.Update(tea.MouseMsg{X: point[0], Y: point[1], Button: button, Action: tea.MouseActionPress})
			if m.focus != 2 || m.selected != m.inv.Projects[0].ID {
				t.Fatal("passive panel changed focus or workspace selection")
			}
		}
	}
	if strings.Contains(ansi.Strip(m.View()), "› LOCAL") {
		t.Fatal("local monitor has a focus marker")
	}
}

func TestCompactDockerSummaryIgnoresMouseWheel(t *testing.T) {
	m := resourceModel(t)
	m.width, m.height = 42, 14
	m.Update(tea.MouseMsg{X: 10, Y: m.height - 3, Button: tea.MouseButtonWheelDown})
	if m.hostIndex != 0 || m.focus != 0 {
		t.Fatal("passive Docker summary changed the selected VM")
	}
}

func TestDashboardShowsWorkspaceUsageAndLoadPeriods(t *testing.T) {
	m := resourceModel(t)
	m.focus = 2
	view := ansi.Strip(m.View())
	for _, value := range []string{"18 running", "1 stopped", "19 total", "12.5%", "256MiB", "LOAD 1/5/15m", "0.10 0.20 0.30"} {
		if !strings.Contains(view, value) {
			t.Fatalf("dashboard lost %q: %s", value, view)
		}
	}
	for i := 0; i < 18; i++ {
		if !strings.Contains(ansi.Strip(m.View()), fmt.Sprintf("app-%02d", i)) {
			t.Fatalf("workspace %d and its usage are unreachable", i)
		}
		m.key(tea.KeyMsg{Type: tea.KeyDown})
	}
	m.width, m.height = 42, 14
	m.key(tea.KeyMsg{Type: tea.KeyEnter})
	for _, value := range []string{"12.5%", "256MiB / 2GiB"} {
		found := false
		for i := 0; i < 30; i++ {
			if strings.Contains(ansi.Strip(m.View()), value) {
				found = true
				break
			}
			m.key(tea.KeyMsg{Type: tea.KeyDown})
		}
		if !found {
			t.Fatalf("small workspace detail lost %q", value)
		}
	}
}

func TestVMResourceInventoryIsCompleteAndLive(t *testing.T) {
	for _, size := range [][2]int{{140, 42}, {100, 32}, {70, 24}, {42, 14}} {
		t.Run(fmt.Sprint(size), func(t *testing.T) {
			m := resourceModel(t)
			m.width, m.height = size[0], size[1]
			m.key(tea.KeyMsg{Type: tea.KeyEnter})
			if m.overlay != "resources" {
				t.Fatal("Enter on VM did not open its resource inventory")
			}
			seen := map[string]bool{}
			for i := 0; i < 180; i++ {
				view := ansi.Strip(m.View())
				if lipgloss.Width(view) > m.width || lipgloss.Height(view) > m.height || !strings.Contains(view, "Esc close") {
					t.Fatal("resource inventory exceeded terminal or lost closing controls")
				}
				for _, c := range m.remotes["vm"].Containers {
					if strings.Contains(view, c.Names) {
						seen[c.Names] = true
					}
				}
				m.key(tea.KeyMsg{Type: tea.KeyDown})
			}
			if len(seen) != 19 {
				t.Fatalf("only %d of 19 containers reachable", len(seen))
			}
			h := m.remotes["vm"]
			h.Containers = []container{{Names: "refreshed-container", State: "running", CPU: "99%", Memory: "512MiB / 2GiB"}}
			m.Update(remoteMsg{h})
			view := ansi.Strip(m.View())
			if !strings.Contains(view, "refreshed-container") || !strings.Contains(view, "99%") {
				t.Fatal("resource refresh left old rows or an empty scrolled viewport")
			}
			m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{']'}})
			if !strings.Contains(ansi.Strip(m.View()), "other-only") || m.overlayScroll != 0 {
				t.Fatal("switching VM retained the old inventory or scroll")
			}
			m.key(tea.KeyMsg{Type: tea.KeyEsc})
			if m.overlay != "" || m.focus != 0 {
				t.Fatal("closing inventory did not return to VM focus")
			}
		})
	}
}

func TestStaleWorkspaceUsageIsNotPresentedAsCurrent(t *testing.T) {
	m := resourceModel(t)
	m.focus = 2
	h := m.remotes["vm"]
	h.Error = "SSH unavailable"
	m.remotes["vm"] = h
	view := ansi.Strip(m.View())
	if strings.Contains(view, "12.5%") || strings.Contains(view, "18 running") {
		t.Fatal("disconnected VM still shows current container usage/counts")
	}
}

func TestVMResourcesShowEmptyAndUnavailableStates(t *testing.T) {
	for _, state := range []struct {
		name, docker, failure, want string
	}{
		{"empty", "ready", "", "No owned containers"},
		{"docker unavailable", "unavailable", "", "Prepare VM"},
		{"disconnected", "ready", "SSH failed", "SSH failed"},
	} {
		t.Run(state.name, func(t *testing.T) {
			m := resourceModel(t)
			h := m.remotes["vm"]
			h.Docker, h.Error, h.Containers = state.docker, state.failure, nil
			m.remotes["vm"] = h
			m.key(tea.KeyMsg{Type: tea.KeyEnter})
			view := ansi.Strip(m.View())
			if !strings.Contains(view, state.want) || !strings.Contains(view, "Esc close") {
				t.Fatalf("inventory lost state or controls: %s", view)
			}
		})
	}
}

func TestMouseSelectsTheVisibleWorkspaceRow(t *testing.T) {
	for _, size := range [][2]int{{140, 42}, {100, 32}, {70, 24}, {42, 14}} {
		m := resourceModel(t)
		m.width, m.height, m.focus = size[0], size[1], 2
		m.selected = m.inv.Projects[12].ID
		want := m.filtered()[m.projectStart()].ID
		y := -1
		for i, line := range strings.Split(ansi.Strip(m.View()), "\n") {
			if strings.Contains(line, m.filtered()[m.projectStart()].Name) {
				y = i
				break
			}
		}
		if y < 0 {
			t.Fatalf("size %v: selected workspace row is not visible", size)
		}
		m.Update(tea.MouseMsg{X: 6, Y: y, Button: tea.MouseButtonLeft, Action: tea.MouseActionPress})
		if m.selected != want {
			t.Fatalf("size %v: mouse selected %s, want visible row %s", size, m.selected, want)
		}
	}
}

func TestMouseCanFocusActivityByItsTitle(t *testing.T) {
	for _, size := range [][2]int{{140, 42}, {100, 32}, {70, 24}} {
		m := resourceModel(t)
		m.width, m.height = size[0], size[1]
		for y, line := range strings.Split(ansi.Strip(m.View()), "\n") {
			if strings.Contains(line, "ACTIVITY / session events") {
				m.Update(tea.MouseMsg{X: 6, Y: y, Button: tea.MouseButtonLeft, Action: tea.MouseActionPress})
				if m.focus != 3 {
					t.Fatalf("size %v: clicking Activity title left focus on %d", size, m.focus)
				}
				break
			}
		}
	}
}

func TestNavigationEndsOnlyMoveTheFocusedArea(t *testing.T) {
	m := resourceModel(t)
	original := m.selected
	m.key(tea.KeyMsg{Type: tea.KeyEnd})
	if m.hostIndex != 1 || m.selected != original {
		t.Fatal("End on VM moved workspace selection")
	}
	m.key(tea.KeyMsg{Type: tea.KeyHome})
	if m.hostIndex != 0 {
		t.Fatal("Home on VM did not select the first VM")
	}
	m.focus = 3
	m.scroll = 1
	m.key(tea.KeyMsg{Type: tea.KeyEnd})
	if m.scroll != 0 || m.selected != original {
		t.Fatal("End on Activity moved workspace selection")
	}
	m.focus = 0
	m.key(tea.KeyMsg{Type: tea.KeyEnter})
	m.key(tea.KeyMsg{Type: tea.KeyEnd})
	if !strings.Contains(ansi.Strip(m.View()), "molt-unregistered") {
		t.Fatal("End in inventory did not reach the last container")
	}
	m.key(tea.KeyMsg{Type: tea.KeyHome})
	m.View()
	if m.overlayScroll != 0 {
		t.Fatal("Home in inventory did not return to the first row")
	}
	m.Update(tea.MouseMsg{X: 40, Y: 15, Button: tea.MouseButtonWheelDown})
	if m.overlayScroll != 1 {
		t.Fatal("mouse wheel did not scroll inventory")
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
