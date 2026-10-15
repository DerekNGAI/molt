package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

func developmentFixtureModel(t *testing.T) (*model, project) {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".molt"), 0700); err != nil {
		t.Fatal(err)
	}
	profile := `{"version":1,"name":"Fixture","actions":[{"id":"extra","label":"Extra command","kind":"task","argv":["printf","literal ; $(touch nope)"],"cwd":"."},{"id":"test","label":"Run tests","kind":"task","argv":["npm","test"],"cwd":"."},{"id":"dev","label":"Development server","kind":"service","argv":["npm","run","dev"],"cwd":"."},{"id":"setup","label":"Install dependencies","kind":"task","argv":["npm","ci"],"cwd":"."}],"ports":[{"id":"web","label":"Web application","service":"dev","container_port":3000,"local_port":3000,"scheme":"http"}],"android":{"enabled":false}}`
	if err := os.WriteFile(filepath.Join(root, ".molt", "development.json"), []byte(profile), 0600); err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, "state", "tmp"), 0700); err != nil {
		t.Fatal(err)
	}
	m := newModel(backend{Home: home, Context: context.Background()})
	t.Cleanup(m.collectorCancel)
	p := project{ID: "aaaaaaaaaaaa", Name: "Fixture", Path: root, Active: true}
	m.inv.Projects = []project{p}
	return m, p
}

func menuTitles(m *model) string {
	var titles []string
	for _, item := range m.menu.Items {
		titles = append(titles, item.Title)
	}
	return strings.Join(titles, "\n")
}

func chooseDevelopmentItem(t *testing.T, m *model, title string) tea.Cmd {
	t.Helper()
	for i, item := range m.menu.Items {
		if strings.HasPrefix(item.Title, title) {
			m.menu.Index = i
			return item.Run()
		}
	}
	t.Fatalf("menu has no %q: %s", title, menuTitles(m))
	return nil
}

func TestDashboardDevelopmentEntrypoints(t *testing.T) {
	m, p := developmentFixtureModel(t)
	m.projectMenu(p)
	if !strings.Contains(menuTitles(m), "Development menu") {
		t.Fatal("project management has no development menu")
	}
	m.openScreen("development:" + p.ID)
	if m.overlay != "native-menu" || !strings.Contains(m.menu.Title, "Development") {
		t.Fatalf("development initial screen unavailable: %s / %s", m.overlay, m.dialog.Title)
	}
	m.openScreen("development:bbbbbbbbbbbb")
	if m.overlay != "message" || !strings.Contains(m.dialog.Body, "registered") {
		t.Fatal("unregistered development screen did not report its reason")
	}
}

func TestDashboardAuxiliaryContainersHaveNoOpenCodeHealth(t *testing.T) {
	data := "system\t100\t60\t1024\t512\t2048\t512\t12\t0.1\t0\t0\tFixture\ndocker\tready\ncontainer\t{\"Names\":\"device\",\"State\":\"running\",\"Role\":\"android\",\"ProjectID\":\"aaaaaaaaaaaa\"}\nhealth\tdevice\tbroken\n"
	h, err := parseRemote("vm", []byte(data))
	if err != nil {
		t.Fatal(err)
	}
	p := project{ID: "aaaaaaaaaaaa", Container: "device"}
	if p.health(h) != "—" {
		t.Fatal("Android container is presented as a broken OpenCode server")
	}
}

func fixtureDevelopmentStatus(id string) DevelopmentStatus {
	return DevelopmentStatus{Version: 1, ProjectID: id, Name: "Fixture", Environment: DevelopmentEnvironmentStatus{State: "ready", Revision: strings.Repeat("a", 64)}, Services: []DevelopmentServiceStatus{{ID: "dev", Label: "Development server", State: "running"}}, Ports: []DevelopmentForwardStatus{{ID: "web", Label: "Web application", Service: "dev", ContainerPort: 3000, VMPort: 31000, LocalPort: 32000, Scheme: "http", URL: "http://127.0.0.1:32000", State: "forwarded"}}, Android: DevelopmentAndroidStatus{State: "disabled", ViewerState: "closed"}, Cleanup: DevelopmentCleanupStatus{State: "clean", Remaining: []string{}}}
}

