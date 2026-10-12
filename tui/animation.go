package main

import (
	"math"
	"time"
)

const gaugeDuration = 400 * time.Millisecond

type gaugeTransition struct {
	From, To [3]float64
	At       time.Time
}

func metricPercents(v metrics) [3]float64 {
	values := [3]float64{v.CPU, -1, -1}
	if v.MemoryTotal > 0 {
		values[1] = 100 * float64(v.MemoryUsed) / float64(v.MemoryTotal)
	}
	if v.DiskTotal > 0 {
		values[2] = 100 * float64(v.DiskUsed) / float64(v.DiskTotal)
	}
	return values
}

func (g gaugeTransition) valuesAt(now time.Time) [3]float64 {
	t := max(0, min(1, float64(now.Sub(g.At))/float64(gaugeDuration)))
	ease := 1 - math.Pow(1-t, 3)
	var values [3]float64
	for i := range values {
		values[i] = g.From[i] + (g.To[i]-g.From[i])*ease
	}
	return values
}

func (m *model) transition(key string, v metrics) {
	now := time.Now()
	to := metricPercents(v)
	from := to
	if old, ok := m.gauges[key]; ok && m.animation && !m.paused {
		from = old.valuesAt(now)
	}
	for i := range to {
		if from[i] < 0 || to[i] < 0 {
			from[i] = to[i]
		}
	}
	m.gauges[key] = gaugeTransition{From: from, To: to, At: now}
}

func (m *model) displayedPercents(key string, v metrics) [3]float64 {
	if g, ok := m.gauges[key]; ok && m.animation && !m.paused {
		return g.valuesAt(time.Now())
	}
	return metricPercents(v)
}

func (m *model) needsFrames(now time.Time) bool {
	if m.work != "" {
		return true
	}
	if !m.animation {
		return false
	}
	if m.action != "" || m.overlay == "loading" || !m.copyStarted.IsZero() && now.Sub(m.copyStarted) < 3*time.Second {
		return true
	}
	if m.paused || m.overlay == "session" || m.exclusive || m.installing {
		return false
	}
	if m.busy() {
		return true
	}
	for _, g := range m.gauges {
		if now.Sub(g.At) < 600*time.Millisecond {
			return true
		}
	}
	for _, at := range m.changed {
		if now.Sub(at) < 1500*time.Millisecond {
			return true
		}
	}
	if !m.logs && len(m.events) > 0 && now.Sub(m.events[len(m.events)-1].At) < 2*time.Second {
		return true
	}
	return false
}

func (m *model) frameDelay(now time.Time) time.Duration {
	if m.needsFrames(now) {
		return 100 * time.Millisecond
	}
	if m.animation && !m.paused && !m.exclusive && !m.installing && m.overlay == "" {
		return time.Second
	}
	return 0
}
