package main

import (
	"archive/tar"
	"archive/zip"
	"bufio"
	bytebuf "bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const bundledOpenCodeVersion = "1.18.34"

var opencodeAssets = []string{"opencode-darwin-arm64.zip", "opencode-darwin-x64-baseline.zip", "opencode-linux-arm64.tar.gz", "opencode-linux-x64-baseline.tar.gz"}
var opencodeVersionPattern = regexp.MustCompile(`^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$`)
var opencodeDigestPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)

type opencodeRelease struct {
	Version string            `json:"version"`
	Assets  map[string]string `json:"assets"`
}

type opencodeTools struct {
	home, lockFile string
	client         *http.Client
}

func parseOpenCodeRelease(data []byte) (opencodeRelease, error) {
	var response struct {
		TagName           string `json:"tag_name"`
		Draft, Prerelease bool
		Assets            []struct{ Name, Digest string }
	}
	if err := json.Unmarshal(data, &response); err != nil {
		return opencodeRelease{}, err
	}
	release := opencodeRelease{Version: strings.TrimPrefix(response.TagName, "v"), Assets: map[string]string{}}
	if !opencodeVersionPattern.MatchString(release.Version) || response.Draft || response.Prerelease {
		return release, errors.New("OpenCode release must be a stable version")
	}
	for _, asset := range response.Assets {
		for _, name := range opencodeAssets {
			if name != asset.Name {
				continue
			}
			digest := strings.TrimPrefix(asset.Digest, "sha256:")
			if !strings.HasPrefix(asset.Digest, "sha256:") || !opencodeDigestPattern.MatchString(digest) || release.Assets[name] != "" {
				return release, fmt.Errorf("missing, invalid, or duplicate checksum for %s", name)
			}
			release.Assets[name] = digest
		}
	}
	if len(release.Assets) != len(opencodeAssets) {
		return release, errors.New("OpenCode release is missing supported client/server assets")
	}
	return release, nil
}

func newerOpenCodeVersion(a, b string) bool {
	left, right := strings.Split(a, "."), strings.Split(b, ".")
	for i := range left {
		x, _ := strconv.Atoi(left[i])
		y, _ := strconv.Atoi(right[i])
		if x != y {
			return x > y
		}
	}
	return false
}

func privateOpenCodeDir(home string, parts ...string) (string, error) {
	dir := home
	for _, part := range append([]string{"state", "opencode"}, parts...) {
		dir = filepath.Join(dir, part)
		if err := os.Mkdir(dir, 0700); err != nil && !os.IsExist(err) {
			return "", err
		}
		info, err := os.Lstat(dir)
		if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return "", fmt.Errorf("unsafe OpenCode state directory: %s", dir)
		}
	}
	return dir, nil
}

func atomicOpenCodeFile(path string, data []byte, mode os.FileMode) error {
	if info, err := os.Lstat(path); err == nil && !info.Mode().IsRegular() {
		return fmt.Errorf("unsafe OpenCode state file: %s", path)
	} else if err != nil && !os.IsNotExist(err) {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".update-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if _, err = file.Write(data); err == nil {
		err = file.Chmod(mode)
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(file.Name(), path)
}

func readOpenCodeFile(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("unsafe OpenCode state file: %s", path)
	}
	return os.ReadFile(path)
}

