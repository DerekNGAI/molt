package main

import (
	"archive/tar"
	"archive/zip"
	"bufio"
	bytebuf "bytes"
	"compress/gzip"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"syscall"
	"time"
)

type DevelopmentToolLock struct {
	Version   int                   `json:"version"`
	Artifacts []DevelopmentArtifact `json:"artifacts"`
}

type DevelopmentArtifact struct {
	Role    string `json:"role"`
	OS      string `json:"os"`
	Arch    string `json:"arch"`
	Version string `json:"version"`
	URL     string `json:"url"`
	SHA256  string `json:"sha256"`
	Image   string `json:"image"`
	Digest  string `json:"digest"`
}

type DevelopmentViewer struct {
	Scrcpy    string `json:"scrcpy"`
	ADB       string `json:"adb"`
	Version   string `json:"version"`
	OwnedRoot string `json:"owned_root"`
}

type developmentArchiveFile struct {
	Data []byte
	Mode os.FileMode
}

func decodeDevelopmentToolLock(data []byte) (DevelopmentToolLock, error) {
	var lock DevelopmentToolLock
	if err := decodeDevelopmentJSON(data, &lock); err != nil {
		return lock, err
	}
	if lock.Version != 1 || len(lock.Artifacts) == 0 || len(lock.Artifacts) > 32 {
		return lock, errors.New("invalid development artifact lock version or count")
	}
	seen := map[string]bool{}
	for _, artifact := range lock.Artifacts {
		key := artifact.Role + "/" + artifact.OS + "/" + artifact.Arch
		if !developmentEnum(artifact.Role, "builder", "android", "viewer", "adb") || !developmentEnum(artifact.OS, "linux", "darwin") || !developmentEnum(artifact.Arch, "arm64", "amd64") || !developmentArtifactVersionPattern.MatchString(artifact.Version) || seen[key] {
			return lock, fmt.Errorf("invalid or duplicate development artifact %q", key)
		}
		if artifact.URL != "" {
			endpoint, err := url.Parse(artifact.URL)
			if err != nil || endpoint.Scheme != "https" || endpoint.Hostname() == "" || endpoint.User != nil || endpoint.Fragment != "" || !developmentText(artifact.URL, 4096, false) || !opencodeDigestPattern.MatchString(artifact.SHA256) || artifact.Image != "" || artifact.Digest != "" {
				return lock, fmt.Errorf("invalid checked archive artifact %q", key)
			}
		} else if artifact.SHA256 != "" || !developmentRegistryImagePattern.MatchString(artifact.Image) || !strings.HasPrefix(artifact.Digest, "sha256:") || !opencodeDigestPattern.MatchString(strings.TrimPrefix(artifact.Digest, "sha256:")) {
			return lock, fmt.Errorf("invalid immutable OCI artifact %q", key)
		}
		seen[key] = true
	}
	return lock, nil
}

