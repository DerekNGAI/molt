package main

import (
	"archive/tar"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

type conflictPreview struct {
	Project, Path, Directory, MacHash, VMHash, Mac, VM string
}

func conflictRoot(name string) string {
	parts := strings.Split(name, "/")
	for i, part := range parts {
		if part == ".git" {
			return strings.Join(parts[:i+1], "/")
		}
	}
	return name
}

func endpointPath(root, name string) (string, error) {
	if name == "" || name == "." || name == ".." || path.IsAbs(name) || path.Clean(name) != name || strings.ContainsAny(name, "\x00\r\n") || strings.HasPrefix(name, "../") {
		return "", fmt.Errorf("unsafe conflict path %q", name)
	}
	info, err := os.Lstat(root)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", fmt.Errorf("invalid checkout root")
	}
	parent := root
	parts := strings.Split(name, "/")
	for _, part := range parts[:len(parts)-1] {
		parent = filepath.Join(parent, part)
		info, err := os.Lstat(parent)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return "", fmt.Errorf("conflict path has a redirected parent: %s", name)
		}
	}
	return filepath.Join(root, filepath.FromSlash(name)), nil
}

func fileHash(name string) (string, error) {
	f, err := os.Open(name)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err = io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// An empty archive represents a deletion; archives keep binary files and links intact.
func archivePath(root, name, archive string) error {
	target, err := endpointPath(root, name)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(archive, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := os.Lstat(target); os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return err
	}
	w := tar.NewWriter(f)
	err = filepath.Walk(target, func(filename string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if !info.Mode().IsRegular() && !info.IsDir() && info.Mode()&os.ModeSymlink == 0 {
			return fmt.Errorf("cannot back up special file: %s", filename)
		}
		link := ""
		if info.Mode()&os.ModeSymlink != 0 {
			var err error
			link, err = os.Readlink(filename)
			if err != nil {
				return err
			}
		}
		header, err := tar.FileInfoHeader(info, link)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, filename)
		header.Name = filepath.ToSlash(rel)
		if err = w.WriteHeader(header); err != nil || !info.Mode().IsRegular() {
			return err
		}
		in, err := os.Open(filename)
		if err != nil {
			return err
		}
		_, err = io.Copy(w, in)
		in.Close()
		return err
	})
	closeErr := w.Close()
	if err != nil {
		return err
	}
	return closeErr
}

func unpackSnapshot(archive, root, name string) (string, error) {
	f, err := os.Open(archive)
	if err != nil {
		return "", err
	}
	defer f.Close()
	r := tar.NewReader(f)
	count := 0
	for {
		header, err := r.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", err
		}
		member := strings.TrimSuffix(header.Name, "/")
		if member != name && !strings.HasPrefix(member, name+"/") {
			return "", fmt.Errorf("archive entry outside conflict: %s", header.Name)
		}
		target, err := endpointPath(root, member)
		if err != nil {
			return "", err
		}
		if err = os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			return "", err
		}
		switch header.Typeflag {
		case tar.TypeDir:
			err = os.Mkdir(target, os.FileMode(header.Mode)&0777)
			if os.IsExist(err) {
				err = fmt.Errorf("duplicate archive directory: %s", member)
			}
		case tar.TypeReg, tar.TypeRegA:
			var out *os.File
			out, err = os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, os.FileMode(header.Mode)&0777)
			if err == nil {
				_, err = io.Copy(out, r)
				out.Close()
			}
		case tar.TypeSymlink:
			err = os.Symlink(header.Linkname, target)
		default:
			err = fmt.Errorf("unsupported archive entry: %s", member)
		}
		if err != nil {
			return "", err
		}
		count++
	}
	if count == 0 {
		return "", nil
	}
	target, err := endpointPath(root, name)
	if err != nil {
		return "", err
	}
	if _, err = os.Lstat(target); err != nil {
		return "", err
	}
	return target, nil
}

func replacePath(root, name, archive, expected string) error {
	target, err := endpointPath(root, name)
	if err != nil {
		return err
	}
	// Stage on the destination filesystem so rename can restore a failed replacement.
	stage, err := os.MkdirTemp(root, ".molt-resolution-")
	if err != nil {
		return err
	}
	removeStage := true
	defer func() {
		if removeStage {
			os.RemoveAll(stage)
		}
	}()
	files := filepath.Join(stage, "files")
	if err = os.Mkdir(files, 0700); err != nil {
		return err
	}
	replacement, err := unpackSnapshot(archive, files, name)
	if err != nil {
		return err
	}
	current := filepath.Join(stage, "current.tar")
	if err = archivePath(root, name, current); err != nil {
		return err
	}
	got, err := fileHash(current)
	if err != nil {
		return err
	}
	if got != expected {
		return fmt.Errorf("%s changed since inspection; inspect it again", name)
	}
	if err = os.MkdirAll(filepath.Dir(target), 0755); err != nil {
		return err
	}
	rollback := filepath.Join(stage, "original")
	hadOriginal := false
	if _, err = os.Lstat(target); err == nil {
		if err = os.Rename(target, rollback); err != nil {
			return err
		}
		hadOriginal = true
	} else if !os.IsNotExist(err) {
		return err
	}
	if replacement != "" {
		if err = os.Rename(replacement, target); err != nil {
			if hadOriginal {
				if restoreErr := os.Rename(rollback, target); restoreErr != nil {
					removeStage = false
					return fmt.Errorf("replacement failed: %v; original retained at %s", err, rollback)
				}
			}
			return err
		}
	}
	return nil
}