func (t *opencodeTools) fetchRelease(ctx context.Context, endpoint string) (opencodeRelease, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", "https://api.github.com/repos/anomalyco/opencode/releases/"+endpoint, nil)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "MOLT")
	response, err := t.client.Do(req)
	if err != nil {
		return opencodeRelease{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return opencodeRelease{}, fmt.Errorf("OpenCode release lookup returned HTTP %d", response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 4<<20))
	if err != nil {
		return opencodeRelease{}, err
	}
	return parseOpenCodeRelease(data)
}

func (t *opencodeTools) saveRelease(release opencodeRelease) error {
	dir, err := privateOpenCodeDir(t.home, "releases")
	if err != nil {
		return err
	}
	data, _ := json.Marshal(release)
	return atomicOpenCodeFile(filepath.Join(dir, release.Version+".json"), data, 0600)
}

func (t *opencodeTools) release(ctx context.Context, version string) (opencodeRelease, error) {
	if !opencodeVersionPattern.MatchString(version) {
		return opencodeRelease{}, errors.New("invalid OpenCode version")
	}
	dir, err := privateOpenCodeDir(t.home, "releases")
	if err != nil {
		return opencodeRelease{}, err
	}
	if data, err := readOpenCodeFile(filepath.Join(dir, version+".json")); err == nil {
		var release opencodeRelease
		if json.Unmarshal(data, &release) != nil || release.Version != version || len(release.Assets) != len(opencodeAssets) {
			return release, errors.New("invalid cached OpenCode release")
		}
		for _, asset := range opencodeAssets {
			if !opencodeDigestPattern.MatchString(release.Assets[asset]) {
				return release, errors.New("invalid cached OpenCode checksum")
			}
		}
		return release, nil
	} else if !os.IsNotExist(err) {
		return opencodeRelease{}, err
	}
	if version == bundledOpenCodeVersion {
		file, err := os.Open(t.lockFile)
		if err != nil {
			return opencodeRelease{}, err
		}
		defer file.Close()
		release := opencodeRelease{Version: version, Assets: map[string]string{}}
		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			fields := strings.Fields(scanner.Text())
			if len(fields) != 2 {
				continue
			}
			for _, asset := range opencodeAssets {
				if fields[1] == asset && opencodeDigestPattern.MatchString(fields[0]) && release.Assets[asset] == "" {
					release.Assets[asset] = fields[0]
				}
			}
		}
		if scanner.Err() != nil || len(release.Assets) != len(opencodeAssets) {
			return release, errors.New("bundled OpenCode checksums are incomplete")
		}
		return release, nil
	}
	release, err := t.fetchRelease(ctx, "tags/v"+version)
	if err != nil {
		return release, err
	}
	if release.Version != version {
		return release, errors.New("OpenCode release lookup returned a different version")
	}
	return release, t.saveRelease(release)
}

func (t *opencodeTools) latest(ctx context.Context, force bool) (opencodeRelease, error) {
	dir, err := privateOpenCodeDir(t.home)
	if err != nil {
		return opencodeRelease{}, err
	}
	var check struct {
		CheckedAt int64  `json:"checked_at"`
		Version   string `json:"version"`
	}
	path := filepath.Join(dir, "latest.json")
	if data, err := readOpenCodeFile(path); err == nil {
		if json.Unmarshal(data, &check) != nil || !opencodeVersionPattern.MatchString(check.Version) {
			return opencodeRelease{}, errors.New("invalid OpenCode release check state")
		}
	} else if !os.IsNotExist(err) {
		return opencodeRelease{}, err
	}
	if check.Version == "" {
		check.Version = bundledOpenCodeVersion
	}
	previous, err := t.release(ctx, check.Version)
	if err != nil {
		return previous, err
	}
	if !force && time.Now().Unix()-check.CheckedAt < int64((24*time.Hour)/time.Second) {
		return previous, nil
	}
	release, fetchErr := t.fetchRelease(ctx, "latest")
	if fetchErr == nil && newerOpenCodeVersion(release.Version, previous.Version) {
		if err := t.saveRelease(release); err != nil {
			return previous, err
		}
		previous, check.Version = release, release.Version
	}
	check.CheckedAt = time.Now().Unix()
	data, _ := json.Marshal(check)
	if err := atomicOpenCodeFile(path, data, 0600); err != nil {
		return previous, err
	}
	return previous, fetchErr
}