func decodeDevelopmentArchive(data []byte, zipped bool) (map[string]developmentArchiveFile, error) {
	files, seen := map[string]developmentArchiveFile{}, map[string]bool{}
	total := int64(0)
	add := func(name string, mode os.FileMode, size int64, input io.Reader) error {
		name = strings.TrimPrefix(strings.TrimSuffix(name, "/"), "./")
		if name == "." && mode.IsDir() {
			return nil
		}
		if !filepath.IsLocal(name) || filepath.ToSlash(filepath.Clean(name)) != name || strings.Contains(name, "\\") || !developmentText(name, 4096, false) || seen[name] || len(seen) >= 4096 || !mode.IsDir() && !mode.IsRegular() {
			return fmt.Errorf("unsafe or duplicate development archive path %q", name)
		}
		for parent := filepath.ToSlash(filepath.Dir(name)); parent != "."; parent = filepath.ToSlash(filepath.Dir(parent)) {
			if _, exists := files[parent]; exists {
				return errors.New("conflicting development archive paths")
			}
		}
		if !mode.IsDir() {
			for existing := range seen {
				if strings.HasPrefix(existing, name+"/") {
					return errors.New("conflicting development archive paths")
				}
			}
		}
		seen[name] = true
		if mode.IsDir() {
			return nil
		}
		if size < 0 || size > 64<<20 || size > (256<<20)-total {
			return errors.New("development tool archive is too large")
		}
		contents, err := io.ReadAll(io.LimitReader(input, size+1))
		if err != nil || int64(len(contents)) != size {
			return errors.Join(errors.New("invalid development archive file size"), err)
		}
		total += size
		files[name] = developmentArchiveFile{Data: contents, Mode: 0600 | mode.Perm()&0100}
		return nil
	}
	if zipped {
		archive, err := zip.NewReader(bytebuf.NewReader(data), int64(len(data)))
		if err != nil {
			return nil, err
		}
		for _, file := range archive.File {
			if file.UncompressedSize64 > 64<<20 {
				return nil, errors.New("development ZIP entry is too large")
			}
			input, err := file.Open()
			if err != nil {
				return nil, err
			}
			err = add(file.Name, file.Mode(), int64(file.UncompressedSize64), input)
			input.Close()
			if err != nil {
				return nil, err
			}
		}
	} else {
		compressed, err := gzip.NewReader(bytebuf.NewReader(data))
		if err != nil {
			return nil, err
		}
		defer compressed.Close()
		archive := tar.NewReader(compressed)
		for {
			file, err := archive.Next()
			if err == io.EOF {
				if _, err := io.CopyN(io.Discard, compressed, 1<<20); err != io.EOF {
					return nil, errors.Join(errors.New("invalid development gzip trailer"), err)
				}
				break
			}
			if err != nil {
				return nil, err
			}
			if file.Typeflag != tar.TypeReg && file.Typeflag != tar.TypeRegA && file.Typeflag != tar.TypeDir {
				return nil, errors.New("development archives cannot contain links or special files")
			}
			if err := add(file.Name, file.FileInfo().Mode(), file.Size, archive); err != nil {
				return nil, err
			}
		}
	}
	if len(files) == 0 {
		return nil, errors.New("development tool archive is empty")
	}
	return files, nil
}

