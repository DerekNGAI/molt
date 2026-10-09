package main

import (
	"context"
	"image"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

type pollMsg time.Time
type frameMsg time.Time
type inventoryMsg struct{ inventory }
type localMsg struct{ metrics }
type remoteMsg struct{ remote }
type syncMsg struct {
	States map[string]syncState
	Error  string
}
type outputMsg struct {
	Lines   []string
	Project string
	Error   string
}
type actionMsg struct {
	Name, Work string
	Error      error
}
type event struct {
	At   time.Time
	Text string
}

type model struct {
	b                                                                            backend
	width, height, focus, hostIndex, frame, scroll                               int
	inv                                                                          inventory
	local, previousLocal                                                         metrics
	remotes                                                                      map[string]remote
	previousRemote                                                               map[string]metrics
	history                                                                      map[string][]float64
	syncs                                                                        map[string]syncState
	syncError                                                                    string
	selected, query, overlay, logProject, action, work                           string
	searching, logs, paused, invBusy, localBusy, syncBusy, logBusy, frameRunning bool
	remoteBusy                                                                   map[string]bool
	animation                                                                    bool
	paletteIndex, overlayScroll                                                  int
	target                                                                       project
	events                                                                       []event
	output                                                                       []string
	rendered                                                                     string
	copyArea                                                                     image.Rectangle
	selection                                                                    *textSelection
	copyID                                                                       int
	copyNotice                                                                   string
	cancelAction                                                                 context.CancelFunc
	menu                                                                         menuState
	form                                                                         formState
	dialog                                                                       dialogState
	editor                                                                       editorState
	queryID                                                                      int
	queryCancel                                                                  context.CancelFunc
	onQuery                                                                      func([]byte) tea.Cmd
	onQueryError                                                                 func(error) tea.Cmd
	afterAction, actionBack, retry                                               func() tea.Cmd
	session                                                                      *terminalSession
	sessionCancel                                                                context.CancelFunc
	sessionBack, afterSession                                                    func() tea.Cmd
	sessionTitle                                                                 string
	exclusive, installing, updating, restart                                     bool
	source                                                                       string
	startScreen                                                                  string
	collectorContext                                                             context.Context
	collectorCancel                                                              context.CancelFunc
	collectors                                                                   *sync.WaitGroup
}

func newModel(b backend) *model {
	if b.Context == nil {
		b.Context = context.Background()
	}
	ctx, cancel := context.WithCancel(b.Context)
	return &model{b: b, inv: inventory{Config: map[string]string{}}, width: 100, height: 32, remotes: map[string]remote{}, previousRemote: map[string]metrics{}, history: map[string][]float64{}, syncs: map[string]syncState{}, remoteBusy: map[string]bool{}, collectorContext: ctx, collectorCancel: cancel, collectors: &sync.WaitGroup{}, events: []event{{time.Now(), "Control center ready · metrics refresh every 3 seconds"}}}
}

func (m *model) collector(cmd tea.Cmd) tea.Cmd {
	wg := m.collectors
	wg.Add(1)
	return func() tea.Msg { defer wg.Done(); return cmd() }
}
func (m *model) resumeCollectors() {
	m.collectorContext, m.collectorCancel = context.WithCancel(m.b.Context)
	m.collectors = &sync.WaitGroup{}
}

func pollTick() tea.Cmd {
	return tea.Tick(refreshInterval, func(t time.Time) tea.Msg { return pollMsg(t) })
}
func animationTick() tea.Cmd {
	return tea.Tick(100*time.Millisecond, func(t time.Time) tea.Msg { return frameMsg(t) })
}

func (m *model) Init() tea.Cmd {
	if m.installing {
		return nil
	}
	return tea.Batch(m.poll(), pollTick())
}

func (m *model) animate() tea.Cmd {
	// Output updates are useful even when decorative motion is disabled.
	if (m.animation || m.work != "") && !m.frameRunning {
		m.frameRunning = true
		return animationTick()
	}
	return nil
}

func (m *model) busy() bool {
	if m.action != "" || m.invBusy || m.localBusy || m.syncBusy || m.logBusy {
		return true
	}
	for _, busy := range m.remoteBusy {
		if busy {
			return true
		}
	}
	for _, s := range m.syncs {
		if s.label() == "transferring" {
			return true
		}
	}
	return false
}

func (m *model) poll() tea.Cmd {
	if m.exclusive || m.installing {
		return nil
	}
	var cmds []tea.Cmd
	b := m.b
	b.Context = m.collectorContext
	if !m.invBusy {
		m.invBusy = true
		cmds = append(cmds, m.collector(func() tea.Msg { return inventoryMsg{b.inventory()} }))
	}
	if !m.localBusy {
		m.localBusy = true
		cmds = append(cmds, m.collector(func() tea.Msg { return localMsg{b.local()} }))
	}
	if !m.syncBusy {
		m.syncBusy = true
		cmds = append(cmds, m.collector(func() tea.Msg {
			data, err := b.output(5*time.Second, "monitor", "sync")
			if err != nil {
				return syncMsg{Error: err.Error()}
			}
			states, err := parseSync(data)
			if err != nil {
				return syncMsg{Error: err.Error()}
			}
			return syncMsg{States: states}
		}))
	}
	for _, name := range m.inv.Hosts {
		name := name
		if m.remoteBusy[name] {
			continue
		}
		m.remoteBusy[name] = true
		cmds = append(cmds, m.collector(func() tea.Msg {
			start := time.Now()
			data, err := b.output(12*time.Second, "monitor", "host", name)
			if err != nil {
				return remoteMsg{remote{Name: name, Error: err.Error(), At: time.Now()}}
			}
			h, err := parseRemote(name, data)
			if err != nil {
				h.Error = err.Error()
			}
			h.Latency = time.Since(start)
			return remoteMsg{h}
		}))
	}
	if m.logs && m.logProject != "" && m.action == "" && !m.logBusy {
		cmds = append(cmds, m.fetchLogs(m.logProject))
	}
	cmds = append(cmds, m.animate())
	return tea.Batch(cmds...)
}

func (m *model) record(text string) {
	m.events = append(m.events, event{time.Now(), clean(text)})
	if len(m.events) > 200 {
		m.events = m.events[len(m.events)-200:]
	}
}

func (m *model) addHistory(key string, v float64) {
	if v < 0 {
		return
	}
	h := append(m.history[key], v)
	if len(h) > 32 {
		h = h[len(h)-32:]
	}
	m.history[key] = h
}

func (m *model) filtered() []project {
	var projects []project
	for _, p := range m.inv.Projects {
		if strings.Contains(strings.ToLower(p.Name+" "+p.Host+" "+p.Path), strings.ToLower(m.query)) {
			projects = append(projects, p)
		}
	}
	return projects
}

func (m *model) current() project {
	list := m.filtered()
	for _, p := range list {
		if p.ID == m.selected {
			return p
		}
	}
	if len(list) > 0 {
		return list[0]
	}
	return project{}
}

func (m *model) move(delta int) {
	if m.focus == 3 {
		m.scroll = max(0, m.scroll-delta)
		return
	}
	if m.focus == 0 {
		m.hostIndex = max(0, min(len(m.inv.Hosts)-1, m.hostIndex+delta))
		return
	}
	list := m.filtered()
	if len(list) == 0 {
		return
	}
	index := 0
	for i, p := range list {
		if p.ID == m.current().ID {
			index = i
		}
	}
	m.selected = list[max(0, min(len(list)-1, index+delta))].ID
}

func (m *model) fetchLogs(id string) tea.Cmd {
	m.logBusy = true
	b := m.b
	b.Context = m.collectorContext
	return m.collector(func() tea.Msg {
		data, err := b.output(8*time.Second, "logs", "@"+id)
		if err != nil {
			return outputMsg{Project: id, Error: err.Error()}
		}
		lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
		for i := range lines {
			lines[i] = clean(lines[i])
		}
		return outputMsg{Lines: lines, Project: id}
	})
}

func (m *model) startAction(name string, args ...string) tea.Cmd {
	if m.action != "" {
		m.record("An action is already running · Esc opens cancellation")
		return nil
	}
	m.afterAction, m.actionBack, m.retry = nil, nil, nil
	return m.withActionConnections(args, m.dashboard, func() tea.Cmd { return m.startProcess(name, m.b.CLI, args...) })
}

func (m *model) startProcess(name, program string, args ...string) tea.Cmd {
	if m.action != "" {
		m.record("An action is already running · Esc opens cancellation")
		return nil
	}
	dir := filepath.Join(m.b.Home, "state", "tmp")
	if m.installing || m.exclusive {
		dir = ""
	}
	work, err := os.MkdirTemp(dir, "action.")
	if err != nil {
		m.record("Cannot start action: " + err.Error())
		returnTo := m.actionBack
		if returnTo == nil {
			returnTo = m.dashboard
		}
		return m.showMessage(name+" · failed", err.Error(), returnTo)
	}
	ctx, cancel := context.WithCancel(m.b.Context)
	m.cancelAction = cancel
	m.action = name
	m.work = work
	m.logs = true
	m.logProject = ""
	m.output = nil
	m.scroll = 0
	m.focus = 3
	m.record(name + " started")
	cmd := m.b.command(ctx, append([]string{"ui-action", work, program}, args...)...)
	if m.installing || m.exclusive {
		// Installation and removal must not depend on an installation log that
		// does not exist yet, or that the worker is about to remove.
		cmd = m.b.process(ctx, program, args...)
		f, err := os.OpenFile(filepath.Join(work, "output"), os.O_CREATE|os.O_WRONLY, 0600)
		if err != nil {
			cancel()
			os.RemoveAll(work)
			m.action, m.work = "", ""
			m.record(err.Error())
			return m.showMessage(name+" · failed", err.Error(), m.actionBack)
		}
		cmd.Stdout, cmd.Stderr = f, f
		wg := m.collectors
		return tea.Batch(m.animate(), func() tea.Msg {
			defer f.Close()
			wg.Wait()
			err := cmd.Run()
			cancel()
			return actionMsg{Name: name, Work: work, Error: err}
		})
	}
	return tea.Batch(m.animate(), func() tea.Msg { err := cmd.Run(); cancel(); return actionMsg{Name: name, Work: work, Error: err} })
}

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.selection, m.rendered = nil, ""
		m.width, m.height = msg.Width, msg.Height
		if m.session != nil {
			m.session.resize(m.sessionSize())
		}
	case queryMsg:
		return m, m.finishQuery(msg)
	case sessionStartedMsg:
		return m, m.sessionStarted(msg)
	case sessionOutputMsg:
		return m, m.sessionOutput(msg)
	case clipboardMsg:
		if msg.ID != m.copyID {
			return m, nil
		}
		m.copyNotice = "Copied to clipboard"
		if msg.Error != nil {
			m.copyNotice = "Copy failed: " + clean(msg.Error.Error())
			m.record(m.copyNotice)
		}
		return m, tea.Tick(3*time.Second, func(time.Time) tea.Msg { return clearClipboardMsg(msg.ID) })
	case clearClipboardMsg:
		if int(msg) == m.copyID {
			m.copyNotice = ""
		}
	case pollMsg:
		if m.work != "" {
			m.output = readTail(filepath.Join(m.work, "output"))
		}
		if !m.paused {
			return m, tea.Batch(m.poll(), pollTick())
		}
		return m, pollTick()
	case frameMsg:
		m.frame++
		if m.work != "" {
			m.output = readTail(filepath.Join(m.work, "output"))
		}
		if (m.animation && m.busy()) || m.work != "" {
			return m, animationTick()
		}
		m.frameRunning = false
	case inventoryMsg:
		m.invBusy = false
		if msg.Error != "" {
			m.record("Inventory: " + msg.Error)
			return m, nil
		}
		first := len(m.inv.Hosts) == 0 && len(msg.Hosts) > 0
		m.inv = msg.inventory
		m.animation = m.inv.Config["MOLT_ANIMATIONS"] != "0" && os.Getenv("NO_COLOR") == ""
		m.hostIndex = max(0, min(m.hostIndex, len(m.inv.Hosts)-1))
		m.selected = m.current().ID
		if m.startScreen != "" {
			screen := m.startScreen
			m.startScreen = ""
			return m, m.openScreen(screen)
		}
		if first {
			return m, m.poll()
		}
	case localMsg:
		m.localBusy = false
		m.previousLocal = m.local
		m.local = withCPU(msg.metrics, m.local)
		m.addHistory("local", m.local.CPU)
	case remoteMsg:
		m.remoteBusy[msg.Name] = false
		previous, exists := m.remotes[msg.Name]
		h := msg.remote
		if h.Error != "" {
			h.Metrics = previous.Metrics
			h.Containers = previous.Containers
			h.Docker = previous.Docker
			if !exists || previous.Error == "" {
				m.record(msg.Name + " · disconnected · " + h.Error)
			}
		} else {
			m.previousRemote[msg.Name] = previous.Metrics
			h.Metrics = withCPU(h.Metrics, previous.Metrics)
			m.addHistory(msg.Name, h.Metrics.CPU)
			if !exists || previous.Error != "" {
				m.record(msg.Name + " · SSH connected")
			}
			for _, p := range m.inv.Projects {
				if p.Host == h.Name && exists && p.runtime(previous) != p.runtime(h) {
					m.record(p.Name + " · container " + p.runtime(h))
				}
			}
		}
		m.remotes[h.Name] = h
	case syncMsg:
		m.syncBusy = false
		if msg.Error != "" {
			if m.syncError == "" {
				m.record("Synchronization: " + msg.Error)
			}
			m.syncError = msg.Error
		} else {
			m.syncError = ""
			for name, s := range msg.States {
				if old, ok := m.syncs[name]; !ok || old.label() != s.label() {
					m.record(name + " · sync " + s.label())
				}
			}
			m.syncs = msg.States
		}
	case outputMsg:
		m.logBusy = false
		if msg.Project == m.logProject && m.action == "" {
			if msg.Error != "" {
				m.output = []string{"Could not retrieve logs", msg.Error}
			} else {
				m.output = msg.Lines
			}
		}
	case actionMsg:
		m.output = readTail(filepath.Join(msg.Work, "output"))
		if msg.Error != nil {
			m.record(msg.Name + " failed · " + msg.Error.Error())
		} else {
			m.record(msg.Name + " completed")
		}
		// Persist the last output for inspection after the control center exits.
		if !m.installing && (!m.exclusive || m.updating) {
			saveOutput(filepath.Join(msg.Work, "output"), m.b.Home)
		}
		os.RemoveAll(msg.Work)
		m.work = ""
		m.action = ""
		m.cancelAction = nil
		next := m.afterAction
		m.afterAction = nil
		if m.overlay == "quit" {
			return m, tea.Quit
		}
		if m.overlay == "cancel" {
			m.overlay = "action"
		}
		if m.exclusive && !m.installing && msg.Error == nil {
			if _, err := os.Stat(m.b.Home); os.IsNotExist(err) {
				return m, tea.Quit
			}
		}
		if m.exclusive {
			m.resumeCollectors()
		}
		m.exclusive, m.updating = false, false
		if msg.Error == nil && next != nil {
			return m, tea.Batch(next(), m.poll())
		}
		if m.overlay == "action" || msg.Error != nil && m.actionBack != nil {
			result := "Completed"
			if msg.Error != nil {
				result = "Failed: " + msg.Error.Error()
			}
			m.showMessage(msg.Name+" · "+result, strings.Join(m.output, "\n"), m.actionBack)
			m.dialog.Retry = m.retry
		}
		if m.installing {
			return m, nil
		}
		return m, m.poll()
	case tea.MouseMsg:
		if m.overlay == "session" && m.session != nil {
			m.session.mouse(msg)
			return m, nil
		}
		if cmd, handled := m.selectionMouse(msg); handled {
			return m, cmd
		}
		if m.nativeMouse(msg) {
			return m, nil
		}
		if m.overlay != "" || m.searching {
			return m, nil
		}
		if msg.Button == tea.MouseButtonWheelUp {
			m.move(-1)
		} else if msg.Button == tea.MouseButtonWheelDown {
			m.move(1)
		} else if msg.Button == tea.MouseButtonLeft && msg.Action == tea.MouseActionPress {
			l := m.layout()
			if msg.Y < 2+l.top {
				if msg.X < m.width/3 {
					m.focus = 0
				} else {
					m.focus = 1
				}
			} else if msg.Y < 2+l.top+l.projects {
				m.focus = 2
				m.selectRow(msg.Y - (2 + l.top) - 3)
			} else {
				m.focus = 3
			}
		}
	case tea.KeyMsg:
		return m, m.key(msg)
	}
	return m, nil
}

