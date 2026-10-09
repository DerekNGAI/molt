package main

import (
	"fmt"
	"image"
	"math"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

var (
	accent        = lipgloss.NewStyle().Foreground(lipgloss.Color("#66D9EF"))
	text          = lipgloss.NewStyle().Foreground(lipgloss.Color("#DCE5F2"))
	muted         = lipgloss.NewStyle().Foreground(lipgloss.Color("#8B9DB5"))
	green         = lipgloss.NewStyle().Foreground(lipgloss.Color("#81D8AE"))
	amber         = lipgloss.NewStyle().Foreground(lipgloss.Color("#EDB776"))
	red           = lipgloss.NewStyle().Foreground(lipgloss.Color("#F08491"))
	selectedStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#DCE5F2")).Background(lipgloss.Color("#22354A"))
)

type dimensions struct {
	top, projects, bottom int
	compact               bool
}

func (m *model) layout() dimensions {
	available := max(1, m.height-4)
	if m.width < 50 || m.height < 24 {
		return dimensions{projects: available, compact: true}
	}
	// The three panels also need two separator rows above the footer.
	available = max(1, m.height-6)
	top := 12
	if m.height < 30 {
		top = 8
	}
	bottom := max(5, min(10, available/4))
	return dimensions{top: top, projects: max(5, available-top-bottom), bottom: bottom}
}

func fit(s string, width int) string { return ansi.Truncate(s, max(0, width), "…") }

func elapsed(start time.Time) string {
	if start.IsZero() {
		return "0s"
	}
	return time.Since(start).Truncate(time.Second).String()
}

func (m *model) actionSummary() string {
	stage := m.actionStage
	if stage == "" {
		stage = "Starting operation"
	}
	return stage + "\nElapsed: " + elapsed(m.actionStarted) + " · step: " + elapsed(m.stageStarted)
}
func cell(s string, width int) string {
	s = fit(s, width)
	return s + strings.Repeat(" ", max(0, width-lipgloss.Width(s)))
}

func box(title, body string, width, height int, focused bool) string {
	if focused {
		title = "› " + title
	}
	inside := max(1, width-4)
	lines := []string{accent.Bold(true).Render(fit(title, inside))}
	lines = append(lines, strings.Split(body, "\n")...)
	rows := max(1, height-2)
	if len(lines) > rows {
		lines = lines[:rows]
	}
	for len(lines) < rows {
		lines = append(lines, "")
	}
	for i := range lines {
		lines[i] = cell(lines[i], inside)
	}
	border := lipgloss.Color("#2B3B52")
	if focused {
		border = lipgloss.Color("#66D9EF")
	}
	return lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(border).Padding(0, 1).Render(strings.Join(lines, "\n"))
}

func bytes(n float64) string {
	units := []string{"B", "K", "M", "G", "T"}
	i := 0
	for n >= 1024 && i < len(units)-1 {
		n /= 1024
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%.0f%s", n, units[i])
	}
	return fmt.Sprintf("%.1f%s", n, units[i])
}

func uptime(seconds uint64) string {
	d := seconds / 86400
	h := seconds % 86400 / 3600
	if d > 0 {
		return fmt.Sprintf("%dd %dh", d, h)
	}
	return fmt.Sprintf("%dh %dm", h, seconds%3600/60)
}

func status(s string) string {
	switch s {
	case "ready", "running", "synced", "connected":
		return green.Render(s)
	case "conflict", "error", "unhealthy", "exited", "disconnected":
		return red.Render(s)
	case "unknown", "connecting", "paused", "unavailable":
		return amber.Render(s)
	case "transferring":
		return accent.Render(s)
	default:
		return muted.Render(s)
	}
}

func spark(values []float64, width int) string {
	if len(values) == 0 {
		return muted.Render(strings.Repeat("─", width))
	}
	if len(values) > width {
		values = values[len(values)-width:]
	}
	var b strings.Builder
	b.WriteString(strings.Repeat(" ", max(0, width-len(values))))
	levels := []rune("▁▂▃▄▅▆▇█")
	for _, v := range values {
		b.WriteRune(levels[int(max(0, min(7, math.Round(v/100*7))))])
	}
	return accent.Render(b.String())
}

func gauge(label string, used, total uint64, percent float64, width int) string {
	value := "—"
	if label == "CPU" {
		if percent >= 0 {
			value = fmt.Sprintf("%.0f%%", percent)
		}
	} else if total > 0 {
		percent = 100 * float64(used) / float64(total)
		value = bytes(float64(used)) + "/" + bytes(float64(total))
	}
	n := max(3, min(12, width-6-len(value)))
	filled := 0
	if percent >= 0 {
		filled = int(math.Round(max(0, min(100, percent)) * float64(n) / 100))
	}
	style := accent
	if percent > 90 {
		style = red
	} else if percent > 75 {
		style = amber
	}
	bar := style.Render(strings.Repeat("━", filled)) + muted.Render(strings.Repeat("─", n-filled))
	return muted.Render(cell(label, 5)) + bar + " " + text.Render(value)
}

func (m *model) spinner() string {
	if !m.animation {
		return "·"
	}
	frames := []rune("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
	return string(frames[m.frame%len(frames)])
}

func (m *model) host() remote {
	if len(m.inv.Hosts) == 0 {
		return remote{Error: "No connection configured", Metrics: metrics{CPU: -1}}
	}
	name := m.inv.Hosts[min(m.hostIndex, len(m.inv.Hosts)-1)]
	h, ok := m.remotes[name]
	if !ok {
		return remote{Name: name, Metrics: metrics{CPU: -1}, Error: "Waiting for first sample"}
	}
	return h
}

func (m *model) metricBody(v, prev metrics, key string, width, height int) string {
	rx, tx := rates(v, prev)
	lines := []string{
		text.Render(fit(v.CPUName, width)),
		gauge("CPU", 0, 0, v.CPU, width),
		gauge("MEM", v.MemoryUsed, v.MemoryTotal, -1, width),
		gauge("DISK", v.DiskUsed, v.DiskTotal, -1, width),
	}
	if height >= 11 {
		lines = append(lines, muted.Render("CPU  ")+spark(m.history[key], max(3, width-5)))
	}
	if height >= 9 {
		lines = append(lines, muted.Render("NET  ")+text.Render("↓ "+bytes(rx)+"/s  ↑ "+bytes(tx)+"/s"))
	}
	if height >= 11 {
		lines = append(lines, muted.Render("UP   ")+text.Render(uptime(v.Uptime)), muted.Render("LOAD ")+text.Render(v.Load))
	}
	return strings.Join(lines, "\n")
}

func (m *model) topView(l dimensions) string {
	h := m.host()
	columns := 3
	if m.width < 90 {
		columns = 2
	}
	w := (m.width - (columns - 1)) / columns
	vmTitle := "VM"
	if h.Name != "" {
		vmTitle += " / " + h.Name
	}
	if len(m.inv.Hosts) > 1 {
		vmTitle += fmt.Sprintf(" · %d/%d", m.hostIndex+1, len(m.inv.Hosts))
	}
	vmBody := ""
	if h.Error != "" {
		vmBody = status("disconnected") + "\n" + muted.Render(fit(h.Error, w-4)) + "\n\n" + text.Render("c  connect · :  manage")
		if !h.Metrics.At.IsZero() {
			vmBody += "\n" + amber.Render("last sample "+time.Since(h.Metrics.At).Round(time.Second).String()+" ago")
		}
	} else {
		vmBody = green.Render("● connected") + muted.Render(" · "+h.Metrics.Name) + "\n" + m.metricBody(h.Metrics, m.previousRemote[h.Name], h.Name, w-4, l.top-1)
	}
	if columns == 2 && l.top >= 12 {
		vmBody += "\n" + muted.Render(fmt.Sprintf("Docker · %d owned containers", len(h.Containers)))
	}
	vm := box(vmTitle, vmBody, w, l.top, m.focus == 0)
	localBody := text.Render(fit(m.local.OS, w-4)) + "\n" + m.metricBody(m.local, m.previousLocal, "local", w-4, l.top-1)
	if m.local.Error != "" {
		localBody = amber.Render(fit(m.local.Error, w-4)) + "\n" + localBody
	}
	localWidth := m.width - w - 1
	if columns == 2 {
		return lipgloss.JoinHorizontal(lipgloss.Top, vm, " ", box("LOCAL / "+clean(m.local.Name), localBody, localWidth, l.top, m.focus == 1))
	}
	localWidth = m.width - 2*w - 2
	running := 0
	for _, c := range h.Containers {
		if c.State == "running" {
			running++
		}
	}
	dockerBody := green.Render(fmt.Sprintf("%d running", running)) + "  " + muted.Render(fmt.Sprintf("%d stopped", len(h.Containers)-running)) + "\n" + muted.Render("MOLT containers on selected VM")
	if h.Error != "" {
		dockerBody = amber.Render("Unknown · VM disconnected") + "\n" + muted.Render("Reconnect to refresh Docker")
	} else if h.Docker != "ready" {
		dockerBody = amber.Render("Docker unavailable") + "\n" + muted.Render("Prepare VM from the palette")
	} else {
		for _, c := range h.Containers {
			name := c.Names
			for _, p := range m.inv.Projects {
				if p.Container == c.Names {
					name = p.Name
				}
			}
			dockerBody += "\n" + cell(text.Render(name), max(3, w-17)) + " " + status(c.State)
			if c.State == "running" && l.top >= 12 {
				dockerBody += "\n" + muted.Render("  "+c.CPU+" CPU · "+c.Memory)
			}
		}
	}
	return lipgloss.JoinHorizontal(lipgloss.Top, vm, " ", box("DOCKER / owned resources", dockerBody, w, l.top, m.focus == 1), " ", box("LOCAL / "+clean(m.local.Name), localBody, localWidth, l.top, m.focus == 1))
}

func (m *model) projectStart() int {
	list := m.filtered()
	index := 0
	for i, p := range list {
		if p.ID == m.current().ID {
			index = i
		}
	}
	return max(0, index-max(1, m.layout().projects-4)+1)
}

func (m *model) projectView(l dimensions) string {
	list := m.filtered()
	inside := max(1, m.width-4)
	title := fmt.Sprintf("WORKSPACES / %d", len(m.inv.Projects))
	if m.query != "" || m.searching {
		title += " · /" + clean(m.query)
		if m.searching {
			title += "▏"
		}
	}
	if len(m.inv.Projects) == 0 {
		return box(title, muted.Render("No repositories registered yet.")+"\n"+text.Render("n  add a repository · :  scan / guided setup"), m.width, l.projects, m.focus == 2)
	}
	if len(list) == 0 {
		return box(title, amber.Render("No matching workspaces · Esc clears the filter"), m.width, l.projects, m.focus == 2)
	}
	nameWidth := max(8, min(28, inside/4))
	hostWidth := max(8, min(20, inside/5))
	stateWidth := 10
	syncWidth := 14
	header := cell("PROJECT", nameWidth) + " " + cell("HOST", hostWidth) + " " + cell("CONTAINER", stateWidth) + " " + cell("SYNC", syncWidth)
	wide := m.width >= 95
	if wide {
		header += " " + cell("SERVER", 10) + " PORT"
	}
	if l.compact || m.width < 65 {
		header = cell("PROJECT", max(10, inside/2)) + " STATE / SYNC"
	}
	lines := []string{muted.Render(fit(header, inside))}
	start := m.projectStart()
	rows := max(1, l.projects-4)
	for i := start; i < min(len(list), start+rows); i++ {
		p := list[i]
		h := m.remotes[p.Host]
		state := p.runtime(h)
		sync := "not started"
		if s, ok := m.syncs[p.Sync]; ok {
			sync = s.label()
		}
		if m.syncError != "" {
			sync = "unknown"
		}
		mark := " "
		if p.ID == m.current().ID {
			mark = "›"
		}
		if sync == "transferring" {
			sync = m.spinner() + " transferring"
		}
		line := cell(mark+" "+clean(p.Name), nameWidth) + " " + cell(muted.Render(clean(p.Host)), hostWidth) + " " + cell(status(state), stateWidth) + " " + cell(status(sync), syncWidth)
		if wide {
			line += " " + cell(status(p.health(h)), 10) + " " + muted.Render(clean(p.Port))
		}
		if l.compact || m.width < 65 {
			line = cell(mark+" "+clean(p.Name), max(10, inside/2)) + " " + status(state) + " / " + status(sync)
		}
		if p.ID == m.current().ID {
			line = selectedStyle.Render(cell(line, inside))
		}
		lines = append(lines, fit(line, inside))
	}
	return box(title, strings.Join(lines, "\n"), m.width, l.projects, m.focus == 2)
}

func (m *model) activityLines() []string {
	var lines []string
	if m.logs {
		lines = m.output
	} else {
		for _, e := range m.events {
			lines = append(lines, muted.Render(e.At.Format("15:04:05"))+"  "+text.Render(e.Text))
		}
	}
	return lines
}

func (m *model) activityView(l dimensions) string {
	title := "ACTIVITY / session events"
	lines := m.activityLines()
	if m.logs {
		title = "OUTPUT / last action"
		if m.logProject != "" {
			for _, p := range m.inv.Projects {
				if p.ID == m.logProject {
					title = "LOGS / " + clean(p.Name)
				}
			}
		}
		if m.action != "" {
			title = "OUTPUT / " + m.action + " · " + m.spinner() + " running"
		}
		if len(lines) == 0 {
			lines = []string{"Waiting for output…"}
		}
	}
	if m.scroll > 0 {
		title += " · scrolled"
	} else if m.logs && m.logProject != "" {
		title += " · live"
	}
	rows := max(1, l.bottom-3)
	summary := ""
	if m.action != "" {
		summary = m.actionSummary() + "\n"
		rows = max(0, rows-2)
	}
	end := max(0, len(lines)-m.scroll)
	start := max(0, end-rows)
	return box(title, summary+strings.Join(lines[start:end], "\n"), m.width, l.bottom, m.focus == 3)
}

func (m *model) overlayView() string {
	if view, ok := m.nativeView(); ok {
		return view
	}
	title := ""
	body := ""
	p := m.current()
	if m.overlay == "stop" || m.overlay == "restart" {
		p = m.target
	}
	switch m.overlay {
	case "help":
		title = "KEYBOARD / help"
		body = keyboardHelp()
	case "palette":
		menu := menuState{Title: "Commands", Help: "Choose a task. Details appear below the list.", Index: m.paletteIndex}
		for _, item := range palette() {
			menu.Items = append(menu.Items, menuItem{Title: item.Title})
			menu.Details = append(menu.Details, item.Description)
		}
		return m.menuView(menu)
	case "detail":
		title = "WORKSPACE / " + clean(p.Name)
		body = "Local      " + clean(p.Path) + "\nVM         " + clean(p.Host) + "\nContainer  " + clean(p.Container) + "\nRuntime    " + p.runtime(m.remotes[p.Host]) + "\nServer     " + p.health(m.remotes[p.Host]) + "\nPort       " + clean(p.Port) + "\nSync       " + clean(p.Sync)
		if s, ok := m.syncs[p.Sync]; ok {
			body += "\nSync state " + s.label()
			if s.LastError != "" {
				body += "\nError      " + clean(s.LastError)
			}
			body += fmt.Sprintf("\nConflicts  %d", len(s.Conflicts))
		}
	case "stop":
		title = "STOP WORKSPACE"
		body = "Stop " + clean(p.Name) + " and flush synchronization?\n\n" + amber.Render("The server session will be interrupted.")
	case "restart":
		title = "RESTART WORKSPACE"
		body = "Stop and restart " + clean(p.Name) + "?\n\n" + amber.Render("The server session will be interrupted.")
	case "down":
		title = "STOP ALL WORKSPACES"
		body = "Stop every registered server and flush synchronization?\n\n" + amber.Render("Connected server sessions will be interrupted.")
	case "quit", "cancel":
		title = "ACTION IN PROGRESS"
		body = clean(m.action) + "\n\nCancel this action"
		if m.overlay == "quit" {
			body += " and quit"
		}
		body += "?\n\nPartial work and recovery records are retained."
	}
	w := min(78, max(20, m.width-4))
	body = ansi.Wrap(body, max(1, w-4), "")
	h := min(max(5, m.height-6), len(strings.Split(body, "\n"))+4)
	lines := strings.Split(body, "\n")
	capacity := max(1, h-3)
	if len(lines) > capacity {
		visible := max(1, capacity-1)
		start := 0
		hint := "↑↓ scroll for more"
		switch m.overlay {
		case "help", "detail", "stop", "restart", "down", "quit", "cancel":
			start = min(m.overlayScroll, max(0, len(lines)-visible))
			hint = fmt.Sprintf("%d–%d of %d · ↑↓ scroll", start+1, min(len(lines), start+visible), len(lines))
		}
		body = strings.Join(lines[start:min(len(lines), start+visible)], "\n") + "\n" + muted.Render(hint)
	}
	return lipgloss.Place(m.width, max(1, m.height-4), lipgloss.Center, lipgloss.Center, box(title, body, w, h, true))
}

func (m *model) View() string {
	if m.selection != nil {
		if m.selection.Overlay == m.overlay {
			return m.selection.view()
		}
		m.selection = nil
	}
	m.copyArea = image.Rectangle{}
	w := max(1, m.width)
	right := muted.Render("LIVE · 3s")
	if m.paused {
		right = amber.Render("PAUSED")
	}
	if m.busy() {
		right = accent.Render(m.spinner() + " sampling")
	}
	if m.paused {
		right = amber.Render("PAUSED")
	}
	if m.action != "" {
		right = accent.Render(m.spinner() + " " + clean(m.action))
	}
	left := accent.Bold(true).Render(" M O L T ") + muted.Render(" / control center")
	header := cell(left, max(1, w-lipgloss.Width(right)-1)) + " " + right
	header = cell(header, w) + "\n" + muted.Render(cell(" Workspaces · infrastructure · synchronization", w))
	l := m.layout()
	content := ""
	if m.overlay != "" {
		content = m.overlayView()
	} else if l.compact {
		if m.focus == 3 {
			l.bottom = l.projects
			content = m.activityView(l)
		} else {
			content = m.projectView(l)
		}
	} else {
		content = m.topView(l) + "\n" + m.projectView(l) + "\n" + m.activityView(l)
	}
	if m.overlay == "" && (!l.compact || m.focus == 3) {
		end := lipgloss.Height(content)
		m.copyArea = image.Rect(2, end-l.bottom+2, w-2, end-1)
	}
	m.copyArea = m.copyArea.Add(image.Pt(0, 2)).Intersect(image.Rect(0, 2, w, max(2, m.height-2)))
	foot := m.footer(w)
	path := m.current().Path
	if path == "" {
		path = m.b.Home
	}
	if m.action != "" {
		path = m.action + " · running"
	}
	view := header + "\n" + content + "\n" + cell(fit(foot, w), w) + "\n" + muted.Render(cell(" "+clean(path), w))
	// A resize can arrive between layout and drawing; clip in terminal cells.
	lines := strings.Split(view, "\n")
	if len(lines) > m.height {
		lines = lines[:max(1, m.height)]
	}
	for i := range lines {
		lines[i] = fit(lines[i], w)
	}
	m.rendered = strings.Join(lines, "\n")
	return m.rendered
}

func keyboardHelp() string {
	row := func(key, action string) string { return accent.Render(cell(key, 14)) + " " + text.Render(action) }
	return strings.Join([]string{
		accent.Bold(true).Render("NAVIGATION"),
		row("Tab · h/l", "Switch panels"),
		row("Shift-Tab", "Previous panel"),
		row("1–4", "Focus a panel"),
		row("↑↓ · j/k", "Move or scroll"),
		row("g / G", "First / last"),
		row("Ctrl-D/U", "Page down / up"),
		row("[ / ]", "Select VM"),
		row("Esc", "Back / cancel"),
		"", accent.Bold(true).Render("WORKSPACES"),
		row("/", "Filter projects"),
		row("Enter", "Project details"),
		row("o", "Attach OpenCode"),
		row("s", "Start project"),
		row("S", "Stop (confirm)"),
		row("r", "Restart (confirm)"),
		row("n", "Register a repo"),
		"", accent.Bold(true).Render("MONITORING"),
		row("L", "Live server logs"),
		row("a", "Activity feed"),
		row("y", "Sync / conflicts"),
		row("d", "Diagnostics"),
		row("R", "Refresh now"),
		row("p", "Pause / resume"),
		row("Y in output", "Copy all retained output"),
		"", accent.Bold(true).Render("COMMANDS & SESSIONS"),
		row(": · Ctrl-P · m", "Commands"),
		row("i in a menu", "Full item details"),
		row("c", "Connect VM"),
		row("Ctrl-]", "Session controls"),
		row("q · Ctrl-C", "Quit dashboard"),
		"", muted.Render("Mouse: click to focus/select; wheel to move/scroll."),
		muted.Render("Drag output or a message to copy on release."),
		muted.Render("Motion: Settings → Animations; NO_COLOR disables it."),
	}, "\n")
}

func (m *model) footer(width int) string {
	var items []string
	switch {
	case m.searching:
		items = []string{"Enter apply", "Esc clear"}
	case m.overlay == "palette" || m.overlay == "native-menu":
		items = []string{"Enter open", "Esc back", "↑↓ move"}
		if m.overlay == "palette" || len(m.menu.Details) > 0 {
			items = append(items, "i info")
		}
	case m.overlay == "help" || m.overlay == "detail":
		items = []string{"Esc close", "↑↓ scroll", "Ctrl-D/U page", "Enter close"}
	case m.overlay == "message":
		items = []string{"Esc back", "Y copy", "↑↓ scroll", "Enter back"}
		if m.dialog.Retry != nil {
			items = []string{"Esc back", "r retry", "Y copy", "↑↓ scroll", "Enter back"}
		}
	case m.overlay == "loading":
		items = []string{"Esc cancel"}
	case m.overlay == "form":
		items = []string{"Enter continue", "Esc back", "Tab fields"}
		if m.form.Index == len(m.form.Fields)-1 {
			items[0] = "Enter save"
		}
	case m.overlay == "editor":
		items = []string{"Ctrl-S save", "Esc discard"}
	case m.overlay == "session":
		items = []string{"Ctrl-] session controls", "Keys go to session"}
	case m.overlay == "confirm" || m.overlay == "stop" || m.overlay == "restart" || m.overlay == "down" || m.overlay == "quit" || m.overlay == "cancel":
		items = []string{"n/Esc cancel", "y confirm", "↑↓ scroll"}
	case m.overlay == "action":
		items = []string{"Esc cancel", "Y copy", "↑↓ scroll", "q quit"}
	default:
		items = []string{": commands", "? help"}
		if m.action != "" {
			items = append(items, "Esc cancel")
		}
		switch m.focus {
		case 0:
			items = append(items, "c connect", "[/] VM", "↑↓ select VM")
		case 1:
			items = append(items, "R refresh", "p pause")
		case 2:
			if m.current().ID == "" {
				items = append(items, "n add repo", "/ filter")
			} else {
				items = append(items, "Enter details", "o OpenCode", "/ filter")
			}
		case 3:
			items = append(items, "↑↓ scroll", "Y copy", "G follow", "a activity")
		}
		items = append(items, "q quit", "Tab panels")
	}
	var parts []string
	used := 1
	for _, item := range items {
		n := lipgloss.Width(item)
		if len(parts) > 0 {
			n += 3
		}
		if used+n > width {
			continue
		}
		key, action, _ := strings.Cut(item, " ")
		parts = append(parts, accent.Bold(true).Render(key)+" "+muted.Render(action))
		used += n
	}
	footer := " " + strings.Join(parts, muted.Render(" · "))
	if m.copyNotice != "" {
		footer = " " + text.Render(m.copyNotice) + muted.Render(" · ") + strings.TrimSpace(footer)
	}
	return footer
}