func ensureDevelopmentViewer(ctx context.Context, home string, lock DevelopmentToolLock, arch string, client *http.Client) (DevelopmentViewer, error) {
	var viewer DevelopmentViewer
	if err := ctx.Err(); err != nil {
		return viewer, err
	}
	if _, err := decodeDevelopmentToolLock(developmentLockJSON(lock)); err != nil {
		return viewer, err
	}
	viewArtifact, err := developmentArtifact(lock, "viewer", "darwin", arch)
	if err != nil {
		return viewer, err
	}
	adbArtifact, err := developmentArtifact(lock, "adb", "darwin", arch)
	if err != nil {
		return viewer, err
	}
	if viewArtifact.URL == "" || adbArtifact.URL == "" {
		return viewer, errors.New("viewer and ADB need checked archive artifacts")
	}
	tools, err := developmentToolsDirectory(home)
	if err != nil {
		return viewer, err
	}
	base := filepath.Join(tools, "development")
	if err := developmentOwnedDirectory(base, true); err != nil {
		return viewer, err
	}
	root, err := os.OpenRoot(base)
	if err != nil {
		return viewer, err
	}
	defer root.Close()
	file, err := root.OpenFile(".lock", os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return viewer, err
	}
	defer file.Close()
	if info, err := file.Stat(); err != nil || !info.Mode().IsRegular() || !developmentOwnedInfo(info) {
		return viewer, errors.New("unsafe development acquisition lock")
	}
	for {
		if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
			break
		} else if err != syscall.EWOULDBLOCK {
			return viewer, err
		}
		select {
		case <-ctx.Done():
			return viewer, ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
	identity := sha256.Sum256(developmentLockJSON(DevelopmentToolLock{Version: 1, Artifacts: []DevelopmentArtifact{viewArtifact, adbArtifact}}))
	bundle := "darwin-" + viewArtifact.Arch + "-" + viewArtifact.Version + "-" + hex.EncodeToString(identity[:])
	artifacts := []DevelopmentArtifact{viewArtifact}
	if adbArtifact.URL != viewArtifact.URL || adbArtifact.SHA256 != viewArtifact.SHA256 {
		artifacts = append(artifacts, adbArtifact)
	}
	info, err := root.Lstat(bundle)
	cached := err == nil
	if cached && (!info.IsDir() || !developmentOwnedInfo(info)) || err != nil && !os.IsNotExist(err) {
		return viewer, errors.New("unsafe private development bundle directory")
	}
	expected := map[string]developmentArchiveFile{}
	for i, artifact := range artifacts {
		prefix := "viewer"
		if i != 0 {
			prefix = "adb"
		}
		var archive []byte
		if cached {
			archive, err = readDevelopmentBundleFile(root, bundle+"/"+prefix+".archive", 128<<20)
		} else {
			archive, err = downloadDevelopmentArtifact(ctx, client, artifact)
		}
		if err != nil {
			return viewer, err
		}
		digest := sha256.Sum256(archive)
		if hex.EncodeToString(digest[:]) != artifact.SHA256 {
			return viewer, errors.New("development tool archive checksum mismatch")
		}
		endpoint, _ := url.Parse(artifact.URL)
		files, err := decodeDevelopmentArchive(archive, strings.HasSuffix(endpoint.Path, ".zip"))
		if err != nil {
			return viewer, err
		}
		expected[prefix+".archive"] = developmentArchiveFile{Data: archive, Mode: 0600}
		for name, contents := range files {
			expected[prefix+"/"+name] = contents
		}
	}
	for name, contents := range expected {
		if contents.Mode&0100 == 0 {
			continue
		}
		var target *string
		switch filepath.Base(name) {
		case "scrcpy":
			target = &viewer.Scrcpy
		case "adb":
			target = &viewer.ADB
		}
		if target != nil {
			if *target != "" {
				return viewer, errors.New("ambiguous development archive executable")
			}
			*target = filepath.Join(base, bundle, name)
		}
	}
	if viewer.Scrcpy == "" || viewer.ADB == "" {
		return viewer, errors.New("development archive is missing scrcpy or ADB")
	}
	viewer.Version, viewer.OwnedRoot = viewArtifact.Version, filepath.Join(base, bundle)
	if !cached {
		stage := ".acquire-" + rand.Text()
		if err := root.Mkdir(stage, 0700); err != nil {
			return viewer, err
		}
		defer root.RemoveAll(stage)
		for name, contents := range expected {
			if err := ctx.Err(); err != nil {
				return viewer, err
			}
			target := filepath.Join(stage, name)
			if err := root.MkdirAll(filepath.Dir(target), 0700); err != nil {
				return viewer, err
			}
			output, err := root.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, contents.Mode)
			if err != nil {
				return viewer, err
			}
			_, err = output.Write(contents.Data)
			if closeErr := output.Close(); err == nil {
				err = closeErr
			}
			if err != nil {
				return viewer, err
			}
		}
		if err := ctx.Err(); err != nil {
			return viewer, err
		}
		if err := root.Rename(stage, bundle); err != nil {
			return viewer, err
		}
	}
	directories := map[string]bool{bundle: true}
	for name := range expected {
		for parent := filepath.Dir(name); parent != "."; parent = filepath.Dir(parent) {
			directories[filepath.ToSlash(filepath.Join(bundle, parent))] = true
		}
	}
	err = fs.WalkDir(root.FS(), bundle, func(name string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if entry.IsDir() {
			info, err := root.Lstat(name)
			if err != nil || !developmentOwnedInfo(info) || !directories[filepath.ToSlash(name)] {
				return errors.New("unsafe or unexpected private development bundle directory")
			}
			return nil
		}
		relative := strings.TrimPrefix(filepath.ToSlash(name), bundle+"/")
		contents, exists := expected[relative]
		if !exists || !entry.Type().IsRegular() {
			return errors.New("unexpected file or link in private development bundle")
		}
		data, err := readDevelopmentBundleFile(root, name, 128<<20)
		if err != nil {
			return err
		}
		info, err := root.Lstat(name)
		if err != nil || info.Mode().Perm() != contents.Mode || !bytebuf.Equal(data, contents.Data) {
			return errors.New("private development bundle integrity mismatch")
		}
		delete(expected, relative)
		return nil
	})
	if err == nil && len(expected) != 0 {
		err = errors.New("private development bundle is missing files")
	}
	return viewer, err
}

