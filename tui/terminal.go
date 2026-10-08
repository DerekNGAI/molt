package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	uv "github.com/charmbracelet/ultraviolet"
	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/vt"
	"github.com/creack/pty"
)

type terminalSession struct {
	cmd    *exec.Cmd
	master *os.File
	term   *vt.Emulator
	cancel context.CancelFunc
	cursor bool
}
type sessionStartedMsg struct {
	Session *terminalSession
	Error   error
}
type sessionOutputMsg struct {
	Session *terminalSession
	Data    []byte
	Done    bool
	Error   error
}

func (m *model) sessionSize() (int, int) { return max(1, m.width-4), max(1, m.height-7) }
func (s *terminalSession) resize(w, h int) {
	s.term.Resize(w, h)
	_ = pty.Setsize(s.master, &pty.Winsize{Cols: uint16(w), Rows: uint16(h)})
}
func (s *terminalSession) close() {
	s.cancel()
	_ = s.master.Close()
	// Close the thread-safe input pipe directly. Emulator state is owned by
	// Bubble Tea; the response pump only reads this pipe.
	if pipe, ok := s.term.InputPipe().(io.Closer); ok {
		_ = pipe.Close()
	}
}
func (s *terminalSession) read() tea.Cmd {
	return func() tea.Msg {
		data := make([]byte, 32*1024)
		n, err := s.master.Read(data)
		if n > 0 {
			return sessionOutputMsg{Session: s, Data: data[:n]}
		}
		if err != nil {
			return sessionOutputMsg{Session: s, Done: true, Error: s.cmd.Wait()}
		}
		return sessionOutputMsg{Session: s}
	}
}

func (m *model) terminal(args ...string) tea.Cmd {
	title := "Terminal session"
	if len(args) > 0 {
		title = strings.Join(args, " ")
		if args[0] == "connection" && len(args) >= 3 {
			title = "SSH / " + args[2]
		}
		if args[0] == "oc-project" {
			title = "OpenCode session"
		}
	}
	return m.terminalProgram(title, m.b.CLI, args...)
}
func (m *model) terminalProgram(title, program string, args ...string) tea.Cmd {
	if m.action != "" || m.sessionCancel != nil {
		m.record("Finish or cancel the current operation first")
		return nil
	}
	if m.sessionBack == nil {
		m.sessionBack = m.dashboard
	}
	m.sessionTitle = title
	m.overlay = "session"
	ctx, cancel := context.WithCancel(m.b.Context)
	m.sessionCancel = cancel
	b := m.b
	wg := m.collectors
	exclusive := m.exclusive
	w, h := m.sessionSize()
	return func() tea.Msg {
		if exclusive {
			wg.Wait()
		}
		c := b.process(ctx, program, args...)
		c.Env = append(c.Env, "MOLT_UI_BATCH=0", "TERM=xterm-256color")
		// A controlling PTY needs its own session. Setsid creates the process
		// group used by our cancellation handler; Setpgid must not also be set.
		c.SysProcAttr = nil
		master, err := pty.StartWithSize(c, &pty.Winsize{Cols: uint16(w), Rows: uint16(h)})
		if err != nil {
			cancel()
			return sessionStartedMsg{Error: err}
		}
		s := &terminalSession{cmd: c, master: master, term: vt.NewEmulator(w, h), cancel: cancel, cursor: true}
		// x/vt currently answers public DSR with a DEC-private reply. Override
		// only that query; keep the emulator's cursor/device handlers.
		s.term.RegisterCsiHandler('n', func(params ansi.Params) bool {
			code, _, _ := params.Param(0, 0)
			if code != 5 {
				return false
			}
			_, _ = io.WriteString(s.term.InputPipe(), "\x1b[0n")
			return true
		})
		s.term.SetScrollbackSize(1000)
		s.term.SetCallbacks(vt.Callbacks{CursorVisibility: func(visible bool) { s.cursor = visible }})
		// Replies to terminal queries and encoded keyboard input return to the
		// child PTY. Child escape sequences never reach the outer terminal.
		go func() { _, _ = io.Copy(master, s.term) }()
		return sessionStartedMsg{Session: s}
	}
}
func (m *model) sessionStarted(msg sessionStartedMsg) tea.Cmd {
	if msg.Error != nil {
		m.sessionCancel = nil
		if m.exclusive {
			m.resumeCollectors()
		}
		m.exclusive = false
		m.afterSession = nil
		return m.showMessage(m.sessionTitle+" · failed", msg.Error.Error(), m.sessionBack)
	}
	m.session = msg.Session
	m.session.resize(m.sessionSize())
	return m.session.read()
}
func (m *model) sessionOutput(msg sessionOutputMsg) tea.Cmd {
	if m.session != msg.Session {
		return nil
	}
	if !msg.Done {
		_, _ = m.session.term.Write(msg.Data)
		return m.session.read()
	}
	text := m.session.term.String()
	m.session.close()
	m.session, m.sessionCancel = nil, nil
	next, returnTo := m.afterSession, m.sessionBack
	m.afterSession, m.sessionBack = nil, nil
	if m.exclusive && msg.Error == nil {
		if _, err := os.Stat(m.b.Home); os.IsNotExist(err) {
			return tea.Quit
		}
	}
	if m.exclusive {
		m.resumeCollectors()
	}
	m.exclusive = false
	if msg.Error != nil {
		m.record(m.sessionTitle + " failed · " + msg.Error.Error())
		return m.showMessage(m.sessionTitle+" · failed", clean(msg.Error.Error())+"\n\n"+text, returnTo)
	}
	m.record(m.sessionTitle + " completed")
	if next != nil {
		return next()
	}
	return m.showMessage(m.sessionTitle+" · completed", text, returnTo)
}