func snapshotSummary(archive string) (string, error) {
	f, err := os.Open(archive)
	if err != nil {
		return "", err
	}
	defer f.Close()
	r := tar.NewReader(f)
	header, err := r.Next()
	if err == io.EOF {
		return "Deleted on this side.", nil
	}
	if err != nil {
		return "", err
	}
	if header.Typeflag == tar.TypeReg || header.Typeflag == tar.TypeRegA {
		data, err := io.ReadAll(io.LimitReader(r, 65537))
		if err != nil {
			return "", err
		}
		if strings.ContainsRune(string(data), '\x00') || !utf8.Valid(data) {
			return fmt.Sprintf("Binary file · %d bytes", header.Size), nil
		}
		text := safeText(string(data))
		if len(data) > 65536 {
			text = safeText(string(data[:65536])) + "\n[Preview limited to 64 KiB; resolution keeps the full file.]"
		}
		return fmt.Sprintf("File · %d bytes\n\n%s", header.Size, text), nil
	}
	if header.Typeflag == tar.TypeSymlink {
		return "Symbolic link → " + safeText(header.Linkname), nil
	}
	var entries []string
	for count := 0; ; count++ {
		if count < 50 {
			entries = append(entries, safeText(header.Name))
		}
		header, err = r.Next()
		if err == io.EOF {
			if count >= 50 {
				entries = append(entries, "[More entries; resolution keeps the complete directory.]")
			}
			return "Directory · resolved as one group\n\n" + strings.Join(entries, "\n"), nil
		}
		if err != nil {
			return "", err
		}
	}
}

func (b backend) currentConflict(ref, name string) error {
	data, err := b.output(30*time.Second, "sync", ref, "--json")
	if err != nil {
		return err
	}
	states, err := parseSync(data)
	if err != nil {
		return err
	}
	session := readValue(filepath.Join(b.Home, "projects", strings.TrimPrefix(ref, "@"), "sync"))
	for _, c := range states[session].Conflicts {
		if conflictRoot(c.Root) == name {
			return nil
		}
	}
	return fmt.Errorf("conflict changed or was resolved; refresh synchronization")
}

func (b backend) remoteArchive(ref, name, destination string) error {
	f, err := os.OpenFile(destination, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	c := b.command(b.Context, "sync-endpoint", ref, "read", name)
	c.Stdout = f
	var errors strings.Builder
	c.Stderr = &errors
	if err = c.Run(); err != nil {
		return fmt.Errorf("VM backup failed: %v: %s", err, safeText(errors.String()))
	}
	return nil
}

func secureDirectory(name string) error {
	if err := os.Mkdir(name, 0700); err != nil && !os.IsExist(err) {
		return err
	}
	info, err := os.Lstat(name)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("unsafe backup directory: %s", name)
	}
	return nil
}

func (b backend) previewConflict(ref, name string) (conflictPreview, error) {
	p := conflictPreview{Project: ref, Path: name}
	if !strings.HasPrefix(ref, "@") || !projectID.MatchString(ref[1:]) {
		return p, fmt.Errorf("invalid project identity")
	}
	if err := b.currentConflict(ref, name); err != nil {
		return p, err
	}
	root := readValue(filepath.Join(b.Home, "projects", ref[1:], "path"))
	if _, err := endpointPath(root, name); err != nil {
		return p, err
	}
	dir := filepath.Join(b.Home, "backups")
	if err := secureDirectory(dir); err != nil {
		return p, err
	}
	dir = filepath.Join(dir, ref[1:])
	if err := secureDirectory(dir); err != nil {
		return p, err
	}
	var err error
	p.Directory, err = os.MkdirTemp(dir, "conflict-")
	if err != nil {
		return p, err
	}
	mac, vm := filepath.Join(p.Directory, "mac.tar"), filepath.Join(p.Directory, "vm.tar")
	if err = archivePath(root, name, mac); err != nil {
		return p, err
	}
	if err = b.remoteArchive(ref, name, vm); err != nil {
		return p, err
	}
	p.MacHash, err = fileHash(mac)
	if err == nil {
		p.VMHash, err = fileHash(vm)
	}
	if err == nil {
		p.Mac, err = snapshotSummary(mac)
	}
	if err == nil {
		p.VM, err = snapshotSummary(vm)
	}
	if err != nil {
		return p, err
	}
	data, err := json.Marshal(p)
	if err == nil {
		err = os.WriteFile(filepath.Join(p.Directory, "preview.json"), data, 0600)
	}
	return p, err
}

