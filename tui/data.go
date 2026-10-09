package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode"

	"github.com/charmbracelet/x/ansi"
	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/disk"
	"github.com/shirou/gopsutil/v4/host"
	"github.com/shirou/gopsutil/v4/load"
	"github.com/shirou/gopsutil/v4/mem"
	"github.com/shirou/gopsutil/v4/net"
)

const refreshInterval = 3 * time.Second

type metrics struct {
	Name, OS, CPUName, Load                              string
	CPU                                                  float64
	MemoryUsed, MemoryTotal, DiskUsed, DiskTotal, Uptime uint64
	RX, TX                                               uint64
	CPUTotal, CPUIdle                                    float64
	At                                                   time.Time
	Error                                                string
}

type container struct {
	Names, State, Status, Image string
	CPU, Memory, NetIO, Health  string
}

type remote struct {
	Name          string
	Metrics       metrics
	Containers    []container
	Docker, Error string
	Latency       time.Duration
	At            time.Time
}

type project struct {
	ID, Name, Path, Host, Container, Sync, Port string
	Active                                      bool
}

func (p project) runtime(h remote) string {
	if h.Error != "" || h.Docker != "ready" {
		return "unknown"
	}
	for _, c := range h.Containers {
		if c.Names == p.Container {
			return c.State
		}
	}
	return "absent"
}

func (p project) health(h remote) string {
	for _, c := range h.Containers {
		if c.Names == p.Container && h.Error == "" {
			return c.Health
		}
	}
	return "—"
}

type syncEndpoint struct {
	Connected                        bool `json:"connected"`
	ScanProblems, TransitionProblems []syncProblem
	StagingProgress                  *struct{ ReceivedSize, TotalSize uint64 }
}

type syncProblem struct {
	Path, Error string
}

type syncState struct {
	Name, Status, LastError string
	Paused                  bool
	Conflicts               []syncConflict
	Alpha, Beta             syncEndpoint
}

type syncConflict struct {
	Root string
}

func (s syncState) label() string {
	switch {
	case len(s.Conflicts) > 0:
		return "conflict"
	case s.LastError != "" || len(s.Alpha.ScanProblems)+len(s.Alpha.TransitionProblems)+len(s.Beta.ScanProblems)+len(s.Beta.TransitionProblems) > 0:
		return "error"
	case s.Paused:
		return "paused"
	case !s.Alpha.Connected || !s.Beta.Connected:
		return "connecting"
	case s.Alpha.StagingProgress != nil || s.Beta.StagingProgress != nil:
		return "transferring"
	case s.Status == "watching":
		return "synced"
	default:
		return strings.ReplaceAll(s.Status, "-", " ")
	}
}

func parseSync(data []byte) (map[string]syncState, error) {
	var sessions []syncState
	if err := json.Unmarshal(data, &sessions); err != nil {
		return nil, fmt.Errorf("invalid Mutagen status: %w", err)
	}
	result := make(map[string]syncState)
	for _, s := range sessions {
		result[s.Name] = s
	}
	return result, nil
}

func clean(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, ansi.Strip(s))
}

func number(s string) uint64 { n, _ := strconv.ParseUint(s, 10, 64); return n }

func safeText(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) && r != '\n' && r != '\t' {
			return -1
		}
		return r
	}, ansi.Strip(s))
}