func writeDevelopmentJSON(t *testing.T, path string, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if path != "" {
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	return data
}

func installDevelopmentFixtureCLI(t *testing.T, m *model, status DevelopmentStatus) {
	t.Helper()
	data, err := os.ReadFile("testdata/development/cli.sh")
	if err != nil {
		t.Fatal(err)
	}
	m.b.CLI = filepath.Join(m.b.Home, "fixture-cli")
	if err := os.WriteFile(m.b.CLI, data, 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("MOLT_DEVELOPMENT_FIXTURE", m.b.Home)
	writeDevelopmentJSON(t, filepath.Join(m.b.Home, "status-"+status.ProjectID+".json"), status)
	writeDevelopmentJSON(t, filepath.Join(m.b.Home, "ports-"+status.ProjectID+".json"), status.Ports)
}

func TestDashboardDevelopmentObservationAndRoutes(t *testing.T) {
	m, p := developmentFixtureModel(t)
	installDevelopmentFixtureCLI(t, m, fixtureDevelopmentStatus(p.ID))
	cmd := m.openScreen("development:" + p.ID)
	if cmd == nil {
		t.Fatal("no read-only status fetch")
	}
	m.Update(cmd())
	titles := menuTitles(m)
	for _, label := range []string{"Install dependencies", "Development server", "Run tests", "Extra command"} {
		if !strings.Contains(titles, label) {
			t.Fatalf("declared action missing: %s", titles)
		}
	}
	if strings.Index(titles, "Install dependencies") > strings.Index(titles, "Development server") || strings.Index(titles, "Development server") > strings.Index(titles, "Run tests") || strings.Index(titles, "Run tests") > strings.Index(titles, "Extra command") || strings.Contains(titles, "Run build") {
		t.Fatal("actions violate the declared guideline order")
	}
	log, _ := os.ReadFile(filepath.Join(m.b.Home, "commands"))
	if string(log) != "dev\t@aaaaaaaaaaaa\tstatus\t--json\n" {
		t.Fatalf("observation mutated or invented commands: %s", log)
	}
	chooseDevelopmentItem(t, m, "Run tests")
	if m.overlay != "session" || m.sessionTitle != "Run tests" {
		t.Fatal("repository task did not open its embedded PTY")
	}
	m.sessionCancel()
	m.sessionCancel = nil
	back(m.sessionBack)
	chooseDevelopmentItem(t, m, "Development server")
	if m.overlay != "action" || m.action == "" {
		t.Fatal("service did not use captured managed action")
	}
	m.cancelAction()
	m.Update(actionMsg{Name: m.action, Work: m.work, Error: errors.New("fixture failure")})
	if m.dialog.Retry == nil || !strings.Contains(m.dialog.Title, "Failed") {
		t.Fatal("failed service has no retry/result")
	}
	m.key(tea.KeyMsg{Type: tea.KeyEsc})
	if m.overlay != "native-menu" || !strings.HasPrefix(m.menu.Items[m.menu.Index].Title, "Development server") {
		t.Fatal("service result lost original menu selection")
	}
}

func TestDashboardDevelopmentStaleAndInvalidStatus(t *testing.T) {
	m, p := developmentFixtureModel(t)
	status := fixtureDevelopmentStatus(p.ID)
	installDevelopmentFixtureCLI(t, m, status)
	m.Update(m.openScreen("development:" + p.ID)())
	status.Ports[0].URL = "https://attacker.example:32000/"
	writeDevelopmentJSON(t, filepath.Join(m.b.Home, "status-"+p.ID+".json"), status)
	m.Update(chooseDevelopmentItem(t, m, "Refresh status")())
	text := m.menu.Help + strings.Join(m.menu.Details, "\n") + menuTitles(m)
	if !strings.Contains(text, "stale") || !strings.Contains(text, "unknown") || strings.Contains(text, "attacker.example") {
		t.Fatalf("invalid observation claims current health or exposes URL: %s", text)
	}
	if err := os.Remove(filepath.Join(p.Path, ".molt", "development.json")); err != nil {
		t.Fatal(err)
	}
	m.Update(chooseDevelopmentItem(t, m, "Refresh status")())
	if strings.Contains(menuTitles(m), "Run tests") || !strings.Contains(m.menu.Help+strings.Join(m.menu.Details, "\n"), "profile") {
		t.Fatal("missing local profile manufactured actions")
	}
	for _, title := range []string{"Prepare environment", "Stop development", "Remove project"} {
		if !strings.Contains(menuTitles(m), title) {
			t.Fatalf("missing profile hides native %s control", title)
		}
	}
}

func TestDashboardDevelopmentAndroidStatesAndConfirmations(t *testing.T) {
	for _, state := range []string{"disabled", "unsupported", "starting", "ready", "failed", "unknown"} {
		t.Run(state, func(t *testing.T) {
			m, p := developmentFixtureModel(t)
			status := fixtureDevelopmentStatus(p.ID)
			status.Android = DevelopmentAndroidStatus{Enabled: state != "disabled", State: state, Reason: "capability fixture reason", ViewerState: "failed"}
			installDevelopmentFixtureCLI(t, m, status)
			m.Update(m.openScreen("development:" + p.ID)())
			chooseDevelopmentItem(t, m, "Android device")
			if !strings.Contains(m.menu.Help, state) || !strings.Contains(strings.Join(m.menu.Details, "\n"), "capability fixture reason") {
				t.Fatal("Android observation or unsupported reason hidden")
			}
			chooseDevelopmentItem(t, m, "Reset Android data")
			if m.overlay != "confirm" || !strings.Contains(m.dialog.Body, p.Name) || !strings.Contains(m.dialog.Body, "data") {
				t.Fatal("Android reset has no per-repository data confirmation")
			}
			m.inv.Projects = []project{{ID: "bbbbbbbbbbbb", Name: "other"}}
			m.dialog.Yes()
			if m.action != "Reset Android data / Fixture" {
				t.Fatal("confirmation changed project after selection changed")
			}
			m.cancelAction()
		})
	}
}

func TestDashboardDevelopmentCacheRevisionAndFailure(t *testing.T) {
	m, p := developmentFixtureModel(t)
	installDevelopmentFixtureCLI(t, m, fixtureDevelopmentStatus(p.ID))
	m.Update(m.openScreen("development:" + p.ID)())
	chooseDevelopmentItem(t, m, "Preview / clean cache")
	preview := DevelopmentCachePreview{Version: 1, ProjectID: p.ID, Revision: strings.Repeat("b", 64), ReclaimableBytes: 123, Items: []DevelopmentCacheItem{{ID: "output", Kind: "build-output", Path: "/owned/cache/output", Bytes: 123}}}
	m.finishQuery(queryMsg{ID: m.queryID, Data: writeDevelopmentJSON(t, "", preview)})
	chooseDevelopmentItem(t, m, "Clean displayed cache")
	if m.overlay != "confirm" || !strings.Contains(m.dialog.Body, "123 bytes") || !strings.Contains(m.dialog.Body, "/owned/cache/output") || !strings.Contains(m.dialog.Body, preview.Revision) {
		t.Fatal("cleanup confirmation differs from its exact preview")
	}
	m.dialog.Yes()
	m.cancelAction()
	m.Update(actionMsg{Name: m.action, Work: m.work, Error: errors.New("cache inventory changed")})
	if m.overlay != "message" || m.dialog.Retry == nil {
		t.Fatal("failed cleanup has no path to a new preview")
	}
	m.dialog.Retry()
	if m.overlay != "loading" || m.action != "" || m.dialog.Title != "Development cache / Fixture" {
		t.Fatal("cleanup retry reused destructive command instead of previewing again")
	}
}

func TestDashboardDevelopmentCompactMenuAndExit(t *testing.T) {
	t.Setenv("NO_COLOR", "1")
	m, p := developmentFixtureModel(t)
	installDevelopmentFixtureCLI(t, m, fixtureDevelopmentStatus(p.ID))
	m.Update(m.openScreen("development:" + p.ID)())
	for _, size := range [][2]int{{42, 14}, {70, 24}, {100, 32}} {
		m.width, m.height = size[0], size[1]
		m.key(tea.KeyMsg{Type: tea.KeyEnd})
		if !strings.Contains(m.View(), "› "+m.menu.Items[len(m.menu.Items)-1].Title) {
			t.Fatal("compact menu hides last selection")
		}
	}
	m.key(tea.KeyMsg{Type: tea.KeyCtrlC})
	log, _ := os.ReadFile(filepath.Join(m.b.Home, "commands"))
	if strings.Contains(string(log), "\tstop") || m.action != "" {
		t.Fatal("leaving menu stopped persistent VM services")
	}
}

func TestDashboardDevelopmentPortsValidation(t *testing.T) {
	status := fixtureDevelopmentStatus("aaaaaaaaaaaa")
	for _, ports := range [][]DevelopmentForwardStatus{status.Ports, {}} {
		decoded, err := decodeDevelopmentPorts(writeDevelopmentJSON(t, "", ports), status.ProjectID)
		if err != nil || len(decoded) != len(ports) {
			t.Fatalf("valid port array rejected: %v", err)
		}
	}
	for _, malicious := range []string{"http://example.com:32000", "http://localhost:32000", "http://127.0.0.1:32001", "http://secret@127.0.0.1:32000", "http://127.0.0.1:32000/\x1b[2J"} {
		status.Ports[0].URL = malicious
		if _, err := decodeDevelopmentPorts(writeDevelopmentJSON(t, "", status.Ports), status.ProjectID); err == nil {
			t.Fatalf("malicious URL accepted: %q", malicious)
		}
	}
}

func TestDashboardDevelopmentPortCopyAndOpenKeepProject(t *testing.T) {
	m, p := developmentFixtureModel(t)
	clipboard := clipboardFixture(t, false)
	status := fixtureDevelopmentStatus(p.ID)
	installDevelopmentFixtureCLI(t, m, status)
	m.Update(m.openScreen("development:" + p.ID)())
	chooseDevelopmentItem(t, m, "Application URLs")
	m.finishQuery(queryMsg{ID: m.queryID, Data: writeDevelopmentJSON(t, "", status.Ports)})
	chooseDevelopmentItem(t, m, "Web application")
	chooseDevelopmentItem(t, m, "Copy actual URL")
	m.inv.Projects = append(m.inv.Projects, project{ID: "bbbbbbbbbbbb", Name: "other"})
	m.selected = "bbbbbbbbbbbb"
	status.Ports[0].LocalPort = 32001
	status.Ports[0].URL = "http://127.0.0.1:32001"
	cmd := m.finishQuery(queryMsg{ID: m.queryID, Data: writeDevelopmentJSON(t, "", status.Ports)})
	finishCopy(t, m, cmd, clipboard, status.Ports[0].URL)
	if !strings.Contains(m.menu.Help, status.Ports[0].URL) {
		t.Fatal("URL menu still shows the old mapping after copying the current URL")
	}
	chooseDevelopmentItem(t, m, "Open in browser")
	cmd = m.finishQuery(queryMsg{ID: m.queryID, Data: writeDevelopmentJSON(t, "", status.Ports)})
	for _, command := range cmd().(tea.BatchMsg) {
		msg := command()
		if result, ok := msg.(actionMsg); ok {
			m.Update(result)
		}
	}
	log, _ := os.ReadFile(filepath.Join(m.b.Home, "commands"))
	if !strings.Contains(string(log), "dev\t@aaaaaaaaaaaa\topen\tweb\n") || strings.Contains(string(log), "@bbbbbbbbbbbb\topen") {
		t.Fatalf("open lost original project/port ID: %s", log)
	}
}

func TestDashboardDevelopmentLateObservationAndNoAuthentication(t *testing.T) {
	m, p := developmentFixtureModel(t)
	p.Host = "unreachable-vm"
	m.inv.Projects = []project{p}
	status := fixtureDevelopmentStatus(p.ID)
	installDevelopmentFixtureCLI(t, m, status)
	msg := m.openScreen("development:" + p.ID)()
	m.inv.Projects = []project{{ID: "bbbbbbbbbbbb", Name: "other"}}
	m.Update(msg)
	if len(m.developments) != 0 {
		t.Fatal("late observation attached to changed project registry")
	}
	log, _ := os.ReadFile(filepath.Join(m.b.Home, "commands"))
	if strings.Contains(string(log), "connection") {
		t.Fatal("status observation prompted for SSH authentication")
	}
	m.inv.Projects = []project{p}
	status.ProjectID = "bbbbbbbbbbbb"
	writeDevelopmentJSON(t, filepath.Join(m.b.Home, "status-"+p.ID+".json"), status)
	m.Update(m.openScreen("development:" + p.ID)())
	if m.developments[p.ID].Error == "" || m.developments[p.ID].Status.Version != 0 {
		t.Fatal("wrong-project status accepted")
	}
}

func TestDashboardDevelopmentOldReadinessExpires(t *testing.T) {
	m, p := developmentFixtureModel(t)
	status := fixtureDevelopmentStatus(p.ID)
	installDevelopmentFixtureCLI(t, m, status)
	m.Update(m.openScreen("development:" + p.ID)())
	o := m.developments[p.ID]
	o.At = time.Now().Add(-time.Minute)
	m.developments[p.ID] = o
	m.renderDevelopmentMenu(p, "main", m.dashboard)
	if !strings.Contains(m.menu.Help, "unknown") || !strings.Contains(m.menu.Help, "stale") {
		t.Fatal("cached readiness survived without observation")
	}
}

func TestDashboardDevelopmentQueryTimeout(t *testing.T) {
	m, p := developmentFixtureModel(t)
	m.developmentCache(p, m.dashboard)
	m.finishQuery(queryMsg{ID: m.queryID, Error: context.DeadlineExceeded})
	if !strings.Contains(m.dialog.Body, "8s") || strings.Contains(m.dialog.Body, "30s") {
		t.Fatal("bounded development query reports the wrong timeout")
	}
}

func TestDashboardDevelopmentResourceRoles(t *testing.T) {
	m, p := developmentFixtureModel(t)
	p.Host = "vm"
	m.inv.Projects, m.inv.Hosts = []project{p}, []string{"vm"}
	m.remotes["vm"] = remote{Name: "vm", Docker: "ready", Containers: []container{{Names: "android-device", State: "running", Role: "android", ProjectID: p.ID}, {Names: "nix-builder", State: "exited", Role: "builder", ProjectID: p.ID}}}
	body := strings.Join(m.resourceLines(90), "\n")
	for _, text := range []string{"Role: android", "Role: builder", "Repository: Fixture"} {
		if !strings.Contains(body, text) {
			t.Fatalf("resource view lost %q: %s", text, body)
		}
	}
	if strings.Contains(body, "OpenCode:") {
		t.Fatal("auxiliary resources have OpenCode health labels")
	}
}

func TestDashboardDevelopmentEnvironmentStates(t *testing.T) {
	for _, state := range []string{"absent", "preparing", "ready", "blocked", "failed", "unknown"} {
		t.Run(state, func(t *testing.T) {
			m, p := developmentFixtureModel(t)
			status := fixtureDevelopmentStatus(p.ID)
			status.Environment.State, status.Environment.Reason = state, "environment fixture reason"
			status.Cleanup = DevelopmentCleanupStatus{State: "failed", Remaining: []string{"owned-builder", "/owned/cache/output"}, Reason: "partial cleanup"}
			installDevelopmentFixtureCLI(t, m, status)
			m.Update(m.openScreen("development:" + p.ID)())
			chooseDevelopmentItem(t, m, "Inspect development status")
			for _, text := range []string{"Environment: " + state, "environment fixture reason", "owned-builder", "/owned/cache/output", "partial cleanup"} {
				if !strings.Contains(m.dialog.Body, text) {
					t.Fatalf("development status lost %q: %s", text, m.dialog.Body)
				}
			}
		})
	}
}

func TestDashboardDevelopmentViewerExitAndEnableConfirmation(t *testing.T) {
	m, p := developmentFixtureModel(t)
	status := fixtureDevelopmentStatus(p.ID)
	installDevelopmentFixtureCLI(t, m, status)
	m.Update(m.openScreen("development:" + p.ID)())
	chooseDevelopmentItem(t, m, "Android device")
	chooseDevelopmentItem(t, m, "Enable Android")
	if m.overlay != "confirm" || m.action != "" || !strings.Contains(m.dialog.Body, p.Name) {
		t.Fatal("Android enable changed preference without project confirmation")
	}
	m.key(tea.KeyMsg{Type: tea.KeyEsc})
	for _, viewer := range []string{"running", "closed", "failed", "unknown"} {
		status.Android = DevelopmentAndroidStatus{Enabled: true, State: "ready", ViewerState: viewer, Reason: "private helper fixture"}
		msg := developmentMsg{Project: p, developmentObservation: developmentObservation{Status: status, At: time.Now()}}
		m.Update(msg)
		if !strings.Contains(m.menu.Help, "Viewer: "+viewer) {
			t.Fatalf("viewer lifecycle observation is hidden: %s", m.menu.Help)
		}
	}
}

func TestDashboardDevelopmentUntrustedDisplayText(t *testing.T) {
	m, p := developmentFixtureModel(t)
	malicious := "\x1b]52;c;fixture-secret\a"
	p.Name += malicious
	m.inv.Projects = []project{p}
	m.openScreen("development:" + p.ID)
	if strings.Contains(m.View(), malicious) {
		t.Fatal("untrusted repository name emitted a terminal clipboard escape")
	}
	chooseDevelopmentItem(t, m, "Stop development")
	if strings.Contains(m.dialog.Body, malicious) {
		t.Fatal("confirmation retained unsafe terminal text for copying")
	}
}

func TestDashboardDevelopmentDetailsShortcut(t *testing.T) {
	m, p := developmentFixtureModel(t)
	m.focus = 2
	m.key(tea.KeyMsg{Type: tea.KeyEnter})
	m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'D'}})
	if m.overlay != "native-menu" || m.menu.DevelopmentID != p.ID {
		t.Fatal("workspace details cannot open the development menu")
	}
}