func (b backend) resolveConflict(ref, directory, side string) (err error) {
	if !strings.HasPrefix(ref, "@") || !projectID.MatchString(ref[1:]) || side != "mac" && side != "vm" {
		return fmt.Errorf("invalid conflict resolution")
	}
	parent := filepath.Join(b.Home, "backups", ref[1:])
	if filepath.Dir(directory) != parent || !strings.HasPrefix(filepath.Base(directory), "conflict-") {
		return fmt.Errorf("invalid conflict backup")
	}
	for _, name := range []string{filepath.Join(b.Home, "backups"), parent, directory} {
		info, err := os.Lstat(name)
		if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("redirected conflict backup")
		}
	}
	data, err := os.ReadFile(filepath.Join(directory, "preview.json"))
	if err != nil {
		return err
	}
	var p conflictPreview
	if err = json.Unmarshal(data, &p); err != nil || p.Project != ref || p.Directory != directory {
		return fmt.Errorf("invalid conflict preview")
	}
	if err = b.currentConflict(ref, p.Path); err != nil {
		return err
	}
	if _, err = b.output(30*time.Second, "sync-prepare", ref); err != nil {
		return err
	}
	// Always resume after a failed replacement, retaining backups and cleanup records.
	defer func() {
		resume := b
		resume.Context = context.Background()
		if _, resumeErr := resume.output(30*time.Second, "sync-resume", ref); resumeErr != nil {
			if err == nil {
				err = fmt.Errorf("could not resume synchronization: %w", resumeErr)
			} else {
				err = fmt.Errorf("%v; could not resume synchronization: %w", err, resumeErr)
			}
		}
	}()
	root := readValue(filepath.Join(b.Home, "projects", ref[1:], "path"))
	work, err := os.MkdirTemp(directory, "check-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(work)
	mac, vm := filepath.Join(work, "mac.tar"), filepath.Join(work, "vm.tar")
	if err = archivePath(root, p.Path, mac); err == nil {
		err = b.remoteArchive(ref, p.Path, vm)
	}
	if err != nil {
		return err
	}
	for filename, expected := range map[string]string{mac: p.MacHash, vm: p.VMHash, filepath.Join(directory, "mac.tar"): p.MacHash, filepath.Join(directory, "vm.tar"): p.VMHash} {
		hash, err := fileHash(filename)
		if err != nil {
			return err
		}
		if hash != expected {
			return fmt.Errorf("%s changed since inspection; inspect it again", p.Path)
		}
	}
	selected := filepath.Join(directory, side+".tar")
	// Validate every archive member before sending it to either filesystem.
	files := filepath.Join(work, "files")
	if err = os.Mkdir(files, 0700); err != nil {
		return err
	}
	if _, err = unpackSnapshot(selected, files, p.Path); err != nil {
		return err
	}
	if err = b.Context.Err(); err != nil {
		return err
	}
	if side == "vm" {
		err = replacePath(root, p.Path, selected, p.MacHash)
	} else {
		f, openErr := os.Open(selected)
		if openErr != nil {
			return openErr
		}
		defer f.Close()
		c := b.command(b.Context, "sync-endpoint", ref, "write", p.Path, p.VMHash)
		c.Stdin, c.Stdout, c.Stderr = f, os.Stdout, os.Stderr
		err = c.Run()
	}
	if err != nil {
		return err
	}
	if _, err = b.output(30*time.Second, "sync-cycle", ref); err != nil {
		return fmt.Errorf("choice applied; synchronization still needs attention: %w", err)
	}
	fmt.Printf("Resolved %s using the %s version. Backups: %s\n", p.Path, side, directory)
	return nil
}

func runSyncRecovery(args []string) int {
	if len(args) < 5 || len(args) > 6 {
		fmt.Fprintln(os.Stderr, "invalid synchronization helper arguments")
		return 1
	}
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	b := backend{CLI: args[1], Home: args[2], Context: ctx}
	var err error
	if args[0] == "sync-preview" && len(args) == 5 {
		var preview conflictPreview
		preview, err = b.previewConflict(args[3], args[4])
		if err == nil {
			err = json.NewEncoder(os.Stdout).Encode(preview)
		}
	} else if args[0] == "sync-resolve" && len(args) == 6 {
		err = b.resolveConflict(args[3], args[4], args[5])
	} else {
		err = fmt.Errorf("invalid synchronization helper action")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "molt:", err)
		return 1
	}
	return 0
}