func parseRemote(name string, data []byte) (remote, error) {
	h := remote{Name: name, At: time.Now(), Metrics: metrics{CPU: -1}}
	stats := make(map[string]struct{ Name, CPUPerc, MemUsage, NetIO string })
	health := make(map[string]string)
	system := false
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.SplitN(line, "\t", 2)
		if len(f) != 2 {
			continue
		}
		switch f[0] {
		case "system":
			v := strings.Split(f[1], "\t")
			if len(v) != 11 {
				return h, fmt.Errorf("incomplete VM metrics")
			}
			for _, i := range []int{0, 1, 2, 3, 4, 5, 8, 9} {
				if _, err := strconv.ParseUint(v[i], 10, 64); err != nil {
					return h, fmt.Errorf("invalid VM counter")
				}
			}
			h.Metrics.CPUTotal, h.Metrics.CPUIdle = float64(number(v[0])), float64(number(v[1]))
			h.Metrics.MemoryTotal = number(v[2]) * 1024
			h.Metrics.MemoryUsed = h.Metrics.MemoryTotal - min(h.Metrics.MemoryTotal, number(v[3])*1024)
			h.Metrics.DiskTotal, h.Metrics.DiskUsed = number(v[4])*1024, number(v[5])*1024
			uptime, _ := strconv.ParseFloat(v[6], 64)
			h.Metrics.Uptime = uint64(max(0, uptime))
			h.Metrics.Load, h.Metrics.RX, h.Metrics.TX = clean(v[7]), number(v[8]), number(v[9])
			h.Metrics.CPUName, h.Metrics.At = clean(v[10]), h.At
			system = true
		case "identity":
			h.Metrics.Name = clean(f[1])
		case "docker":
			h.Docker = clean(f[1])
		case "container":
			var c container
			if err := json.Unmarshal([]byte(f[1]), &c); err != nil {
				return h, fmt.Errorf("invalid Docker status: %w", err)
			}
			c.Names, c.State, c.Status, c.Image = clean(c.Names), clean(c.State), clean(c.Status), clean(c.Image)
			h.Containers = append(h.Containers, c)
		case "stats":
			var s struct{ Name, CPUPerc, MemUsage, NetIO string }
			if err := json.Unmarshal([]byte(f[1]), &s); err != nil {
				return h, fmt.Errorf("invalid Docker metrics: %w", err)
			}
			stats[s.Name] = s
		case "health":
			v := strings.Split(f[1], "\t")
			if len(v) == 2 {
				health[v[0]] = clean(v[1])
			}
		}
	}
	if !system {
		return h, fmt.Errorf("VM did not return system metrics")
	}
	for i := range h.Containers {
		c := &h.Containers[i]
		s := stats[c.Names]
		c.CPU, c.Memory, c.NetIO, c.Health = clean(s.CPUPerc), clean(s.MemUsage), clean(s.NetIO), health[c.Names]
		if c.Health == "" {
			c.Health = "—"
		}
	}
	return h, nil
}

type backend struct {
	CLI, Home string
	Context   context.Context
}

func (b backend) command(ctx context.Context, args ...string) *exec.Cmd {
	return b.process(ctx, b.CLI, args...)
}

func (b backend) process(ctx context.Context, program string, args ...string) *exec.Cmd {
	c := exec.CommandContext(ctx, program, args...)
	c.Env = append(os.Environ(), "MOLT_HOME="+b.Home, "MOLT_UI_BATCH=1")
	// Kill the collector/action process group so a timed-out SSH cannot linger.
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	c.Cancel = func() error { return syscall.Kill(-c.Process.Pid, syscall.SIGTERM) }
	c.WaitDelay = 2 * time.Second
	return c
}

func (b backend) output(timeout time.Duration, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(b.Context, timeout)
	defer cancel()
	c := b.command(ctx, args...)
	var errors strings.Builder
	c.Stderr = &errors
	data, err := c.Output()
	if err != nil {
		return nil, fmt.Errorf("%s: %s", err, clean(errors.String()))
	}
	return data, nil
}

type inventory struct {
	Projects []project
	Hosts    []string
	Config   map[string]string
	Error    string
}

var projectID = regexp.MustCompile(`^[a-f0-9]{12}$`)

func (b backend) inventory() inventory {
	i := inventory{Config: make(map[string]string)}
	data, err := b.output(5*time.Second, "config", "show")
	if err != nil {
		i.Error = err.Error()
		return i
	}
	for _, line := range strings.Split(string(data), "\n") {
		if k, v, ok := strings.Cut(line, "="); ok {
			i.Config[k] = v
		}
	}
	hosts := make(map[string]bool)
	addHost := func(h string) {
		if h != "" {
			hosts[h] = true
		}
	}
	addHost(i.Config["MOLT_HOST"])
	entries, err := os.ReadDir(filepath.Join(b.Home, "projects"))
	if err != nil && !os.IsNotExist(err) {
		i.Error = err.Error()
		return i
	}
	for _, e := range entries {
		if !e.IsDir() || !projectID.MatchString(e.Name()) {
			continue
		}
		read := func(key string) string {
			data, _ := os.ReadFile(filepath.Join(b.Home, "projects", e.Name(), key))
			return strings.TrimRight(string(data), "\r\n")
		}
		p := project{ID: e.Name(), Name: read("name"), Path: read("path"), Host: read("host"), Container: read("container"), Sync: read("sync"), Port: read("opencode_port"), Active: read("active") == "1"}
		if p.Path == "" {
			continue
		}
		if p.Host == "" {
			p.Host = i.Config["MOLT_HOST"]
		}
		i.Projects = append(i.Projects, p)
		addHost(p.Host)
	}
	for _, pattern := range []string{"state/ssh/profiles/*/hostname", "state/remotes/*/host"} {
		files, _ := filepath.Glob(filepath.Join(b.Home, pattern))
		for _, file := range files {
			if strings.HasSuffix(file, "/hostname") {
				addHost(filepath.Base(filepath.Dir(file)))
			} else {
				data, _ := os.ReadFile(file)
				addHost(strings.TrimSpace(string(data)))
			}
		}
	}
	for h := range hosts {
		i.Hosts = append(i.Hosts, h)
	}
	sort.Strings(i.Hosts)
	sort.Slice(i.Projects, func(a, b int) bool { return i.Projects[a].Name < i.Projects[b].Name })
	return i
}

