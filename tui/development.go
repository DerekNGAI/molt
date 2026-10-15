package main

import (
	bytebuf "bytes"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

type developmentObservation struct {
	Status              DevelopmentStatus
	Spec                DevelopmentSpec
	Error, ProfileError string
	At                  time.Time
}

type developmentMsg struct {
	Project project
	developmentObservation
}

// Stop an invalid CLI response from allocating unbounded output before decoding.
type developmentBuffer struct {
	bytebuf.Buffer
	Limit int
}

func (b *developmentBuffer) Write(data []byte) (int, error) {
	if len(data) > b.Limit-b.Len() {
		return 0, fmt.Errorf("development output exceeds %d bytes", b.Limit)
	}
	return b.Buffer.Write(data)
}

func (b backend) observeDevelopment(p project) developmentMsg {
	msg := developmentMsg{Project: p}
	spec, err := readDevelopmentSpec(filepath.Join(p.Path, ".molt", "development.json"), p.Path)
	if err != nil {
		msg.ProfileError = clean(err.Error())
	} else {
		msg.Spec = spec
	}
	data, err := b.output(8*time.Second, "dev", "@"+p.ID, "status", "--json")
	if err == nil {
		msg.Status, err = decodeDevelopmentStatus(data)
		if err == nil && msg.Status.ProjectID != p.ID {
			err = fmt.Errorf("development status belongs to another project")
		}
	}
	if err != nil {
		msg.Status = DevelopmentStatus{}
		msg.Error = clean(err.Error())
	} else {
		msg.At = time.Now()
	}
	return msg
}

func (m *model) observeDevelopment(p project) tea.Cmd {
	if !projectID.MatchString(p.ID) || m.developmentBusy[p.ID] || m.exclusive || m.installing {
		return nil
	}
	m.developmentBusy[p.ID] = true
	b := m.b
	b.Context = m.collectorContext
	return m.collector(func() tea.Msg { return b.observeDevelopment(p) })
}

func (m *model) developmentTarget() project {
	id := ""
	if m.overlay == "detail" {
		return m.current()
	}
	if m.overlay == "native-menu" {
		id = m.menu.DevelopmentID
	}
	for _, p := range m.inv.Projects {
		if p.ID == id {
			return p
		}
	}
	return project{}
}

func (m *model) receiveDevelopment(msg developmentMsg) {
	m.developmentBusy[msg.Project.ID] = false
	registered := false
	for _, p := range m.inv.Projects {
		if p.ID == msg.Project.ID && p.Path == msg.Project.Path {
			registered = true
			break
		}
	}
	if !registered {
		return
	}
	o := msg.developmentObservation
	if o.Error != "" {
		previous := m.developments[msg.Project.ID]
		o.Status, o.At = previous.Status, previous.At
	}
	m.developments[msg.Project.ID] = o
	if m.overlay == "native-menu" && m.menu.DevelopmentID == msg.Project.ID {
		m.restoreDevelopmentMenu(msg.Project, m.menu)
	}
}

func (o developmentObservation) fresh() bool {
	return o.Error == "" && !o.At.IsZero() && time.Since(o.At) <= 4*refreshInterval
}

func (o developmentObservation) state(value string) string {
	if o.fresh() {
		return value
	}
	if value != "" {
		return "unknown (last: " + value + "; stale)"
	}
	return "unknown"
}

func developmentSummary(o developmentObservation) string {
	s := o.Status
	body := "Environment: " + o.state(s.Environment.State)
	if s.Environment.Reason != "" {
		body += "\n" + s.Environment.Reason
	}
	if o.Error != "" {
		body += "\nObservation unavailable: " + o.Error
	}
	if !o.At.IsZero() {
		body += "\nLast observation: " + o.At.Format(time.RFC3339)
	}
	if o.ProfileError != "" {
		body += "\nLocal profile unavailable: " + o.ProfileError
	} else if o.Spec.Version != 1 {
		body += "\nLocal profile: checking"
	}
	for _, s := range s.Services {
		body += "\nService " + s.Label + ": " + o.state(s.State)
		if s.Reason != "" {
			body += "\n" + s.Reason
		}
	}
	for _, port := range s.Ports {
		body += "\n" + developmentPortSummary(o, port)
	}
	body += "\n\n" + developmentAndroidSummary(o)
	if s.Version == 1 {
		body += fmt.Sprintf("\n\nCache: %d bytes", s.Cache.ReclaimableBytes)
		if !o.fresh() {
			body += " (last observation; stale)"
		}
		body += "\n" + s.Cache.Reason + "\nCleanup: " + o.state(s.Cleanup.State) + "\n" + s.Cleanup.Reason
		for _, resource := range s.Cleanup.Remaining {
			body += "\nRemaining: " + resource
		}
	}
	body += "\n\nClosing this menu leaves VM services running. Stop development preserves persistent data."
	return body
}

func developmentPortSummary(o developmentObservation, p DevelopmentForwardStatus) string {
	body := p.Label + ": " + o.state(p.State)
	if p.URL != "" {
		body += "\n" + p.URL
	}
	body += fmt.Sprintf("\nContainer %d → VM loopback %d → local loopback %d", p.ContainerPort, p.VMPort, p.LocalPort)
	if p.Reason != "" {
		body += "\n" + p.Reason
	}
	return body + "\nHTTP and WebSockets use the same TCP tunnel."
}

func developmentAndroidSummary(o developmentObservation) string {
	a := o.Status.Android
	body := "Android: " + o.state(a.State) + " · Viewer: " + o.state(a.ViewerState)
	if a.Reason != "" {
		body += "\n" + a.Reason
	}
	if a.Container != "" {
		body += "\nContainer: " + a.Container
	}
	if a.ADBLocalPort != 0 || a.ADBServerLocalPort != 0 {
		body += fmt.Sprintf("\nADB VM/local: %d/%d · private server: %d", a.ADBVMPort, a.ADBLocalPort, a.ADBServerLocalPort)
	}
	return body + "\nDevice data belongs to this repository. Viewer and ADB helpers are managed by Molt."
}

func (m *model) developmentMenu(p project, returnTo func() tea.Cmd) tea.Cmd {
	if !projectID.MatchString(p.ID) {
		return m.showMessage("Development unavailable", "Choose a registered repository.", returnTo)
	}
	m.renderDevelopmentMenu(p, "main", returnTo)
	return m.observeDevelopment(p)
}

func (m *model) restoreDevelopmentMenu(p project, snapshot menuState) {
	if strings.HasPrefix(snapshot.DevelopmentPage, "port:") {
		m.developmentPortMenu(p, strings.TrimPrefix(snapshot.DevelopmentPage, "port:"), snapshot.Back)
	} else {
		m.renderDevelopmentMenu(p, snapshot.DevelopmentPage, snapshot.Back)
	}
	m.menu.Index = min(snapshot.Index, max(0, len(m.menu.Items)-1))
	if snapshot.Index >= 0 && snapshot.Index < len(snapshot.Keys) {
		key := snapshot.Keys[snapshot.Index]
		for i, current := range m.menu.Keys {
			if key == current {
				m.menu.Index = i
				return
			}
		}
		for i, current := range m.menu.Keys {
			if current == "Inspect development status" {
				m.menu.Index = i
				return
			}
		}
	}
}

func (m *model) developmentReturn(p project) func() tea.Cmd {
	snapshot := m.menu
	return func() tea.Cmd {
		m.restoreDevelopmentMenu(p, snapshot)
		return m.observeDevelopment(p)
	}
}

func (m *model) renderDevelopmentMenu(p project, page string, returnTo func() tea.Cmd) {
	o := m.developments[p.ID]
	var items []menuItem
	var details, keys []string
	add := func(title, detail string, run func() tea.Cmd) {
		items = append(items, menuItem{title, run})
		details = append(details, detail)
		keys = append(keys, title)
	}
	title, help := "Development / "+p.Name, "Environment: "+o.state(o.Status.Environment.State)+" · Android: "+o.state(o.Status.Android.State)
	backToMenu := func() tea.Cmd { return back(m.developmentReturn(p)) }
	if page == "android" {
		title, help = "Android / "+p.Name, developmentAndroidSummary(o)
		for _, entry := range [][2]string{{"check", "Check Android capability"}, {"enable", "Enable Android"}, {"disable", "Disable Android"}, {"prepare-host", "Prepare Android host"}, {"start", "Start Android device"}, {"stop", "Stop Android device"}, {"view", "Open Android viewer"}, {"logs", "Android logs"}, {"reset", "Reset Android data"}} {
			verb, label := entry[0], entry[1]
			add(label, developmentAndroidSummary(o), func() tea.Cmd { return m.developmentAndroidAction(p, verb, label) })
		}
	} else if page == "ports" {
		title, help = "Application URLs / "+p.Name, "Actual loopback mappings. HTTP and WebSockets use the same tunnel."
		for _, port := range o.Status.Ports {
			port := port
			add(port.Label+" · "+o.state(port.State), developmentPortSummary(o, port), func() tea.Cmd { return m.developmentPortMenu(p, port.ID, m.developmentReturn(p)) })
			keys[len(keys)-1] = "port:" + port.ID
		}
		if len(o.Status.Ports) == 0 {
			add("No observed app ports", "Prepare/start declared services to allocate mappings. Observation does not start them.", backToMenu)
		}
		add("Refresh mappings", "Read-only port observation.", func() tea.Cmd { return m.developmentPorts(p, returnTo) })
	} else {
		ordered := []DevelopmentAction{}
		for _, id := range []string{"setup", "dev", "test", "check", "build"} {
			for _, action := range o.Spec.Actions {
				if action.ID == id {
					ordered = append(ordered, action)
				}
			}
		}
		for _, action := range o.Spec.Actions {
			if !contains([]string{"setup", "dev", "test", "check", "build"}, action.ID) {
				ordered = append(ordered, action)
			}
		}
		for _, action := range ordered {
			action := action
			label := action.Label
			if action.Kind == "service" {
				state := "unknown"
				for _, service := range o.Status.Services {
					if service.ID == action.ID {
						state = o.state(service.State)
					}
				}
				label += " · " + state
			}
			add(label, "Declared "+action.Kind+" · directory: "+action.Cwd, func() tea.Cmd {
				if action.Kind == "task" {
					return m.developmentTerminal(p, action.Label, m.developmentReturn(p), "run", action.ID)
				}
				return m.developmentRun(p, action.Label, m.developmentReturn(p), "run", action.ID)
			})
			keys[len(keys)-1] = "run:" + action.ID
		}
		add("Inspect development status", developmentSummary(o), func() tea.Cmd {
			return m.showMessage("Development status / "+p.Name, developmentSummary(m.developments[p.ID]), m.developmentReturn(p))
		})
		add("Refresh status", developmentSummary(o), func() tea.Cmd { return m.observeDevelopment(p) })
		add("Prepare environment", "Generate only missing configuration and build; keep existing definitions.", func() tea.Cmd { return m.developmentRun(p, "Prepare environment", m.developmentReturn(p), "prepare") })
		add("Start development", "Start declared services and localhost forwards.", func() tea.Cmd { return m.developmentRun(p, "Start development", m.developmentReturn(p), "start") })
		add("Stop development", "Stop services, device, viewer, and app forwards; preserve source and persistent data.", func() tea.Cmd {
			returnTo := m.developmentReturn(p)
			return m.confirm("Stop development / "+p.Name, "Stop services, Android, viewer, and app forwards for "+p.Name+"? Source, dependencies, and persistent service/device data are kept.", returnTo, func() tea.Cmd { return m.developmentRun(p, "Stop development", returnTo, "stop") })
		})
		add("Development shell", "Open an interactive shell in the prepared environment.", func() tea.Cmd {
			return m.developmentTerminal(p, "Development shell / "+p.Name, m.developmentReturn(p), "shell")
		})
		add("Service logs", "Bounded output for all services or one declared service.", func() tea.Cmd { return m.developmentLogs(p, m.developmentReturn(p)) })
		add("Application URLs", "Inspect/open/copy actual localhost URLs and mappings.", func() tea.Cmd { return m.developmentPorts(p, m.developmentReturn(p)) })
		add("Android device", developmentAndroidSummary(o), func() tea.Cmd {
			returnTo := m.developmentReturn(p)
			m.renderDevelopmentMenu(p, "android", returnTo)
			return m.observeDevelopment(p)
		})
		add("Preview / clean cache", "Preview eligible disposable resources; persistent data is excluded.", func() tea.Cmd { return m.developmentCache(p, m.developmentReturn(p)) })
		add("Remove project", "Synchronize edits before removing this project's owned resources and persistent device/service data.", func() tea.Cmd { return m.removeProjectMenu(p) })
		if o.ProfileError != "" {
			help += "\nLocal profile unavailable: " + o.ProfileError
		}
		if o.Error != "" {
			help += "\nObservation unavailable: " + o.Error
		}
	}
	m.showMenu(title, help, returnTo, items...)
	m.menu.Details, m.menu.Keys, m.menu.DevelopmentID, m.menu.DevelopmentPage = details, keys, p.ID, page
}

func (m *model) developmentRun(p project, label string, returnTo func() tea.Cmd, args ...string) tea.Cmd {
	return m.run(label+" / "+p.Name, returnTo, nil, append([]string{"dev", "@" + p.ID}, args...)...)
}

func (m *model) developmentTerminal(p project, label string, returnTo func() tea.Cmd, args ...string) tea.Cmd {
	start := func() tea.Cmd {
		m.sessionBack = returnTo
		return m.terminalProgram(label, m.b.CLI, append([]string{"dev", "@" + p.ID}, args...)...)
	}
	if p.Host != "" {
		return m.withConnections([]string{p.Host}, returnTo, start)
	}
	return start()
}

func (m *model) developmentLogs(p project, returnTo func() tea.Cmd) tea.Cmd {
	items := []menuItem{{"All service logs", func() tea.Cmd { return m.developmentRun(p, "Service logs", returnTo, "logs") }}}
	for _, service := range m.developments[p.ID].Status.Services {
		service := service
		items = append(items, menuItem{service.Label, func() tea.Cmd { return m.developmentRun(p, service.Label+" logs", returnTo, "logs", service.ID) }})
	}
	return m.showMenu("Service logs / "+p.Name, "Bounded service output.", returnTo, items...)
}

func (m *model) developmentAndroidAction(p project, verb, label string) tea.Cmd {
	returnTo := m.developmentReturn(p)
	run := func() tea.Cmd { return m.developmentRun(p, label, returnTo, "android", verb) }
	body := ""
	switch verb {
	case "enable":
		body = "Enable optional Android for " + p.Name + "? This changes only this repository's validated preference. Host capability and boot checks determine readiness."
	case "disable":
		body = "Stop the device/viewer and disable Android for " + p.Name + "? Device data is kept."
	case "prepare-host":
		body = "Prepare Android prerequisites on " + p.Host + " for " + p.Name + "? Administrator authentication may be required. Molt records its changes for later cleanup; it does not replace the host kernel."
		run = func() tea.Cmd {
			return m.developmentTerminal(p, label+" / "+p.Name, returnTo, "android", "prepare-host")
		}
	case "reset":
		body = "Permanently delete Android device data for " + p.Name + "? Its device/viewer stops first. Source, service data, and other repositories' devices are kept."
		run = func() tea.Cmd {
			cmd := m.developmentRun(p, label, returnTo, "android", "reset", "--yes")
			m.retry = func() tea.Cmd { return m.confirm(label+" / "+p.Name, body, returnTo, run) }
			return cmd
		}
	}
	if body != "" {
		return m.confirm(label+" / "+p.Name, body, returnTo, run)
	}
	return run()
}

// Reuse the foundation's forward validation for the public ports-array ABI.
func decodeDevelopmentPorts(data []byte, id string) ([]DevelopmentForwardStatus, error) {
	var ports []DevelopmentForwardStatus
	if err := decodeDevelopmentJSON(data, &ports); err != nil {
		return nil, err
	}
	status := DevelopmentStatus{Version: 1, ProjectID: id, Name: "Ports", Environment: DevelopmentEnvironmentStatus{State: "unknown"}, Services: []DevelopmentServiceStatus{}, Ports: ports, Android: DevelopmentAndroidStatus{State: "disabled", ViewerState: "closed"}, Cleanup: DevelopmentCleanupStatus{State: "clean", Remaining: []string{}}}
	seen := map[string]bool{}
	for _, p := range ports {
		if !seen[p.Service] {
			status.Services = append(status.Services, DevelopmentServiceStatus{ID: p.Service, Label: p.Service, State: "unknown"})
			seen[p.Service] = true
		}
	}
	encoded, err := json.Marshal(status)
	if err != nil {
		return nil, err
	}
	decoded, err := decodeDevelopmentStatus(encoded)
	return decoded.Ports, err
}

func (m *model) developmentPorts(p project, returnTo func() tea.Cmd) tea.Cmd {
	return m.fetch("Application URLs / "+p.Name, returnTo, func(data []byte) tea.Cmd {
		ports, err := decodeDevelopmentPorts(data, p.ID)
		if err != nil {
			return m.showMessage("Invalid application URLs", err.Error(), returnTo)
		}
		o := m.developments[p.ID]
		o.Status.Ports = ports
		m.developments[p.ID] = o
		m.renderDevelopmentMenu(p, "ports", returnTo)
		return nil
	}, "dev", "@"+p.ID, "ports", "--json")
}

func (m *model) developmentPortMenu(p project, id string, returnTo func() tea.Cmd) tea.Cmd {
	for _, port := range m.developments[p.ID].Status.Ports {
		if port.ID != id {
			continue
		}
		port := port
		portBack := func() tea.Cmd { return m.developmentPortMenu(p, id, returnTo) }
		m.showMenu("URL / "+port.Label+" / "+p.Name, developmentPortSummary(m.developments[p.ID], port), returnTo,
			menuItem{"Inspect mapping", func() tea.Cmd {
				return m.showMessage("Mapping / "+port.Label, developmentPortSummary(m.developments[p.ID], port), portBack)
			}},
			menuItem{"Open in browser", func() tea.Cmd { return m.developmentPortAction(p, id, false, portBack) }},
			menuItem{"Copy actual URL", func() tea.Cmd { return m.developmentPortAction(p, id, true, portBack) }})
		m.menu.DevelopmentID, m.menu.DevelopmentPage = p.ID, "port:"+id
		m.menu.Keys = []string{"inspect", "open", "copy"}
		return nil
	}
	return m.showMessage("Application port unavailable", "Refresh mappings to inspect this declared port.", returnTo)
}

func (m *model) developmentPortAction(p project, id string, copy bool, returnTo func() tea.Cmd) tea.Cmd {
	return m.fetch("Check application URL / "+p.Name, returnTo, func(data []byte) tea.Cmd {
		ports, err := decodeDevelopmentPorts(data, p.ID)
		if err != nil {
			return m.showMessage("Invalid application URLs", err.Error(), returnTo)
		}
		o := m.developments[p.ID]
		o.Status.Ports = ports
		m.developments[p.ID] = o
		for _, port := range ports {
			if port.ID != id {
				continue
			}
			if copy {
				if port.State != "forwarded" {
					return m.showMessage("URL unavailable", port.Reason+"\nNo observed localhost mapping to copy.", returnTo)
				}
				back(returnTo)
				return m.copyText(port.URL)
			}
			return m.developmentRun(p, "Open "+port.Label, returnTo, "open", id)
		}
		return m.showMessage("Application port unavailable", "The port is no longer declared. Refresh mappings.", returnTo)
	}, "dev", "@"+p.ID, "ports", "--json")
}

func developmentCacheSummary(preview DevelopmentCachePreview) string {
	body := fmt.Sprintf("Eligible disposable cache: %d bytes\nRevision: %s", preview.ReclaimableBytes, preview.Revision)
	for _, item := range preview.Items {
		body += fmt.Sprintf("\n\n%s · %s · %d bytes\n%s", item.ID, item.Kind, item.Bytes, item.Path)
	}
	if preview.Reason != "" {
		body += "\n\n" + preview.Reason
	}
	return body + "\n\nSource, credentials, databases, Android data, and live resources are excluded. Shared private Nix storage is retained while in use."
}

func (m *model) developmentCache(p project, returnTo func() tea.Cmd) tea.Cmd {
	return m.fetch("Development cache / "+p.Name, returnTo, func(data []byte) tea.Cmd {
		preview, err := decodeDevelopmentCachePreview(data)
		if err == nil && preview.ProjectID != p.ID {
			err = fmt.Errorf("cache preview belongs to another project")
		}
		if err != nil {
			return m.showMessage("Invalid cache preview", err.Error(), returnTo)
		}
		refresh := func() tea.Cmd { return m.developmentCache(p, returnTo) }
		body := developmentCacheSummary(preview)
		items := []menuItem{{"Inspect exact inventory", func() tea.Cmd { return m.showMessage("Cache inventory / "+p.Name, body, refresh) }}, {"Refresh cache preview", refresh}}
		if preview.Revision != "" && len(preview.Items) != 0 {
			items = append(items, menuItem{"Clean displayed cache", func() tea.Cmd {
				return m.confirm("Clean cache / "+p.Name, "Remove exactly this eligible inventory?\n\n"+body, refresh, func() tea.Cmd {
					cmd := m.developmentRun(p, "Clean cache", returnTo, "clean-cache", "--yes", "--revision", preview.Revision)
					m.retry = refresh
					m.actionFailure = func(err error) tea.Cmd {
						cmd := m.showMessage("Cache cleanup · failed", clean(err.Error())+"\n"+strings.Join(m.output, "\n")+"\n\nFetch a new preview before confirming cleanup again.", refresh)
						m.dialog.Retry = refresh
						return cmd
					}
					return cmd
				})
			}})
		}
		m.showMenu("Cache preview / "+p.Name, fmt.Sprintf("%d eligible bytes · %d resources", preview.ReclaimableBytes, len(preview.Items)), returnTo, items...)
		for range items {
			m.menu.Details = append(m.menu.Details, body)
		}
		return nil
	}, "dev", "@"+p.ID, "cache", "--json")
}