func openCodeBinaryVersion(ctx context.Context, binary string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	work, err := os.MkdirTemp(filepath.Dir(binary), ".version-*")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(work)
	command := exec.CommandContext(ctx, binary, "--version")
	command.Dir = work
	command.Env = append(os.Environ(), "HOME="+work, "XDG_CONFIG_HOME="+work, "XDG_DATA_HOME="+work, "XDG_CACHE_HOME="+work,
		"XDG_STATE_HOME="+work, "OPENCODE_CONFIG_DIR="+work, "OPENCODE_DISABLE_PROJECT_CONFIG=1", "OPENCODE_DISABLE_AUTOUPDATE=1")
	data, err := command.Output()
	return strings.TrimSpace(string(data)), err
}

func (t *opencodeTools) ensureClient(ctx context.Context, version, base string) (string, error) {
	if !opencodeVersionPattern.MatchString(version) {
		return "", errors.New("invalid OpenCode client version")
	}
	dir, err := privateOpenCodeDir(t.home, "clients", version)
	if err != nil {
		return "", err
	}
	binary := filepath.Join(dir, "opencode")
	if data, err := readOpenCodeFile(binary); err == nil {
		digest := sha256.Sum256(data)
		expected, err := readOpenCodeFile(binary + ".sha256")
		if err == nil && string(expected) == hex.EncodeToString(digest[:]) {
			return binary, nil
		}
	} else if !os.IsNotExist(err) {
		return "", err
	}
	var data []byte
	if base != "" {
		if found, err := openCodeBinaryVersion(ctx, base); err == nil && found == version {
			data, err = os.ReadFile(base)
			if err != nil {
				return "", err
			}
		}
	}
	if len(data) == 0 {
		if runtime.GOOS != "darwin" && runtime.GOOS != "linux" || runtime.GOARCH != "arm64" && runtime.GOARCH != "amd64" {
			return "", errors.New("unsupported OpenCode client platform")
		}
		release, err := t.release(ctx, version)
		if err != nil {
			return "", err
		}
		asset := "opencode-" + runtime.GOOS + "-arm64.tar.gz"
		if runtime.GOOS == "darwin" {
			asset = "opencode-darwin-arm64.zip"
		}
		if runtime.GOARCH == "amd64" {
			asset = "opencode-" + runtime.GOOS + "-x64-baseline.tar.gz"
			if runtime.GOOS == "darwin" {
				asset = "opencode-darwin-x64-baseline.zip"
			}
		}
		if release.Assets[asset] == "" {
			return "", errors.New("unsupported OpenCode client platform")
		}
		request, _ := http.NewRequestWithContext(ctx, "GET", "https://github.com/anomalyco/opencode/releases/download/v"+version+"/"+asset, nil)
		response, err := t.client.Do(request)
		if err != nil {
			return "", err
		}
		defer response.Body.Close()
		if response.StatusCode != 200 {
			return "", fmt.Errorf("OpenCode client download returned HTTP %d", response.StatusCode)
		}
		archive, err := io.ReadAll(io.LimitReader(response.Body, 512<<20))
		if err != nil {
			return "", err
		}
		digest := sha256.Sum256(archive)
		if hex.EncodeToString(digest[:]) != release.Assets[asset] {
			return "", errors.New("OpenCode client checksum mismatch")
		}
		data, err = extractOpenCodeBinary(archive, strings.HasSuffix(asset, ".zip"))
		if err != nil {
			return "", err
		}
	}
	staged, err := os.CreateTemp(dir, ".client-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(staged.Name())
	_, err = staged.Write(data)
	if err == nil {
		err = staged.Chmod(0700)
	}
	if closeErr := staged.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return "", err
	}
	if found, err := openCodeBinaryVersion(ctx, staged.Name()); err != nil || found != version {
		return "", fmt.Errorf("downloaded OpenCode client did not report version %s", version)
	}
	if err := os.Rename(staged.Name(), binary); err != nil {
		return "", err
	}
	digest := sha256.Sum256(data)
	return binary, atomicOpenCodeFile(binary+".sha256", []byte(hex.EncodeToString(digest[:])), 0600)
}