func (m *model) sessionKey(msg tea.KeyMsg) tea.Cmd {
	if msg.String() == "ctrl+]" {
		return m.confirm("End terminal session?", "Stop the interactive process? VM project servers and synchronization continue independently.", func() tea.Cmd { m.overlay = "session"; return nil }, func() tea.Cmd {
			m.overlay = "session"
			if m.sessionCancel != nil {
				m.sessionCancel()
			}
			return nil
		})
	}
	if m.session == nil {
		return nil
	}
	s := m.session
	if msg.Type == tea.KeyRunes {
		if msg.Paste {
			s.term.Paste(string(msg.Runes))
		} else {
			value := string(msg.Runes)
			if msg.Alt {
				value = "\x1b" + value
			}
			s.term.SendText(value)
		}
		return nil
	}
	if msg.Type >= 0 && msg.Type <= 31 {
		value := string(rune(msg.Type))
		if msg.Alt {
			value = "\x1b" + value
		}
		s.term.SendText(value)
		return nil
	}
	parts := strings.Split(msg.String(), "+")
	if len(parts) > 1 {
		modifier := 1
		for _, part := range parts[:len(parts)-1] {
			switch part {
			case "shift":
				modifier += 1
			case "alt":
				modifier += 2
			case "ctrl":
				modifier += 4
			}
		}
		name := parts[len(parts)-1]
		if final, ok := map[string]byte{"up": 'A', "down": 'B', "right": 'C', "left": 'D', "home": 'H', "end": 'F', "f1": 'P', "f2": 'Q', "f3": 'R', "f4": 'S'}[name]; ok {
			s.term.SendText(fmt.Sprintf("\x1b[1;%d%c", modifier, final))
			return nil
		}
		if code, ok := map[string]int{"insert": 2, "delete": 3, "pgup": 5, "pgdown": 6, "f5": 15, "f6": 17, "f7": 18, "f8": 19, "f9": 20, "f10": 21, "f11": 23, "f12": 24}[name]; ok {
			s.term.SendText(fmt.Sprintf("\x1b[%d;%d~", code, modifier))
			return nil
		}
	}
	codes := map[tea.KeyType]rune{tea.KeyUp: vt.KeyUp, tea.KeyDown: vt.KeyDown, tea.KeyLeft: vt.KeyLeft, tea.KeyRight: vt.KeyRight, tea.KeyHome: vt.KeyHome, tea.KeyEnd: vt.KeyEnd, tea.KeyPgUp: vt.KeyPgUp, tea.KeyPgDown: vt.KeyPgDown, tea.KeyInsert: vt.KeyInsert, tea.KeyDelete: vt.KeyDelete, tea.KeyBackspace: vt.KeyBackspace, tea.KeySpace: vt.KeySpace, tea.KeyShiftTab: vt.KeyTab, tea.KeyF1: vt.KeyF1, tea.KeyF2: vt.KeyF2, tea.KeyF3: vt.KeyF3, tea.KeyF4: vt.KeyF4, tea.KeyF5: vt.KeyF5, tea.KeyF6: vt.KeyF6, tea.KeyF7: vt.KeyF7, tea.KeyF8: vt.KeyF8, tea.KeyF9: vt.KeyF9, tea.KeyF10: vt.KeyF10, tea.KeyF11: vt.KeyF11, tea.KeyF12: vt.KeyF12}
	if code, ok := codes[msg.Type]; ok {
		key := vt.KeyPressEvent{Code: code}
		if msg.Type == tea.KeyShiftTab {
			key.Mod = vt.ModShift
		}
		if msg.Alt {
			key.Mod |= vt.ModAlt
		}
		s.term.SendKey(key)
	}
	return nil
}
func (s *terminalSession) mouse(msg tea.MouseMsg) {
	x, y := msg.X-2, msg.Y-4
	if x < 0 || y < 0 || x >= s.term.Width() || y >= s.term.Height() {
		return
	}
	buttons := map[tea.MouseButton]uv.MouseButton{tea.MouseButtonLeft: uv.MouseLeft, tea.MouseButtonMiddle: uv.MouseMiddle, tea.MouseButtonRight: uv.MouseRight, tea.MouseButtonWheelUp: uv.MouseWheelUp, tea.MouseButtonWheelDown: uv.MouseWheelDown, tea.MouseButtonWheelLeft: uv.MouseWheelLeft, tea.MouseButtonWheelRight: uv.MouseWheelRight}
	m := uv.Mouse{X: x, Y: y, Button: buttons[msg.Button]}
	if msg.Ctrl {
		m.Mod |= uv.ModCtrl
	}
	if msg.Alt {
		m.Mod |= uv.ModAlt
	}
	if msg.Shift {
		m.Mod |= uv.ModShift
	}
	switch {
	case msg.Action == tea.MouseActionMotion:
		s.term.SendMouse(uv.MouseMotionEvent(m))
	case msg.Action == tea.MouseActionRelease:
		s.term.SendMouse(uv.MouseReleaseEvent(m))
	case msg.Button >= tea.MouseButtonWheelUp && msg.Button <= tea.MouseButtonWheelRight:
		s.term.SendMouse(uv.MouseWheelEvent(m))
	default:
		s.term.SendMouse(uv.MouseClickEvent(m))
	}
}
func (m *model) sessionView() string {
	body := "Starting terminal session…"
	if m.session != nil {
		body = m.session.term.Render()
		if os.Getenv("NO_COLOR") != "" {
			body = ansi.Strip(body)
		}
		if m.session.cursor {
			pos := m.session.term.CursorPosition()
			lines := strings.Split(body, "\n")
			for len(lines) <= pos.Y {
				lines = append(lines, "")
			}
			line := cell(lines[pos.Y], m.session.term.Width())
			lines[pos.Y] = ansi.Cut(line, 0, pos.X) + lipgloss.NewStyle().Reverse(true).Render(ansi.Cut(line, pos.X, pos.X+1)) + ansi.Cut(line, pos.X+1, m.session.term.Width())
			body = strings.Join(lines, "\n")
		}
	}
	return box("SESSION / "+clean(m.sessionTitle), body, max(4, m.width), max(4, m.height-4), true)
}
