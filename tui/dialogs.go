package main

import (
	"context"
	"fmt"
	"image"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

type menuItem struct {
	Title string
	Run   func() tea.Cmd
}
type menuState struct {
	Title, Help string
	Items       []menuItem
	Details     []string
	Index       int
	Back        func() tea.Cmd
}
type formField struct {
	Label, Value string
	Optional     bool
}
type formState struct {
	Title, Help, Error string
	Fields             []formField
	Index, Cursor      int
	Submit             func([]string) tea.Cmd
	Back               func() tea.Cmd
}
type dialogState struct {
	Title, Body string
	Back, Yes   func() tea.Cmd
	Retry       func() tea.Cmd
}
type editorState struct {
	Text   []rune
	Cursor int
	Save   func(string) tea.Cmd
	Back   func() tea.Cmd
	File   string
}
type queryMsg struct {
	ID    int
	Data  []byte
	Error error
}

func (m *model) dashboard() tea.Cmd { m.overlay = ""; return nil }
func (m *model) screen(name string) func() tea.Cmd {
	return func() tea.Cmd { return m.openScreen(name) }
}
func (m *model) showMenu(title, help string, back func() tea.Cmd, items ...menuItem) tea.Cmd {
	m.overlay = "native-menu"
	m.menu = menuState{Title: title, Help: help, Items: items, Back: back}
	return nil
}
func (m *model) showForm(title, help string, back func() tea.Cmd, submit func([]string) tea.Cmd, fields ...formField) tea.Cmd {
	m.overlay = "form"
	m.form = formState{Title: title, Help: help, Fields: fields, Back: back, Submit: submit}
	if len(fields) > 0 {
		m.form.Cursor = len([]rune(fields[0].Value))
	}
	return nil
}
func (m *model) showMessage(title, body string, back func() tea.Cmd) tea.Cmd {
	m.selection, m.rendered = nil, ""
	m.overlay, m.overlayScroll = "message", 0
	m.dialog = dialogState{Title: title, Body: safeText(body), Back: back}
	return nil
}
func (m *model) confirm(title, body string, back, yes func() tea.Cmd) tea.Cmd {
	m.overlay, m.overlayScroll = "confirm", 0
	m.dialog = dialogState{Title: title, Body: body, Back: back, Yes: yes}
	return nil
}
func back(cmd func() tea.Cmd) tea.Cmd {
	if cmd != nil {
		return cmd()
	}
	return nil
}

func (m *model) fetch(title string, returnTo func() tea.Cmd, done func([]byte) tea.Cmd, args ...string) tea.Cmd {
	if m.queryCancel != nil {
		m.queryCancel()
	}
	m.queryID++
	id := m.queryID
	ctx, cancel := context.WithTimeout(m.b.Context, 30*time.Second)
	m.queryCancel, m.onQuery = cancel, done
	m.onQueryError = nil
	m.overlay = "loading"
	m.dialog = dialogState{Title: title, Body: "Loading…", Back: returnTo}
	b := m.b
	b.Context = ctx
	return func() tea.Msg {
		defer cancel()
		data, err := b.output(30*time.Second, args...)
		return queryMsg{id, data, err}
	}
}
func (m *model) finishQuery(msg queryMsg) tea.Cmd {
	if msg.ID != m.queryID || m.overlay != "loading" {
		return nil
	}
	m.queryCancel = nil
	if msg.Error != nil {
		if m.onQueryError != nil {
			return m.onQueryError(msg.Error)
		}
		return m.showMessage(m.dialog.Title+" · failed", msg.Error.Error(), m.dialog.Back)
	}
	return m.onQuery(msg.Data)
}

func (m *model) run(title string, returnTo, next func() tea.Cmd, args ...string) tea.Cmd {
	return m.runProgram(title, returnTo, next, m.b.CLI, args...)
}
func (m *model) runProgram(title string, returnTo, next func() tea.Cmd, program string, args ...string) tea.Cmd {
	if m.action != "" || m.sessionCancel != nil {
		return m.showMessage("Action in progress", "Finish or cancel the current operation first.", returnTo)
	}
	m.overlay = "action"
	m.actionFailure = nil
	m.dialog = dialogState{Title: title, Back: returnTo}
	m.afterAction, m.actionBack = next, returnTo
	m.retry = func() tea.Cmd { return m.runProgram(title, returnTo, next, program, args...) }
	if program == m.b.CLI {
		return m.withActionConnections(args, returnTo, func() tea.Cmd { m.overlay = "action"; return m.startProcess(title, program, args...) })
	}
	return m.startProcess(title, program, args...)
}

func (m *model) nativeKey(msg tea.KeyMsg) (tea.Cmd, bool) {
	k := msg.String()
	switch m.overlay {
	case "session":
		return m.sessionKey(msg), true
	case "native-menu":
		switch k {
		case "esc", "ctrl+c":
			return back(m.menu.Back), true
		case "j", "down":
			m.menu.Index = min(len(m.menu.Items)-1, m.menu.Index+1)
		case "k", "up":
			m.menu.Index = max(0, m.menu.Index-1)
		case "home", "g":
			m.menu.Index = 0
		case "end", "G":
			m.menu.Index = max(0, len(m.menu.Items)-1)
		case "enter":
			if m.menu.Index >= 0 && m.menu.Index < len(m.menu.Items) {
				return back(m.menu.Items[m.menu.Index].Run), true
			}
		case "i":
			if m.menu.Index >= 0 && m.menu.Index < len(m.menu.Details) && m.menu.Details[m.menu.Index] != "" {
				snapshot := m.menu
				return m.showMessage("Details / "+snapshot.Items[snapshot.Index].Title, snapshot.Details[snapshot.Index], func() tea.Cmd { m.menu = snapshot; m.overlay = "native-menu"; return nil }), true
			}
		}
	case "form":
		if k == "esc" || k == "ctrl+c" {
			return back(m.form.Back), true
		}
		if len(m.form.Fields) == 0 {
			return nil, true
		}
		f := &m.form.Fields[m.form.Index]
		if k == "enter" && m.form.Index == len(m.form.Fields)-1 {
			values := make([]string, len(m.form.Fields))
			for i, field := range m.form.Fields {
				values[i] = field.Value
				if !field.Optional && strings.TrimSpace(field.Value) == "" {
					m.form.Index, m.form.Cursor = i, len([]rune(field.Value))
					m.form.Error = field.Label + " is required"
					return nil, true
				}
			}
			return m.form.Submit(values), true
		}
		switch k {
		case "tab", "down", "enter":
			m.form.Index = (m.form.Index + 1) % len(m.form.Fields)
			m.form.Cursor = len([]rune(m.form.Fields[m.form.Index].Value))
		case "shift+tab", "up":
			m.form.Index = (m.form.Index + len(m.form.Fields) - 1) % len(m.form.Fields)
			m.form.Cursor = len([]rune(m.form.Fields[m.form.Index].Value))
		default:
			r := []rune(f.Value)
			r, m.form.Cursor = editText(r, m.form.Cursor, msg, false)
			f.Value = string(r)
			m.form.Error = ""
		}
	case "confirm":
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
		if k == "y" {
			return back(m.dialog.Yes), true
		}
		if k == "n" || k == "esc" || k == "ctrl+c" {
			return back(m.dialog.Back), true
		}
	case "message", "loading":
		if k == "esc" || k == "enter" || k == "ctrl+c" {
			if m.queryCancel != nil {
				m.queryCancel()
				m.queryCancel = nil
				m.queryID++
			}
			return back(m.dialog.Back), true
		}
		if m.overlay == "message" {
			switch k {
			case "j", "down":
				m.overlayScroll++
			case "k", "up":
				m.overlayScroll = max(0, m.overlayScroll-1)
			case "ctrl+d", "pgdown":
				m.overlayScroll += 5
			case "ctrl+u", "pgup":
				m.overlayScroll = max(0, m.overlayScroll-5)
			case "r":
				if m.dialog.Retry != nil {
					return m.dialog.Retry(), true
				}
			}
		}
	case "action":
		switch k {
		case "esc", "ctrl+c":
			m.overlay, m.overlayScroll = "cancel", 0
		case "q":
			m.overlay, m.overlayScroll = "quit", 0
		case "j", "down":
			m.scroll = max(0, m.scroll-1)
		case "k", "up":
			m.scroll++
		}
	case "editor":
		switch k {
		case "esc", "ctrl+c":
			snapshot := m.editor
			return m.confirm("Discard server settings?", "Unsaved edits will be discarded.", func() tea.Cmd { m.editor = snapshot; m.overlay = "editor"; return nil }, snapshot.Back), true
		case "ctrl+s", "ctrl+d":
			snapshot := m.editor
			return m.confirm("Save server settings?", "Settings apply to projects sharing this VM workspace. Restart projects to apply changes.", func() tea.Cmd { m.editor = snapshot; m.overlay = "editor"; return nil }, func() tea.Cmd { return snapshot.Save(string(snapshot.Text)) }), true
		default:
			m.editor.Text, m.editor.Cursor = editText(m.editor.Text, m.editor.Cursor, msg, true)
		}
	default:
		return nil, false
	}
	return nil, true
}

func editText(text []rune, cursor int, msg tea.KeyMsg, multiline bool) ([]rune, int) {
	cursor = max(0, min(cursor, len(text)))
	start, end := cursor, cursor
	for start > 0 && text[start-1] != '\n' {
		start--
	}
	for end < len(text) && text[end] != '\n' {
		end++
	}
	switch msg.String() {
	case "left":
		cursor = max(0, cursor-1)
	case "right":
		cursor = min(len(text), cursor+1)
	case "home", "ctrl+a":
		cursor = start
	case "end", "ctrl+e":
		cursor = end
	case "ctrl+u":
		text = append(text[:start], text[cursor:]...)
		cursor = start
	case "ctrl+k":
		text = append(text[:cursor], text[end:]...)
	case "backspace", "ctrl+h":
		if cursor > 0 {
			text = append(text[:cursor-1], text[cursor:]...)
			cursor--
		}
	case "delete":
		if cursor < len(text) {
			text = append(text[:cursor], text[cursor+1:]...)
		}
	case "up":
		if multiline && start > 0 {
			previous := start - 1
			for previous > 0 && text[previous-1] != '\n' {
				previous--
			}
			cursor = min(start-1, previous+cursor-start)
		}
	case "down":
		if multiline && end < len(text) {
			next := end + 1
			for next < len(text) && text[next] != '\n' {
				next++
			}
			cursor = min(next, end+1+cursor-start)
		}
	default:
		var insert []rune
		if msg.Type == tea.KeyRunes {
			insert = []rune(safeText(string(msg.Runes)))
		}
		if multiline && msg.Type == tea.KeyEnter {
			insert = []rune{'\n'}
		}
		if multiline && msg.Type == tea.KeyTab {
			insert = []rune{' ', ' '}
		}
		if !multiline {
			insert = []rune(clean(string(insert)))
		}
		if len(insert) > 0 {
			tail := append([]rune(nil), text[cursor:]...)
			text = append(append(text[:cursor], insert...), tail...)
			cursor += len(insert)
		}
	}
	return text, cursor
}

func (m *model) nativeMouse(msg tea.MouseMsg) bool {
	if m.overlay == "native-menu" {
		if msg.Button == tea.MouseButtonWheelUp {
			m.menu.Index = max(0, m.menu.Index-1)
		}
		if msg.Button == tea.MouseButtonWheelDown {
			m.menu.Index = min(len(m.menu.Items)-1, m.menu.Index+1)
		}
		return true
	}
	return false
}

func (m *model) nativeView() (string, bool) {
	w, h := max(8, min(90, m.width-4)), max(5, m.height-6)
	capacity := max(1, h-3)
	title, body := "", ""
	switch m.overlay {
	case "session":
		return m.sessionView(), true
	case "native-menu":
		return m.menuView(m.menu), true
	case "form":
		title = m.form.Title
		body = fit(clean(m.form.Help), w-4) + "\n"
		f := m.form.Fields[m.form.Index]
		body += fmt.Sprintf("\n%s  (%d/%d)\n", clean(f.Label), m.form.Index+1, len(m.form.Fields))
		r := []rune(f.Value)
		cursor := max(0, min(m.form.Cursor, len(r)))
		value := clean(string(r[:cursor])) + "▏" + clean(string(r[cursor:]))
		// Keep the insertion point visible for paths wider than the form.
		offset := max(0, lipgloss.Width(string(r[:cursor]))-(w-8))
		body += text.Render(ansi.Cut(value, offset, offset+w-4)) + "\n" + red.Render(fit(m.form.Error, w-4))
		if h <= 10 {
			body = fmt.Sprintf("%s (%d/%d)\n%s\n%s", clean(f.Label), m.form.Index+1, len(m.form.Fields), text.Render(ansi.Cut(value, offset, offset+w-4)), red.Render(fit(m.form.Error, w-4)))
		}
	case "confirm", "message", "loading":
		title, body = m.dialog.Title, m.dialog.Body
		lines := strings.Split(ansi.Wrap(body, max(1, w-4), ""), "\n")
		start := min(m.overlayScroll, max(0, len(lines)-capacity))
		body = strings.Join(lines[start:min(len(lines), start+capacity)], "\n")
	case "action":
		title = m.action + " · " + m.spinner() + " running"
		end := max(0, len(m.output)-m.scroll)
		body = strings.Join(m.output[max(0, end-capacity):end], "\n")
		if body == "" {
			body = "Waiting for output…"
		}
	case "editor":
		title = "SERVER SETTINGS / JSONC"
		r := m.editor.Text
		cursor := max(0, min(m.editor.Cursor, len(r)))
		lines := strings.Split(ansi.Hardwrap(string(r[:cursor])+"▏"+string(r[cursor:]), max(1, w-4), true), "\n")
		before := ansi.Hardwrap(string(r[:cursor]), max(1, w-4), true)
		line := strings.Count(before, "\n")
		start := max(0, line-capacity+1)
		body = strings.Join(lines[start:min(len(lines), start+capacity)], "\n")
	default:
		return "", false
	}
	lines := strings.Split(body, "\n")
	if len(lines) > capacity {
		lines = lines[:capacity]
	}
	for len(lines) < capacity {
		lines = append(lines, "")
	}
	body = strings.Join(lines, "\n")
	panel := box(strings.ToUpper(title), body, w, h, true)
	if m.overlay == "message" || m.overlay == "action" {
		pw, ph := lipgloss.Width(panel), lipgloss.Height(panel)
		x, y := max(0, m.width-pw)/2, max(0, m.height-4-ph)/2
		m.copyArea = image.Rect(x+2, y+2, x+pw-2, y+ph-1)
	}
	return lipgloss.Place(m.width, max(1, m.height-4), lipgloss.Center, lipgloss.Center, panel), true
}

func (m *model) menuView(menu menuState) string {
	w, h := max(8, min(90, m.width-4)), max(5, m.height-6)
	width, capacity := max(1, w-4), max(1, h-3)
	var lines, detail []string
	if h > 10 && menu.Help != "" {
		help := strings.Split(ansi.Wrap(safeText(menu.Help), width, ""), "\n")
		lines = append(lines, help[:min(2, len(help))]...)
		lines = append(lines, "")
	}
	if menu.Index >= 0 && menu.Index < len(menu.Details) && menu.Details[menu.Index] != "" {
		detail = strings.Split(ansi.Wrap(safeText(menu.Details[menu.Index]), width, ""), "\n")
		detail = detail[:min(2, len(detail))]
	}
	rows := max(1, capacity-len(lines)-len(detail)-1)
	start := max(0, menu.Index-rows+1)
	end := min(len(menu.Items), start+rows)
	for i := start; i < end; i++ {
		line := fit("  "+clean(menu.Items[i].Title), width)
		if i == menu.Index {
			line = selectedStyle.Render(cell("› "+clean(menu.Items[i].Title), width))
		}
		lines = append(lines, line)
	}
	lines = append(lines, muted.Render(fmt.Sprintf("%d–%d of %d", min(start+1, end), end, len(menu.Items))))
	for _, line := range detail {
		lines = append(lines, text.Render(line))
	}
	return lipgloss.Place(m.width, max(1, m.height-4), lipgloss.Center, lipgloss.Center, box(strings.ToUpper(menu.Title), strings.Join(lines, "\n"), w, h, true))
}