var developmentArtifactVersionPattern = regexp.MustCompile(`^[0-9]{1,6}(\.[0-9]{1,6}){1,3}([_-][a-zA-Z0-9][a-zA-Z0-9._-]{0,31})?$`)
var developmentRegistryImagePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9._:/-]{0,255}$`)

func developmentLockJSON(lock DevelopmentToolLock) []byte {
	data, _ := json.Marshal(lock)
	return data
}

func developmentOwnedInfo(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Uid == uint32(os.Geteuid()) && info.Mode().Perm()&0022 == 0
}

func developmentOwnedDirectory(name string, create bool) error {
	if create {
		if err := os.Mkdir(name, 0700); err != nil && !os.IsExist(err) {
			return err
		}
	}
	info, err := os.Lstat(name)
	if err != nil || !info.IsDir() || !developmentOwnedInfo(info) {
		return fmt.Errorf("unsafe or unowned development directory: %s", name)
	}
	return canonicalDevelopmentPath(name)
}

func developmentInstallationID(name, home string) (string, error) {
	data, err := readDevelopmentDocument(name)
	if err != nil {
		return "", err
	}
	info, err := os.Lstat(name)
	if err != nil || !developmentOwnedInfo(info) {
		return "", errors.New("unsafe development installation marker")
	}
	values := map[string]string{}
	scanner := bufio.NewScanner(bytebuf.NewReader(data))
	for scanner.Scan() {
		key, value, ok := strings.Cut(scanner.Text(), "=")
		if _, duplicate := values[key]; !ok || duplicate {
			return "", errors.New("invalid development installation marker")
		}
		values[key] = value
	}
	if scanner.Err() != nil || values["FORMAT"] != "2" || values["ROOT"] != home || values["STATUS"] != "ready" || !developmentInstallationPattern.MatchString(values["INSTALL_ID"]) {
		return "", errors.New("not an owned ready Molt installation")
	}
	return values["INSTALL_ID"], nil
}

var developmentInstallationPattern = regexp.MustCompile(`^[a-f0-9]{32}$`)

func developmentToolsDirectory(home string) (string, error) {
	if err := developmentOwnedDirectory(home, false); err != nil {
		return "", err
	}
	installation, err := developmentInstallationID(filepath.Join(home, ".install-manifest"), home)
	if err != nil {
		return "", err
	}
	tools := filepath.Join(home, "tools")
	info, err := os.Lstat(tools)
	if err == nil && info.Mode()&os.ModeSymlink != 0 {
		target, err := os.Readlink(tools)
		if err != nil || target != "current/tools" {
			return "", errors.New("unexpected Molt tools redirect")
		}
		current, err := os.Readlink(filepath.Join(home, "current"))
		if err != nil || !strings.HasPrefix(current, "releases/install.") || filepath.Clean(current) != current || filepath.Dir(current) != "releases" {
			return "", errors.New("unexpected Molt release redirect")
		}
		release := filepath.Join(home, current)
		if err := developmentOwnedDirectory(filepath.Join(home, "releases"), false); err != nil {
			return "", err
		}
		if err := developmentOwnedDirectory(release, false); err != nil {
			return "", err
		}
		owner, err := developmentInstallationID(filepath.Join(release, ".molt-release"), home)
		if err != nil || owner != installation {
			return "", errors.New("Molt release ownership does not match this installation")
		}
		tools = filepath.Join(release, "tools")
	} else if err != nil && !os.IsNotExist(err) {
		return "", err
	}
	if err := developmentOwnedDirectory(tools, true); err != nil {
		return "", err
	}
	return tools, nil
}

func downloadDevelopmentArtifact(ctx context.Context, client *http.Client, artifact DevelopmentArtifact) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, "GET", artifact.URL, nil)
	if err != nil {
		return nil, err
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("development tool download returned HTTP %d", response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, (128<<20)+1))
	if err != nil || len(data) > 128<<20 {
		return nil, errors.Join(errors.New("development tool download failed or is too large"), err)
	}
	return data, nil
}

func readDevelopmentBundleFile(root *os.Root, name string, limit int64) ([]byte, error) {
	for current := name; current != "."; current = filepath.Dir(current) {
		info, err := root.Lstat(current)
		if err != nil || info.Mode()&os.ModeSymlink != 0 || !developmentOwnedInfo(info) {
			return nil, errors.New("unsafe private development bundle path")
		}
	}
	file, err := root.OpenFile(name, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > limit {
		return nil, errors.New("invalid private development bundle file")
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err == nil && int64(len(data)) > limit {
		err = errors.New("private development bundle file is too large")
	}
	return data, err
}

func readDevelopmentDocument(name string) ([]byte, error) {
	if err := canonicalDevelopmentPath(name); err != nil {
		return nil, err
	}
	root, err := os.OpenRoot(filepath.Dir(name))
	if err != nil {
		return nil, err
	}
	defer root.Close()
	file, err := root.Open(filepath.Base(name))
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return nil, errors.New("development document must be a regular file")
	}
	return io.ReadAll(io.LimitReader(file, (1<<20)+1))
}

func developmentArtifact(lock DevelopmentToolLock, role, platform, arch string) (DevelopmentArtifact, error) {
	switch arch {
	case "aarch64", "arm64":
		arch = "arm64"
	case "x86_64", "amd64":
		arch = "amd64"
	default:
		return DevelopmentArtifact{}, errors.New("unsupported development architecture")
	}
	for _, artifact := range lock.Artifacts {
		if artifact.Role == role && artifact.OS == platform && artifact.Arch == arch {
			return artifact, nil
		}
	}
	return DevelopmentArtifact{}, fmt.Errorf("no locked development artifact for %s/%s/%s", role, platform, arch)
}

func runDevelopmentTools(args []string) int {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	var result any
	var err error
	failure := 2
	switch {
	case len(args) == 2 && args[0] == "validate":
		if filepath.Base(args[1]) != "development.json" || filepath.Base(filepath.Dir(args[1])) != ".molt" {
			err = errors.New("profile must be at the canonical .molt/development.json path")
		} else {
			result, err = readDevelopmentSpec(args[1], filepath.Dir(filepath.Dir(args[1])))
		}
	case len(args) == 5 && args[0] == "artifact", len(args) == 3 && args[0] == "viewer":
		lockPath := args[1]
		if args[0] == "viewer" {
			lockPath = args[2]
		}
		var data []byte
		data, err = readDevelopmentDocument(lockPath)
		var lock DevelopmentToolLock
		if err == nil {
			lock, err = decodeDevelopmentToolLock(data)
		}
		if err == nil && args[0] == "artifact" {
			result, err = developmentArtifact(lock, args[2], args[3], args[4])
		} else if err == nil {
			err = canonicalDevelopmentPath(args[1])
			if err == nil && runtime.GOOS != "darwin" {
				err = errors.New("private development viewer is supported only on macOS")
			}
			if err == nil {
				failure = 1
				client := &http.Client{Timeout: 2 * time.Minute, CheckRedirect: func(req *http.Request, via []*http.Request) error {
					if req.URL.Scheme != "https" || len(via) >= 10 {
						return errors.New("unsafe development tool download redirect")
					}
					return nil
				}}
				result, err = ensureDevelopmentViewer(ctx, args[1], lock, runtime.GOARCH, client)
			}
		}
	default:
		err = errors.New("usage: development-tools validate <profile> | artifact <lock> <role> <os> <arch> | viewer <MOLT_HOME> <lock>")
	}
	if errors.Is(err, context.Canceled) || ctx.Err() != nil {
		return 130
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "molt:", err)
		return failure
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, "molt:", err)
		return 1
	}
	return 0
}