func (m *model) selectRow(row int) {
	list := m.filtered()
	start := m.projectStart()
	index := start + row
	if row >= 0 && index < len(list) {
		m.selected = list[index].ID
	}
}

func (m *model) key(msg tea.KeyMsg) tea.Cmd {
	m.selection = nil
	k := msg.String()
	if m.searching {
		switch k {
		case "esc":
			m.searching = false
			m.query = ""
		case "enter":
			m.searching = false
			m.selected = m.current().ID
		case "backspace", "ctrl+h":
			r := []rune(m.query)
			if len(r) > 0 {
				m.query = string(r[:len(r)-1])
			}
		case "ctrl+u":
			m.query = ""
		default:
			if msg.Type == tea.KeyRunes {
				m.query += string(msg.Runes)
			}
		}
		return nil
	}
	if k == "Y" && !msg.Paste {
		if m.overlay == "message" || m.overlay == "action" || m.overlay == "" && m.focus == 3 {
			return m.copyOutput()
		}
	}
	if m.overlay != "" {
		return m.overlayKey(msg)
	}
	m.overlayScroll = 0
	switch k {
	case "q", "ctrl+c":
		if m.action != "" {
			m.overlay = "quit"
			return nil
		}
		return tea.Quit
	case "?":
		m.overlay = "help"
		m.overlayScroll = 0
	case ":", "ctrl+p":
		m.overlay = "palette"
		m.paletteIndex = 0
	case "/":
		m.searching = true
		m.focus = 2
	case "esc":
		if m.action != "" {
			m.overlay = "cancel"
		} else {
			m.query = ""
		}
	case "tab", "l", "right":
		m.focus = (m.focus + 1) % 4
	case "shift+tab", "h", "left":
		m.focus = (m.focus + 3) % 4
	case "j", "down":
		m.move(1)
	case "k", "up":
		m.move(-1)
	case "g", "home":
		if m.focus == 3 {
			m.scroll = len(m.output)
		} else if list := m.filtered(); len(list) > 0 {
			m.selected = list[0].ID
		}
	case "G", "end":
		m.scroll = 0
		if list := m.filtered(); len(list) > 0 {
			m.selected = list[len(list)-1].ID
		}
	case "ctrl+d", "pgdown":
		m.move(5)
	case "ctrl+u", "pgup":
		m.move(-5)
	case "1", "2", "3", "4":
		m.focus = int(k[0] - '1')
	case "[":
		m.hostIndex = max(0, m.hostIndex-1)
	case "]":
		m.hostIndex = min(max(0, len(m.inv.Hosts)-1), m.hostIndex+1)
	case "p":
		m.paused = !m.paused
	case "R":
		return m.poll()
	case "a":
		m.logs = false
		m.scroll = 0
		m.focus = 3
	case "L":
		if p := m.current(); p.ID != "" {
			m.logs = true
			m.logProject = p.ID
			m.output = nil
			m.scroll = 0
			m.focus = 3
			return tea.Batch(m.fetchLogs(p.ID), m.animate())
		}
	case "enter":
		if m.focus == 2 {
			m.overlay = "detail"
			m.overlayScroll = 0
		}
	case "s":
		if p := m.current(); p.ID != "" {
			return m.startAction("Start "+p.Name, "start", "@"+p.ID)
		}
	case "S":
		if p := m.current(); p.ID != "" {
			m.overlay = "stop"
			m.target = p
		}
	case "r":
		if p := m.current(); p.ID != "" {
			m.overlay = "restart"
			m.target = p
		}
	case "o":
		if p := m.current(); p.ID != "" {
			return m.terminal("oc-project", "@"+p.ID)
		}
	case "y":
		if p := m.current(); p.ID != "" {
			return m.startAction("Sync status · "+p.Name, "sync", "@"+p.ID)
		}
	case "d":
		return m.startAction("Diagnostics", "doctor")
	case "c":
		if len(m.inv.Hosts) > 0 {
			return m.terminal("connection", "login", m.inv.Hosts[m.hostIndex])
		}
		return m.openScreen("connections")
	case "n":
		return m.registerForm(m.dashboard)
	case "m":
		m.overlay, m.paletteIndex = "palette", 0
	}
	return nil
}

