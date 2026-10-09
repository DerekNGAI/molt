package main

import (
	"crypto/subtle"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

var sessionIDPattern = regexp.MustCompile(`^ses_[a-zA-Z0-9]+$`)

type sessionProxy struct {
	proxy              *httputil.ReverseProxy
	lockDir            string
	username, password string
	mu                 sync.Mutex
	sessions           map[string]*os.File
	closed             bool
}

func (p *sessionProxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	user, password, ok := r.BasicAuth()
	if !ok || user != p.username || subtle.ConstantTimeCompare([]byte(password), []byte(p.password)) != 1 {
		w.Header().Set("WWW-Authenticate", `Basic realm="OpenCode"`)
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if r.Method != "GET" && r.Method != "HEAD" && r.Method != "OPTIONS" && len(parts) >= 2 && parts[0] == "session" && !(len(parts) == 3 && parts[2] == "fork") {
		id := parts[1]
		if !sessionIDPattern.MatchString(id) {
			http.Error(w, "Invalid session ID", http.StatusBadRequest)
			return
		}
		if err := p.claim(id); err != nil {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
	}
	p.proxy.ServeHTTP(w, r)
}

func (p *sessionProxy) claim(id string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return errors.New("terminal is closing")
	}
	if _, ok := p.sessions[id]; ok {
		return nil
	}
	fd, err := syscall.Open(filepath.Join(p.lockDir, id), syscall.O_CREAT|syscall.O_RDWR|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0600)
	if err != nil {
		return fmt.Errorf("cannot record session ownership: %w", err)
	}
	lock := os.NewFile(uintptr(fd), id)
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return errors.New("session is active in another terminal; open a new session")
	}
	p.sessions[id] = lock
	return nil
}

func (p *sessionProxy) close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return nil
	}
	p.closed = true
	var failures []error
	for id, lock := range p.sessions {
		if err := lock.Close(); err != nil {
			failures = append(failures, fmt.Errorf("could not release session %s: %w", id, err))
		}
	}
	return errors.Join(failures...)
}

func runAttachedClient(args []string) int {
	flags := flag.NewFlagSet("attach-client", flag.ContinueOnError)
	upstream := flags.String("upstream", "", "shared OpenCode server URL")
	directory := flags.String("directory", "", "server working directory")
	lockDir := flags.String("sessions", "", "project session ownership directory")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	command := flags.Args()
	endpoint, err := url.Parse(*upstream)
	if err != nil || endpoint.Scheme != "http" || endpoint.Hostname() != "127.0.0.1" || endpoint.Port() == "" || *directory == "" || *lockDir == "" || len(command) < 3 || command[1] != "attach" || command[2] != *upstream {
		fmt.Fprintln(os.Stderr, "molt: invalid attached client parameters")
		return 2
	}
	if err := os.MkdirAll(*lockDir, 0700); err != nil {
		fmt.Fprintln(os.Stderr, "molt:", err)
		return 1
	}
	info, err := os.Lstat(*lockDir)
	if err != nil || !info.IsDir() {
		fmt.Fprintln(os.Stderr, "molt: unsafe session ownership directory")
		return 1
	}
	username := os.Getenv("OPENCODE_SERVER_USERNAME")
	if username == "" {
		username = "opencode"
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	defer transport.CloseIdleConnections()
	p := &sessionProxy{lockDir: *lockDir, username: username,
		password: os.Getenv("OPENCODE_SERVER_PASSWORD"), sessions: map[string]*os.File{}}
	p.proxy = httputil.NewSingleHostReverseProxy(endpoint)
	p.proxy.Transport = transport
	p.proxy.FlushInterval = -1
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintln(os.Stderr, "molt:", err)
		return 1
	}
	server := &http.Server{Handler: p, ReadHeaderTimeout: 5 * time.Second}
	defer server.Close()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(signals)
	go server.Serve(listener)
	command[2] = "http://" + listener.Addr().String()
	client := exec.Command(command[0], command[1:]...)
	client.Stdin, client.Stdout, client.Stderr = os.Stdin, os.Stdout, os.Stderr
	rc := 0
	if err := client.Start(); err != nil {
		fmt.Fprintln(os.Stderr, "molt:", err)
		rc = 1
	} else {
		done := make(chan error, 1)
		go func() { done <- client.Wait() }()
		select {
		case err := <-done:
			if exit, ok := err.(*exec.ExitError); ok {
				rc = exit.ExitCode()
			}
		case sig := <-signals:
			client.Process.Signal(syscall.SIGTERM)
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				client.Process.Kill()
				<-done
			}
			rc = 128 + int(sig.(syscall.Signal))
		}
	}
	server.Close()
	if err := p.close(); err != nil {
		fmt.Fprintln(os.Stderr, "molt:", err)
		if rc == 0 {
			rc = 1
		}
	}
	return rc
}