func extractOpenCodeBinary(data []byte, zipped bool) ([]byte, error) {
	if zipped {
		reader, err := zip.NewReader(bytebuf.NewReader(data), int64(len(data)))
		if err != nil {
			return nil, err
		}
		for _, file := range reader.File {
			if filepath.Base(file.Name) != "opencode" || !file.Mode().IsRegular() {
				continue
			}
			input, err := file.Open()
			if err != nil {
				return nil, err
			}
			defer input.Close()
			return io.ReadAll(io.LimitReader(input, 512<<20))
		}
	} else {
		compressed, err := gzip.NewReader(bytebuf.NewReader(data))
		if err != nil {
			return nil, err
		}
		defer compressed.Close()
		reader := tar.NewReader(compressed)
		for {
			file, err := reader.Next()
			if err == io.EOF {
				break
			}
			if err != nil {
				return nil, err
			}
			if filepath.Base(file.Name) == "opencode" && file.Typeflag == tar.TypeReg {
				return io.ReadAll(io.LimitReader(reader, 512<<20))
			}
		}
	}
	return nil, errors.New("OpenCode archive has no executable")
}

func probeOpenCodeServer(ctx context.Context, client *http.Client, endpoint, username, password string) (string, bool, error) {
	get := func(path string, result any) (http.Header, error) {
		request, err := http.NewRequestWithContext(ctx, "GET", endpoint+path, nil)
		if err != nil {
			return nil, err
		}
		request.SetBasicAuth(username, password)
		response, err := client.Do(request)
		if err != nil {
			return nil, err
		}
		defer response.Body.Close()
		if response.StatusCode != 200 {
			return nil, fmt.Errorf("OpenCode %s returned HTTP %d", strings.Split(path, "?")[0], response.StatusCode)
		}
		return response.Header, json.NewDecoder(io.LimitReader(response.Body, 8<<20)).Decode(result)
	}
	var health struct {
		Healthy bool
		Version string
	}
	if _, err := get("/global/health", &health); err != nil {
		return "", false, err
	}
	if !health.Healthy || !opencodeVersionPattern.MatchString(health.Version) {
		return "", false, errors.New("OpenCode server did not report a healthy stable version")
	}
	directories := map[string]bool{"/workspace": true}
	cursor := ""
	limit, previousCursor := 200, int64(-1)
	for {
		var sessions []struct{ Directory string }
		header, err := get(fmt.Sprintf("/experimental/session?limit=%d&archived=true%s", limit, cursor), &sessions)
		if err != nil || sessions == nil {
			return health.Version, false, errors.Join(errors.New("could not verify all server sessions"), err)
		}
		for _, session := range sessions {
			if !strings.HasPrefix(session.Directory, "/") || strings.ContainsAny(session.Directory, "\x00\r\n") {
				return health.Version, false, errors.New("server session has an invalid directory")
			}
			directories[session.Directory] = true
		}
		next := header.Get("x-next-cursor")
		if next == "" {
			break
		}
		number, err := strconv.ParseInt(next, 10, 64)
		if err != nil || number < 0 || number == 1<<63-1 || previousCursor >= 0 && number > previousCursor {
			return health.Version, false, errors.New("invalid server session pagination")
		}
		if number == previousCursor {
			// ponytail: huge timestamp groups defer updates; use unique cursors when OpenCode provides them.
			if limit >= 20000 {
				return health.Version, false, errors.New("could not enumerate sessions sharing a timestamp")
			}
			limit *= 2
		} else {
			// OpenCode's cursor excludes equal timestamps, so overlap the boundary.
			cursor = fmt.Sprintf("&cursor=%d", number+1)
			previousCursor, limit = number, 200
		}
	}
	for directory := range directories {
		var statuses map[string]struct{ Type string }
		if _, err := get("/session/status?directory="+url.QueryEscape(directory), &statuses); err != nil || statuses == nil {
			return health.Version, false, errors.Join(errors.New("could not verify server activity"), err)
		}
		for _, status := range statuses {
			if status.Type != "idle" {
				return health.Version, false, nil
			}
		}
	}
	return health.Version, true, nil
}

