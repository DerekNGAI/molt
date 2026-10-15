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
	top := 11
	if m.height >= 36 {
		top = 12
	}
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
	clock := "Elapsed: " + elapsed(m.actionStarted) + " · step: " + elapsed(m.stageStarted)
	width := min(86, m.width-8)
	track := min(18, width-lipgloss.Width(clock)-2)
	if track >= 6 {
		clock += "  " + m.progress(track)
	}
	return text.Render(stage) + "\n" + muted.Render(clock)
}

func (m *model) progress(width int) string {
	if !m.animation {
		return muted.Render(cell("running…", width))
	}
	length := min(6, max(2, width/3))
	travel := width - length
	pos := m.frame % (2*travel + 1)
	if pos > travel {
		pos = 2*travel - pos
	}
	return muted.Render(strings.Repeat("─", pos)) + accent.Render(strings.Repeat("━", length)) + muted.Render(strings.Repeat("─", width-pos-length))
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
	case "ready", "running", "synced", "connected", "healthy":
		return green.Render("● " + s)
	case "conflict", "error", "unhealthy", "disconnected":
		return red.Render("✕ " + s)
	case "exited", "stopped", "absent", "not started":
		return muted.Render("○ " + s)
	case "unknown", "connecting", "starting", "restarting", "paused", "unavailable":
		return amber.Render("◐ " + s)
	case "transferring":
		return accent.Render("⇅ " + s)
	default:
		return muted.Render(s)
	}
}

func syncLabel(states map[string]syncState, name, failure string) string {
	if failure != "" {
		return "unknown"
	}
	if s, ok := states[name]; ok {
		return s.label()
	}
	return "not started"
}

func (m *model) workspaceStyle(id string) lipgloss.Style {
	if id == m.current().ID {
		return selectedStyle
	}
	if at, ok := m.changed[id]; ok && m.animation && !m.paused {
		age := time.Since(at)
		if age < 750*time.Millisecond {
			return text.Background(lipgloss.Color("#3D3022"))
		}
		if age < 1500*time.Millisecond {
			return text.Background(lipgloss.Color("#25251F"))
		}
	}
	return lipgloss.NewStyle()
}

func spark(values []float64, width int) string {
	width = max(0, width)
	if len(values) == 0 {
		return muted.Render(strings.Repeat("─", width))
	}
	if len(values) > width {
		values = values[len(values)-width:]
	}
	var b strings.Builder
	levels := []rune("▁▂▃▄▅▆▇█")
	for _, v := range values {
		b.WriteString(loadStyle(v).Render(string(levels[int(max(0, min(7, math.Round(v/100*7))))])))
	}
	return b.String()
}

func loadStyle(percent float64) lipgloss.Style {
	if percent > 90 {
		return red
	}
	if percent > 75 {
		return amber
	}
	return accent
}

