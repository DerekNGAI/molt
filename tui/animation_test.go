package main

import (
	"io"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/vt"
	"github.com/muesli/termenv"
)

func TestCPUTrendStaysWithCPUGauge(t *testing.T) {
	m := resourceModel(t)
	m.history["local"] = []float64{25, 50, 75}
	v := metrics{CPU: 40, MemoryUsed: 1 << 30, MemoryTotal: 8 << 30, DiskUsed: 4 << 30, DiskTotal: 16 << 30, CPUName: "CPU model", Load: "1 2 3"}
	for _, size := range [][2]int{{60, 7}, {40, 5}, {30, 6}} {
		lines := strings.Split(ansi.Strip(m.metricBody(v, metrics{}, "local", size[0], size[1])), "\n")
		cpu, trend, mem := -1, -1, -1
		for i, line := range lines {
			if strings.HasPrefix(line, "CPU  ") {
				cpu = i
			}
			if strings.Contains(line, "▃▅▆") {
				trend = i
			}
			if strings.HasPrefix(line, "MEM  ") {
				mem = i
			}
		}
		if trend < cpu || trend > cpu+1 || trend >= mem {
			t.Fatalf("size %v separates CPU trend from its gauge:\n%s", size, strings.Join(lines, "\n"))
		}
		if len(lines) > size[1] {
			t.Fatalf("metric rows overflow %v", size)
		}
	}
	if got := ansi.Strip(spark([]float64{25, 50, 75}, 12)); !strings.HasPrefix(got, "▃▅▆") {
		t.Fatalf("new CPU history is displaced to the right: %q", got)
	}
}

func TestGaugesEaseButNumbersStayCurrent(t *testing.T) {
	m := resourceModel(t)
	m.animation = true
	m.Update(localMsg{metrics{CPU: 25, At: time.Now()}})
	bar := func() string {
		line := strings.Split(ansi.Strip(m.metricBody(m.local, metrics{}, "local", 40, 3)), "\n")[0]
		return ansi.Cut(line, 5, 17)
	}
	before := bar()
	m.Update(localMsg{metrics{CPU: 90, At: time.Now()}})
	if got := bar(); got != before {
		t.Fatalf("gauge jumped from %q to %q on a sample", before, got)
	}
	if !strings.Contains(ansi.Strip(m.metricBody(m.local, metrics{}, "local", 40, 3)), "90%") {
		t.Fatal("easing hid the latest CPU reading")
	}
	m.animation = false
	if bar() == before {
		t.Fatal("animations off retained an old gauge fill")
	}
}

func TestIdleAnimationKeepsCountdownTick(t *testing.T) {
	m := resourceModel(t)
	m.events = nil
	m.animation = true
	if _, cmd := m.Update(frameMsg(time.Now())); cmd == nil {
		t.Fatal("idle countdown stopped after active animation")
	}
	m.animation = false
	if _, cmd := m.Update(frameMsg(time.Now())); cmd != nil {
		t.Fatal("disabled animations kept a decorative timer")
	}
}

func TestWorkspaceChangesHighlightAndExpire(t *testing.T) {
	profile := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	defer lipgloss.SetColorProfile(profile)
	m := resourceModel(t)
	m.animation, m.focus = true, 2
	p := m.inv.Projects[1]
	h := m.remotes[p.Host]
	h.Containers = append([]container(nil), h.Containers...)
	h.Containers[1].State = "exited"
	m.Update(remoteMsg{h})
	if m.changed[p.ID].IsZero() {
		t.Fatal("runtime change was not highlighted")
	}
	highlighted := func() bool {
		view := m.View()
		term := vt.NewEmulator(m.width, m.height)
		defer term.InputPipe().(io.Closer).Close()
		term.Write([]byte(strings.ReplaceAll(view, "\n", "\r\n")))
		for y, line := range strings.Split(ansi.Strip(view), "\n") {
			if strings.Contains(line, p.Name) {
				for _, x := range []int{2, m.width - 4} {
					bg := term.CellAt(x, y).Style.Bg
					if bg == nil {
						return false
					}
					r, g, b, _ := bg.RGBA()
					if !(r > g && g > b) {
						return false
					}
				}
				return true
			}
		}
		return false
	}
	if !highlighted() {
		t.Fatal("changed workspace has no amber background")
	}
	m.changed[p.ID] = time.Now().Add(-2 * time.Second)
	if highlighted() {
		t.Fatal("workspace highlight did not expire")
	}
	h.Containers = append([]container(nil), h.Containers...)
	h.Containers[1].Health = "unhealthy"
	m.Update(remoteMsg{h})
	if time.Since(m.changed[p.ID]) > time.Second {
		t.Fatal("server health change did not renew highlight")
	}
	m.syncs[p.Sync] = syncState{Alpha: syncEndpoint{Connected: true}, Beta: syncEndpoint{Connected: true}}
	m.changed[p.ID] = time.Now().Add(-2 * time.Second)
	m.Update(syncMsg{States: map[string]syncState{p.Sync: {Paused: true}}})
	if time.Since(m.changed[p.ID]) > time.Second {
		t.Fatal("sync change did not renew highlight")
	}
}