func (b backend) local() metrics {
	ctx, cancel := context.WithTimeout(b.Context, 2*time.Second)
	defer cancel()
	m := metrics{CPU: -1, At: time.Now()}
	var failures []string
	if h, err := host.InfoWithContext(ctx); err == nil {
		m.Name, m.OS, m.Uptime = h.Hostname, h.Platform+" "+h.PlatformVersion, h.Uptime
	}
	if c, err := cpu.InfoWithContext(ctx); err == nil && len(c) > 0 {
		m.CPUName = c[0].ModelName
	}
	if c, err := cpu.TimesWithContext(ctx, false); err == nil && len(c) > 0 {
		x := c[0]
		m.CPUTotal = x.User + x.System + x.Idle + x.Nice + x.Iowait + x.Irq + x.Softirq + x.Steal
		m.CPUIdle = x.Idle + x.Iowait
	} else {
		failures = append(failures, "CPU unavailable")
	}
	if v, err := mem.VirtualMemoryWithContext(ctx); err == nil {
		m.MemoryUsed, m.MemoryTotal = v.Used, v.Total
	} else {
		failures = append(failures, "memory unavailable")
	}
	if d, err := disk.UsageWithContext(ctx, b.Home); err == nil {
		m.DiskUsed, m.DiskTotal = d.Used, d.Total
	} else {
		failures = append(failures, "disk unavailable")
	}
	if l, err := load.AvgWithContext(ctx); err == nil {
		m.Load = fmt.Sprintf("%.2f %.2f %.2f", l.Load1, l.Load5, l.Load15)
	}
	if n, err := net.IOCountersWithContext(ctx, true); err == nil {
		for _, v := range n {
			if v.Name != "lo" && v.Name != "lo0" {
				m.RX += v.BytesRecv
				m.TX += v.BytesSent
			}
		}
	}
	m.Error = strings.Join(failures, " · ")
	return m
}

func withCPU(next, previous metrics) metrics {
	if next.CPUTotal > previous.CPUTotal && previous.CPUTotal > 0 {
		next.CPU = max(0, min(100, 100*(1-(next.CPUIdle-previous.CPUIdle)/(next.CPUTotal-previous.CPUTotal))))
	}
	return next
}

func rates(next, prev metrics) (float64, float64) {
	dt := next.At.Sub(prev.At).Seconds()
	if prev.At.IsZero() || dt <= 0 {
		return 0, 0
	}
	return float64(next.RX-min(next.RX, prev.RX)) / dt, float64(next.TX-min(next.TX, prev.TX)) / dt
}

// Logs stay bounded in memory even when a build produces megabytes of output.
func readTail(path string) []string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	if st, err := f.Stat(); err == nil && st.Size() > 256*1024 {
		f.Seek(-256*1024, 2)
	}
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 4096), 256*1024)
	var lines []string
	for scanner.Scan() {
		lines = append(lines, clean(scanner.Text()))
		if len(lines) > 1000 {
			lines = lines[1:]
		}
	}
	return lines
}

func saveOutput(source, home string) {
	in, err := os.Open(source)
	if err != nil {
		return
	}
	defer in.Close()
	dir := filepath.Join(home, "state", "ui")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return
	}
	// Match the CLI's rule that managed files cannot follow symlinks.
	fd, err := syscall.Open(filepath.Join(dir, "last.log"), syscall.O_WRONLY|syscall.O_CREAT|syscall.O_TRUNC|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return
	}
	out := os.NewFile(uintptr(fd), "last.log")
	defer out.Close()
	io.Copy(out, in)
}