func TestDashboardDevelopmentSelectionSurvivesProfileChange(t *testing.T) {
	m, p := developmentFixtureModel(t)
	status := fixtureDevelopmentStatus(p.ID)
	installDevelopmentFixtureCLI(t, m, status)
	m.Update(m.openScreen("development:" + p.ID)())
	o := m.developments[p.ID]
	var service, setup DevelopmentAction
	for _, action := range o.Spec.Actions {
		if action.ID == "dev" {
			service = action
		} else if action.ID == "setup" {
			setup = action
		}
	}
	o.Spec.Actions = []DevelopmentAction{service}
	m.receiveDevelopment(developmentMsg{Project: p, developmentObservation: o})
	m.menu.Index = 0
	service.Label = "Renamed service"
	o.Spec.Actions = []DevelopmentAction{setup, service}
	m.receiveDevelopment(developmentMsg{Project: p, developmentObservation: o})
	m.key(tea.KeyMsg{Type: tea.KeyEnter})
	if m.action != "Renamed service / Fixture" {
		t.Fatal("profile refresh moved selection onto a different action")
	}
	m.cancelAction()
}

func TestDashboardDevelopmentURLBackNavigation(t *testing.T) {
	m, p := developmentFixtureModel(t)
	status := fixtureDevelopmentStatus(p.ID)
	installDevelopmentFixtureCLI(t, m, status)
	m.Update(m.openScreen("development:" + p.ID)())
	chooseDevelopmentItem(t, m, "Application URLs")
	m.finishQuery(queryMsg{ID: m.queryID, Data: writeDevelopmentJSON(t, "", status.Ports)})
	chooseDevelopmentItem(t, m, "Web application")
	chooseDevelopmentItem(t, m, "Open in browser")
	status.Ports[0].URL = "http://attacker.example:32000"
	m.finishQuery(queryMsg{ID: m.queryID, Data: writeDevelopmentJSON(t, "", status.Ports)})
	m.key(tea.KeyMsg{Type: tea.KeyEnter})
	for _, title := range []string{"Application URLs", "Development"} {
		m.key(tea.KeyMsg{Type: tea.KeyEsc})
		if m.overlay != "native-menu" || !strings.HasPrefix(m.menu.Title, title) {
			t.Fatalf("back skipped %s: %s / %s", title, m.overlay, m.menu.Title)
		}
	}
	m.key(tea.KeyMsg{Type: tea.KeyEsc})
	if m.overlay != "" {
		t.Fatal("initial development screen did not return to dashboard")
	}
}