type paletteItem struct {
	Title, Description string
	Args               []string
	Interactive        bool
}

func palette() []paletteItem {
	return []paletteItem{
		{"Repositories", "Scan, register, and manage your Git repositories.", []string{"projects"}, true},
		{"Connections", "Manage VM connections, SSH profiles, and keys.", []string{"connections"}, true},
		{"Guided setup", "Connect a VM, choose folders, and prepare Docker.", []string{"setup"}, true},
		{"OpenCode", "Attach to a project, manage providers, and edit server settings.", []string{"opencode"}, true},
		{"Settings", "Choose folders, ports, animations, and shell activation.", []string{"settings"}, true},
		{"Maintenance", "Update MOLT, check diagnostics, repair, and clean up resources.", []string{"maintenance"}, true},
		{"Tool versions", "Show the installed MOLT, Mutagen, and OpenCode versions.", []string{"tools"}, false},
		{"Start all projects", "Start every registered workspace.", []string{"up"}, false},
		{"Stop all projects", "Stop all workspaces and flush synchronization. Confirmation required.", []string{"down"}, false},
		{"Uninstall MOLT", "Review cleanup and choose how to remove this installation.", []string{"uninstall"}, true},
	}
}

func (m *model) overlayKey(msg tea.KeyMsg) tea.Cmd {
	if cmd, handled := m.nativeKey(msg); handled {
		return cmd
	}
	k := msg.String()
	if k == "esc" || k == "ctrl+c" {
		m.overlay = ""
		return nil
	}
	switch m.overlay {
	case "help", "detail":
		switch k {
		case "j", "down":
			m.overlayScroll++
		case "k", "up":
			m.overlayScroll = max(0, m.overlayScroll-1)
		case "ctrl+d", "pgdown":
			m.overlayScroll += 5
		case "ctrl+u", "pgup":
			m.overlayScroll = max(0, m.overlayScroll-5)
		}
		if k == "q" || k == "enter" || k == "?" {
			m.overlay = ""
		}
	case "palette":
		switch k {
		case "j", "down":
			m.paletteIndex = min(len(palette())-1, m.paletteIndex+1)
		case "k", "up":
			m.paletteIndex = max(0, m.paletteIndex-1)
		case "home", "g":
			m.paletteIndex = 0
		case "end", "G":
			m.paletteIndex = len(palette()) - 1
		case "i":
			index := m.paletteIndex
			item := palette()[index]
			return m.showMessage("Details / "+item.Title, item.Description, func() tea.Cmd { m.overlay, m.paletteIndex = "palette", index; return nil })
		case "enter":
			item := palette()[m.paletteIndex]
			if item.Args[0] == "down" {
				m.overlay, m.overlayScroll = "down", 0
				return nil
			}
			m.overlay = ""
			if item.Interactive {
				return m.openScreen(item.Args[0])
			}
			return m.startAction(item.Title, item.Args...)
		}
	default:
		switch k {
		case "j", "down":
			m.overlayScroll++
		case "k", "up":
			m.overlayScroll = max(0, m.overlayScroll-1)
		case "ctrl+d", "pgdown":
			m.overlayScroll += 5
		case "ctrl+u", "pgup":
			m.overlayScroll = max(0, m.overlayScroll-5)
		}
		if k != "y" {
			if k == "n" {
				m.overlay = ""
			}
			return nil
		}
		action := m.overlay
		m.overlay = ""
		switch action {
		case "quit", "cancel":
			if m.cancelAction != nil {
				m.cancelAction()
			}
			if action == "quit" {
				m.overlay = "quit"
			}
			return nil
		case "down":
			return m.startAction("Stop all projects", "down")
		case "stop":
			p := m.target
			return m.startAction("Stop "+p.Name, "stop", "@"+p.ID)
		case "restart":
			p := m.target
			return m.startAction("Restart "+p.Name, "restart", "@"+p.ID)
		}
	}
	return nil
}
