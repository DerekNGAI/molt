package main

import (
	"context"
	"image"
	"os/exec"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

type textSelection struct {
	Frame, Overlay string
	Area           image.Rectangle
	Start, End     image.Point
}

type clipboardMsg struct {
	ID    int
	Error error
}
type clearClipboardMsg int

func (m *model) copyText(value string) tea.Cmd {
	value = safeText(value)
	if strings.TrimSpace(value) == "" {
		return nil
	}
	m.copyID++
	id, parent := m.copyID, m.b.Context
	m.copyNotice = "Copying…"
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(parent, 2*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "pbcopy")
		cmd.Stdin = strings.NewReader(value)
		return clipboardMsg{ID: id, Error: cmd.Run()}
	}
}

func (m *model) copyOutput() tea.Cmd {
	switch m.overlay {
	case "message":
		return m.copyText(m.dialog.Body)
	case "action":
		return m.copyText(strings.Join(m.output, "\n"))
	case "":
		if m.focus == 3 {
			return m.copyText(strings.Join(m.activityLines(), "\n"))
		}
	}
	return nil
}

func (m *model) selectionMouse(msg tea.MouseMsg) (tea.Cmd, bool) {
	if tea.MouseEvent(msg).IsWheel() {
		m.selection = nil
		return nil, false
	}
	if m.selection != nil && m.selection.Overlay != m.overlay {
		m.selection = nil
	}
	if s := m.selection; s != nil {
		switch {
		case msg.Action == tea.MouseActionMotion && msg.Button == tea.MouseButtonLeft:
			s.move(msg.X, msg.Y)
			return nil, true
		case msg.Action == tea.MouseActionRelease && (msg.Button == tea.MouseButtonLeft || msg.Button == tea.MouseButtonNone):
			s.move(msg.X, msg.Y)
			m.selection = nil
			if s.Start != s.End {
				return m.copyText(s.text()), true
			}
			return nil, true
		}
	}
	if msg.Action == tea.MouseActionPress {
		m.selection = nil
		p := image.Pt(msg.X, msg.Y)
		if msg.Button == tea.MouseButtonLeft && p.In(m.copyArea) && m.rendered != "" {
			m.selection = &textSelection{Frame: m.rendered, Overlay: m.overlay, Area: m.copyArea, Start: p, End: p}
			if m.overlay == "" {
				m.focus = 3
			}
			return nil, true
		}
	}
	return nil, false
}

func (s *textSelection) move(x, y int) {
	s.End = image.Pt(max(s.Area.Min.X, min(s.Area.Max.X-1, x)), max(s.Area.Min.Y, min(s.Area.Max.Y-1, y)))
}

func (s *textSelection) limits() (image.Point, image.Point) {
	a, b := s.Start, s.End
	if a.Y > b.Y || a.Y == b.Y && a.X > b.X {
		a, b = b, a
	}
	return a, b
}

func (s *textSelection) columns(line string, y int) (int, int) {
	a, b := s.limits()
	left, right := s.Area.Min.X, s.Area.Max.X
	if y == a.Y {
		left = a.X
	}
	if y == b.Y {
		right = b.X + 1
	}
	// A drag can end on either cell of a wide grapheme; copy it whole.
	plain := ansi.Strip(line)
	for x := 0; len(plain) > 0 && x < right; {
		cluster, width := ansi.FirstGraphemeCluster(plain, ansi.GraphemeWidth)
		if left > x && left < x+width {
			left = x
		}
		if right > x && right < x+width {
			right = x + width
		}
		x += width
		plain = plain[len(cluster):]
	}
	return left, right
}

func (s *textSelection) text() string {
	lines := strings.Split(s.Frame, "\n")
	a, b := s.limits()
	var selected []string
	for y := a.Y; y <= b.Y; y++ {
		left, right := s.columns(lines[y], y)
		selected = append(selected, strings.TrimRight(ansi.Strip(ansi.Cut(lines[y], left, right)), " "))
	}
	return strings.Join(selected, "\n")
}

func (s *textSelection) view() string {
	if s.Start == s.End {
		return s.Frame
	}
	lines := strings.Split(s.Frame, "\n")
	a, b := s.limits()
	for y := a.Y; y <= b.Y; y++ {
		line := lines[y]
		left, right := s.columns(line, y)
		lines[y] = ansi.Cut(line, 0, left) + "\x1b[7m" + ansi.Strip(ansi.Cut(line, left, right)) + "\x1b[0m" + ansi.Cut(line, right, ansi.StringWidth(line))
	}
	return strings.Join(lines, "\n")
}