func TestStatusAndActivityIconsExplainState(t *testing.T) {
	for label, icon := range map[string]string{"running": "●", "exited": "○", "unknown": "◐", "unhealthy": "✕", "transferring": "⇅"} {
		if got := ansi.Strip(status(label)); got != icon+" "+label {
			t.Errorf("status %q = %q", label, got)
		}
	}
	m := resourceModel(t)
	m.events = []event{{time.Now(), "vm disconnected"}, {time.Now(), "Build completed"}, {time.Now(), "Build started"}}
	lines := m.activityLines()
	for i, icon := range []string{"✗", "✓", "▶"} {
		if !strings.Contains(ansi.Strip(lines[i]), icon) {
			t.Fatalf("event %d lost icon %s", i, icon)
		}
	}
}

func TestActionProgressMovesWithoutLosingClocks(t *testing.T) {
	m := resourceModel(t)
	m.animation, m.action = true, "Building"
	m.actionStage = "Building container image"
	m.actionStarted, m.stageStarted = time.Now(), time.Now()
	before := ansi.Strip(m.actionSummary())
	m.frame = 6
	after := ansi.Strip(m.actionSummary())
	if before == after {
		t.Fatal("action progress did not move")
	}
	for _, s := range []string{"Building container image", "Elapsed:", "step:"} {
		if !strings.Contains(after, s) {
			t.Fatalf("progress hid %s", s)
		}
	}
	m.animation = false
	before = ansi.Strip(m.actionSummary())
	m.frame++
	if ansi.Strip(m.actionSummary()) != before {
		t.Fatal("disabled animations move progress")
	}
}

func TestCopyToastPreservesCompactControls(t *testing.T) {
	m := resourceModel(t)
	m.width, m.height, m.focus = 42, 14, 2
	m.copyNotice = "Copied to clipboard"
	view := ansi.Strip(m.View())
	lines := strings.Split(view, "\n")
	for _, hint := range []string{": commands", "? help", "Enter details"} {
		if !strings.Contains(lines[len(lines)-2], hint) {
			t.Fatalf("copy toast hid %q: %s", hint, lines[len(lines)-2])
		}
	}
	if !strings.Contains(view, "Copied to clipboard") {
		t.Fatal("compact copy success is hidden")
	}
}

func TestAnimationTimingAndTimerChains(t *testing.T) {
	m := resourceModel(t)
	m.animation = true
	m.events = nil
	now := time.Now()
	if m.frameDelay(now) != time.Second {
		t.Fatal("idle dashboard should tick once per second")
	}
	m.transition("local", metrics{CPU: 10})
	m.transition("local", metrics{CPU: 90})
	g := m.gauges["local"]
	if values := g.valuesAt(g.At.Add(gaugeDuration)); values[0] != 90 {
		t.Fatalf("gauge never settled: %v", values)
	}
	if m.frameDelay(now) != 100*time.Millisecond {
		t.Fatal("fresh samples need smooth frames")
	}
	if m.animate() == nil || m.animate() != nil {
		t.Fatal("animation did not start exactly one active timer chain")
	}
	g.At = now.Add(-time.Second)
	m.gauges["local"] = g
	if m.frameDelay(now) != time.Second {
		t.Fatal("settled gauge retained fast frames")
	}
	m.paused = true
	if m.frameDelay(now) != 0 {
		t.Fatal("paused monitoring retained an idle timer")
	}
	m.animation = false
	m.work = t.TempDir()
	if m.frameDelay(now) != 100*time.Millisecond {
		t.Fatal("reduced motion stops action output polling")
	}
}

func TestLongCopyErrorKeepsActionControls(t *testing.T) {
	m := resourceModel(t)
	m.width, m.height, m.overlay = 80, 24, "action"
	m.copyNotice = "Copy failed: " + strings.Repeat("clipboard unavailable ", 10)
	lines := strings.Split(ansi.Strip(m.View()), "\n")
	footer := lines[len(lines)-2]
	for _, hint := range []string{"Esc cancel", "Y copy", "↑↓ scroll"} {
		if !strings.Contains(footer, hint) {
			t.Fatalf("long clipboard error hid %q: %s", hint, footer)
		}
	}
}

func TestManualRefreshKeepsScheduledCountdown(t *testing.T) {
	m := resourceModel(t)
	m.animation = true
	m.events = nil
	m.lastPoll = time.Now().Add(-2200 * time.Millisecond)
	m.poll()
	m.invBusy, m.localBusy, m.syncBusy = false, false, false
	for name := range m.remoteBusy {
		m.remoteBusy[name] = false
	}
	if !strings.Contains(ansi.Strip(m.View()), "LIVE ●○○") {
		t.Fatal("manual sampling reset the countdown to the scheduled refresh")
	}
}