func gauge(label string, used, total uint64, percent, shown float64, width int) string {
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
	units := 0
	if shown >= 0 {
		units = int(math.Round(max(0, min(100, shown)) * float64(n*8) / 100))
	}
	filled := units / 8
	fill := strings.Repeat("█", filled)
	if part := units % 8; part > 0 {
		fill += string([]rune("▏▎▍▌▋▊▉")[part-1])
		filled++
	}
	bar := loadStyle(percent).Render(fill) + muted.Render(strings.Repeat("─", n-filled))
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

func (m *model) metricBody(v, prev metrics, key string, width, rows int) string {
	rx, tx := rates(v, prev)
	shown := m.displayedPercents(key, v)
	cpu := gauge("CPU", 0, 0, v.CPU, shown[0], width)
	if v.CPU < 0 {
		cpu = muted.Render("CPU  ") + accent.Render(m.spinner()+" sampling")
	}
	trendWidth := min(32, width-lipgloss.Width(cpu)-2)
	inline := trendWidth >= 8
	if inline {
		cpu += "  " + spark(m.history[key], trendWidth)
	}
	lines := []string{cpu}
	if !inline && rows >= 5 {
		lines = append(lines, "     "+spark(m.history[key], min(12, max(0, width-5))))
	}
	lines = append(lines, gauge("MEM", v.MemoryUsed, v.MemoryTotal, -1, shown[1], width), gauge("DISK", v.DiskUsed, v.DiskTotal, -1, shown[2], width))
	if rows-len(lines) >= 2 {
		network := "↓ " + bytes(rx) + "/s  ↑ " + bytes(tx) + "/s"
		if width >= 43 {
			network += " · UP " + uptime(v.Uptime)
		}
		lines = append(lines, muted.Render("NET  ")+text.Render(network))
	}
	if rows > len(lines) {
		load := v.Load
		if load == "" {
			load = "—"
		}
		lines = append(lines, muted.Render("LOAD 1/5/15m ")+text.Render(load))
	}
	if rows > len(lines) && v.CPUName != "" {
		lines = append([]string{text.Render(fit(v.CPUName, width))}, lines...)
	}
	return strings.Join(lines[:min(len(lines), max(0, rows))], "\n")
}

func (m *model) vmView(width, height int) string {
	h := m.host()
	vmTitle := "VM"
	if h.Name != "" {
		vmTitle += " / " + h.Name
	}
	if len(m.inv.Hosts) > 1 {
		vmTitle += fmt.Sprintf(" · %d/%d", m.hostIndex+1, len(m.inv.Hosts))
	}
	vmBody := ""
	if h.Metrics.At.IsZero() && (h.Error == "Waiting for first sample" || h.Error == "" && m.remoteBusy[h.Name]) {
		vmBody = accent.Render(m.spinner()+" connecting") + "\n" + muted.Render("Waiting for first sample…")
	} else if h.Error != "" {
		vmBody = status("disconnected") + "\n" + muted.Render(fit(h.Error, width-4)) + "\n" + text.Render("c  connect · :  manage")
		if !h.Metrics.At.IsZero() {
			vmBody += "\n" + amber.Render("last sample "+time.Since(h.Metrics.At).Round(time.Second).String()+" ago")
		}
	} else {
		connection := green
		if g, ok := m.gauges[h.Name]; ok && m.animation && !m.paused && time.Since(g.At) < 600*time.Millisecond {
			connection = accent.Bold(true)
		}
		vmBody = connection.Render("● connected") + muted.Render(" · "+h.Metrics.Name) + "\n" + m.metricBody(h.Metrics, m.previousRemote[h.Name], h.Name, width-4, height-4)
	}
	return box(vmTitle, vmBody, width, height, m.focus == 0)
}

func (m *model) topView(l dimensions) string {
	w := (m.width - 1) / 2
	height := l.top - 1
	vm := m.vmView(w, height)
	localWidth := m.width - w - 1
	identity := text.Render(fit(m.local.OS, localWidth-4))
	localMetrics := m.local
	if m.local.At.IsZero() && m.localBusy {
		identity = accent.Render(m.spinner() + " reading local metrics…")
		localMetrics.CPU = -1
	} else if !m.local.At.IsZero() {
		pulse := green
		if g, ok := m.gauges["local"]; ok && m.animation && !m.paused && time.Since(g.At) < 600*time.Millisecond {
			pulse = accent.Bold(true)
		}
		identity = pulse.Render("● ") + identity
	}
	if m.local.Error != "" {
		identity = amber.Render(fit(m.local.Error, localWidth-4))
	}
	localBody := identity + "\n" + m.metricBody(localMetrics, m.previousLocal, "local", localWidth-4, height-4)
	local := box("LOCAL / "+clean(m.local.Name), localBody, localWidth, height, false)
	return lipgloss.JoinHorizontal(lipgloss.Top, vm, " ", local) + "\n" + cell(" "+dockerSummary(m.host()), m.width)
}

func dockerSummary(h remote) string {
	label := accent.Render("DOCKER / "+clean(h.Name)) + " · "
	if h.Error != "" {
		return label + amber.Render("unknown · VM disconnected")
	}
	if h.Docker != "ready" {
		return label + amber.Render("unavailable")
	}
	running := 0
	for _, c := range h.Containers {
		if c.State == "running" {
			running++
		}
	}
	return label + green.Render(fmt.Sprintf("%d running", running)) + muted.Render(fmt.Sprintf(" · %d stopped · %d total", len(h.Containers)-running, len(h.Containers)))
}

func (m *model) resourceLines(width int) []string {
	h := m.host()
	body := dockerSummary(h)
	if h.Error != "" {
		body += "\n\n" + clean(h.Error) + "\nReconnect to refresh Docker."
	} else if h.Docker != "ready" {
		body += "\n\nPrepare VM from the command palette."
	} else if len(h.Containers) == 0 {
		body += "\n\nNo owned containers on this VM."
	} else {
		for _, c := range h.Containers {
			workspace := "unregistered"
			for _, p := range m.inv.Projects {
				if p.Host == h.Name && (p.Container == c.Names || c.ProjectID == p.ID) {
					workspace = clean(p.Name)
					break
				}
			}
			cpu, memory := containerUsage(c)
			role := c.Role
			if role == "" {
				role = "workspace"
			}
			body += "\n\n" + text.Render(clean(c.Names)) + " · " + status(c.State) + "\n" + muted.Render("Repository: "+workspace+" · Role: "+role) + "\nCPU " + cpu + " · MEM " + memory
		}
	}
	return strings.Split(ansi.Wrap(body, width, ""), "\n")
}

func (m *model) resourceView() string {
	w, h := max(8, min(90, m.width-4)), max(5, m.height-6)
	lines := m.resourceLines(max(1, w-4))
	rows := max(1, h-4)
	m.overlayScroll = max(0, min(m.overlayScroll, len(lines)-rows))
	end := min(len(lines), m.overlayScroll+rows)
	body := strings.Join(lines[m.overlayScroll:end], "\n")
	for i := end - m.overlayScroll; i < rows; i++ {
		body += "\n"
	}
	body += "\n" + muted.Render(fmt.Sprintf("%d–%d of %d lines · ↑↓ scroll", m.overlayScroll+1, end, len(lines)))
	return lipgloss.Place(m.width, max(1, m.height-4), lipgloss.Center, lipgloss.Center, box("DOCKER / "+clean(m.host().Name)+" · owned containers", body, w, h, true))
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
	nameWidth := max(8, min(28, inside/6))
	hostWidth := max(8, min(20, inside/8))
	stateWidth := 12
	syncWidth := 16
	header := cell("PROJECT", nameWidth) + " " + cell("HOST", hostWidth) + " " + cell("CONTAINER", stateWidth) + " " + cell("SYNC", syncWidth)
	wide := m.width >= 95
	if wide {
		header += " " + cell("SERVER", 12) + " " + cell("CPU", 7) + " " + cell("MEM", 11)
		if m.width >= 120 {
			header += " PORT"
		}
	}
	if l.compact || m.width < 65 {
		nameWidth = max(8, min(inside/3, inside-20))
		header = cell("PROJECT", nameWidth) + " STATE / SYNC"
	}
	lines := []string{muted.Render(fit(header, inside))}
	start := m.projectStart()
	rows := max(1, l.projects-4)
	for i := start; i < min(len(list), start+rows); i++ {
		p := list[i]
		h := m.remotes[p.Host]
		state := p.runtime(h)
		sync := syncLabel(m.syncs, p.Sync, m.syncError)
		mark := " "
		if p.ID == m.current().ID {
			mark = "›"
		}
		syncText := status(sync)
		if sync == "transferring" && m.animation && !m.paused {
			syncText = accent.Render([]string{"⇡", "⇅", "⇣", "⇅"}[m.frame/2%4] + " transferring")
		}
		line := cell(mark+" "+clean(p.Name), nameWidth) + " " + cell(muted.Render(clean(p.Host)), hostWidth) + " " + cell(status(state), stateWidth) + " " + cell(syncText, syncWidth)
		if wide {
			cpu, memory := p.usage(h)
			memory, _, _ = strings.Cut(memory, " / ")
			line += " " + cell(status(p.health(h)), 12) + " " + cell(text.Render(cpu), 7) + " " + cell(text.Render(memory), 11)
			if m.width >= 120 {
				line += " " + muted.Render(clean(p.Port))
			}
		}
		if l.compact || m.width < 65 {
			line = cell(mark+" "+clean(p.Name), nameWidth) + " " + status(state) + " / " + syncText
		}
		style := m.workspaceStyle(p.ID)
		line = cell(line, inside)
		if _, plain := style.GetBackground().(lipgloss.NoColor); !plain {
			// Nested status resets would interrupt the full-row background.
			line = ansi.Strip(line)
		}
		line = style.Render(line)
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
			icon := "·"
			switch {
			case strings.Contains(e.Text, "failed"), strings.Contains(e.Text, "disconnected"):
				icon = red.Render("✗")
			case strings.Contains(e.Text, "completed"), strings.Contains(e.Text, "connected"):
				icon = green.Render("✓")
			case strings.Contains(e.Text, "started"):
				icon = accent.Render("▶")
			case strings.Contains(e.Text, "sync"):
				icon = accent.Render("⇅")
			}
			timestamp, message := muted, text
			if m.animation && !m.paused {
				age := time.Since(e.At)
				if age < 2*time.Second {
					timestamp = accent
				}
				if age < 600*time.Millisecond {
					message = text.Bold(true)
				}
			}
			lines = append(lines, timestamp.Render(e.At.Format("15:04:05"))+"  "+icon+" "+message.Render(e.Text))
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
	if m.overlay == "resources" {
		return m.resourceView()
	}
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
		cpu, memory := p.usage(m.remotes[p.Host])
		body += "\nCPU        " + cpu + "\nMemory     " + memory
		body += "\n\n" + developmentSummary(m.developments[p.ID]) + "\nD opens the development menu."
	case "stop":
		title = "STOP WORKSPACE"
		body = "Stop " + clean(p.Name) + " and flush synchronization? Development services, Android, viewer, and app forwards stop. Persistent service/device data is kept.\n\n" + amber.Render("The server session will be interrupted.")
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
	if m.animation && !m.lastPoll.IsZero() {
		dots := max(0, min(3, 3-int(time.Since(m.lastPoll)/time.Second)))
		right = green.Render("LIVE ") + accent.Render(strings.Repeat("●", dots)) + muted.Render(strings.Repeat("○", 3-dots))
	}
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
		if m.focus == 0 {
			content = m.vmView(m.width, l.projects-1) + "\n" + cell(" "+dockerSummary(m.host()), m.width)
		} else if m.focus == 3 {
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
	pathLine := muted.Render(cell(" "+clean(path), w))
	if m.copyNotice != "" && w < 80 {
		pathLine = cell(" "+m.copyToast(), w)
	}
	view := header + "\n" + content + "\n" + cell(fit(foot, w), w) + "\n" + pathLine
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
		row("1 / 3 / 4", "Focus VM / Workspaces / Activity"),
		row("↑↓ · j/k", "Move or scroll"),
		row("g / G", "First / last"),
		row("Ctrl-D/U", "Page down / up"),
		row("[ / ]", "Select VM"),
		row("Esc", "Back / cancel"),
		"", accent.Bold(true).Render("WORKSPACES"),
		row("/", "Filter projects"),
		row("Enter", "Project details (VM: owned containers)"),
		row("o", "Attach OpenCode"),
		row("D", "Development menu / app URLs / Android"),
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
		"", muted.Render("LOAD 1/5/15m: whole-machine load averages; not CPU %."),
		muted.Render("Compare with logical CPU count for CPU-heavy work."),
		muted.Render("Linux load also includes uninterruptible waits, often disk I/O."),
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
	case m.overlay == "resources":
		items = []string{"Esc close", "↑↓ scroll", "[/] VM", "g/G ends", "R refresh", "p pause"}
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
			items = append(items, "c connect", "Enter resources", "[/] VM", "↑↓ select VM")
		case 2:
			if m.current().ID == "" {
				items = append(items, "n add repo", "/ filter")
			} else {
				items = append(items, "Enter details", "o OpenCode", "/ filter")
			}
		case 3:
			items = append(items, "↑↓ scroll", "Y copy", "G follow", "a activity")
		}
		items = append(items, "q quit", "Tab panels", "R refresh", "p pause")
	}
	var parts []string
	used := 1
	toast := ""
	if m.copyNotice != "" && width >= 80 {
		toast = fit(m.copyToast(), width/3)
		width -= lipgloss.Width(toast) + 2
	}
	separator := muted.Render(" · ")
	if width < 60 {
		separator = " "
	}
	for _, item := range items {
		key, action, _ := strings.Cut(item, " ")
		badge := accent.Bold(true).Background(lipgloss.Color("#22354A")).Render(" " + key + " ")
		part := badge + muted.Render(action)
		n := lipgloss.Width(part)
		if len(parts) > 0 {
			n += lipgloss.Width(separator)
		}
		if used+n > width {
			continue
		}
		parts = append(parts, part)
		used += n
	}
	footer := " " + strings.Join(parts, separator)
	if toast != "" {
		footer = cell(footer, width) + "  " + toast
	}
	return footer
}

func (m *model) copyToast() string {
	style, icon := green.Background(lipgloss.Color("#1B332C")), "✓"
	if strings.HasPrefix(m.copyNotice, "Copy failed:") {
		style, icon = red.Background(lipgloss.Color("#3D252E")), "✗"
	}
	if m.animation && !m.copyStarted.IsZero() && time.Since(m.copyStarted) >= 2500*time.Millisecond {
		style = muted.Background(lipgloss.Color("#1A2532"))
	}
	return style.Render(" " + icon + " " + m.copyNotice + " ")
}