func runOpenCodeTools(args []string) int {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if len(args) < 1 {
		return 2
	}
	if args[0] == "server" && len(args) == 2 {
		endpoint, err := url.Parse(args[1])
		if err != nil || endpoint.Scheme != "http" || endpoint.Hostname() != "127.0.0.1" || endpoint.Port() == "" {
			fmt.Fprintln(os.Stderr, "molt: invalid OpenCode probe endpoint")
			return 1
		}
		transport := http.DefaultTransport.(*http.Transport).Clone()
		transport.Proxy = nil
		defer transport.CloseIdleConnections()
		ctx, stop := context.WithTimeout(ctx, 15*time.Second)
		defer stop()
		username := os.Getenv("OPENCODE_SERVER_USERNAME")
		if username == "" {
			username = "opencode"
		}
		version, idle, err := probeOpenCodeServer(ctx, &http.Client{Transport: transport, Timeout: 3 * time.Second}, args[1], username, os.Getenv("OPENCODE_SERVER_PASSWORD"))
		if version == "" {
			fmt.Fprintln(os.Stderr, "molt:", err)
			return 1
		}
		state := "busy"
		if err != nil {
			state = "unknown"
			fmt.Fprintln(os.Stderr, "molt:", err)
		} else if idle {
			state = "idle"
		}
		fmt.Printf("%s\n%s\n", version, state)
		return 0
	}
	if len(args) < 3 {
		return 2
	}
	tools := &opencodeTools{home: args[1], lockFile: args[2], client: &http.Client{Timeout: 2 * time.Minute}}
	dir, err := privateOpenCodeDir(tools.home)
	if err != nil {
		fmt.Fprintln(os.Stderr, "molt:", err)
		return 1
	}
	fd, err := syscall.Open(filepath.Join(dir, "tools.lock"), syscall.O_CREAT|syscall.O_RDWR|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0600)
	if err != nil {
		fmt.Fprintln(os.Stderr, "molt:", err)
		return 1
	}
	lock := os.NewFile(uintptr(fd), "OpenCode tools lock")
	defer lock.Close()
	for {
		if err = syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
			break
		}
		if err != syscall.EWOULDBLOCK {
			fmt.Fprintln(os.Stderr, "molt:", err)
			return 1
		}
		select {
		case <-ctx.Done():
			return 1
		case <-time.After(100 * time.Millisecond):
		}
	}
	switch args[0] {
	case "latest":
		force := len(args) == 4 && args[3] == "--refresh"
		release, lookupErr := tools.latest(ctx, force)
		if lookupErr != nil {
			fmt.Fprintln(os.Stderr, "molt: OpenCode release check:", lookupErr)
			if force || release.Version == "" {
				return 1
			}
		}
		fmt.Println(release.Version)
	case "client":
		if len(args) != 5 {
			return 2
		}
		binary, clientErr := tools.ensureClient(ctx, args[3], args[4])
		err = clientErr
		if err == nil {
			fmt.Println(binary)
		}
	case "lock":
		if len(args) != 4 {
			return 2
		}
		release, releaseErr := tools.release(ctx, args[3])
		err = releaseErr
		if err == nil {
			data, readErr := os.ReadFile(tools.lockFile)
			err = readErr
			if err == nil {
				for _, line := range strings.Split(string(data), "\n") {
					if !strings.Contains(line, "opencode-") && line != "" {
						fmt.Println(line)
					}
				}
				for _, asset := range opencodeAssets {
					fmt.Printf("%s %s\n", release.Assets[asset], asset)
				}
			}
		}
	default:
		return 2
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "molt:", err)
		return 1
	}
	return 0
}
