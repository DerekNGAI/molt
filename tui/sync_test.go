package main

import (
	"archive/tar"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

func TestSyncShortcutOpensRecoveryInsideTUI(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	p := project{ID: "aaaaaaaaaaaa", Name: "app", Sync: "molt-app"}
	m.inv.Projects = []project{p}
	m.selected = p.ID
	m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})
	if m.overlay != "loading" || m.dialog.Title != "Synchronization / app" {
		t.Fatalf("sync shortcut did not open recovery: %s / %s", m.overlay, m.dialog.Title)
	}
	m.finishQuery(queryMsg{ID: m.queryID, Data: []byte(`[{"name":"molt-app","conflicts":[{"root":"file.txt","alphaChanges":[],"betaChanges":[]}]}]`)})
	if m.overlay != "native-menu" || len(m.menu.Items) == 0 || m.menu.Items[0].Title != "file.txt" {
		t.Fatal("synchronization does not offer the conflicting file")
	}
}

func TestReplacementHandlesDirectoriesLinksBinaryAndDeletions(t *testing.T) {
	root := t.TempDir()
	archive := filepath.Join(t.TempDir(), "chosen.tar")
	current := filepath.Join(t.TempDir(), "current.tar")
	for _, name := range []string{"mac.tar", "current.tar", "original", "tree"} {
		t.Run(name, func(t *testing.T) {
			os.MkdirAll(filepath.Join(root, name), 0755)
			os.WriteFile(filepath.Join(root, name, "binary"), []byte{0, 1, 255}, 0755)
			os.Symlink("binary", filepath.Join(root, name, "link"))
			if err := archivePath(root, name, archive); err != nil {
				t.Fatal(err)
			}
			os.RemoveAll(filepath.Join(root, name))
			os.WriteFile(filepath.Join(root, name), []byte("other side"), 0644)
			archivePath(root, name, current)
			hash, _ := fileHash(current)
			if err := replacePath(root, name, archive, hash); err != nil {
				t.Fatal(err)
			}
			data, _ := os.ReadFile(filepath.Join(root, name, "binary"))
			link, _ := os.Readlink(filepath.Join(root, name, "link"))
			if len(data) != 3 || data[2] != 255 || link != "binary" {
				t.Fatal("replacement lost bytes or a symbolic link")
			}
			archivePath(root, name, current)
			hash, _ = fileHash(current)
			os.WriteFile(archive, nil, 0600)
			if err := replacePath(root, name, archive, hash); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Lstat(filepath.Join(root, name)); !os.IsNotExist(err) {
				t.Fatal("selected deletion was not applied")
			}
		})
	}
}

func TestReplacementRejectsArchiveTraversalWithoutChangingTarget(t *testing.T) {
	for _, member := range []string{"../outside", "/outside", "file/../../outside", "unrelated"} {
		t.Run(member, func(t *testing.T) {
			root := t.TempDir()
			os.WriteFile(filepath.Join(root, "file"), []byte("preserve"), 0644)
			archive := filepath.Join(t.TempDir(), "bad.tar")
			f, _ := os.Create(archive)
			w := tar.NewWriter(f)
			w.WriteHeader(&tar.Header{Name: member, Mode: 0644, Size: 1})
			w.Write([]byte("x"))
			w.Close()
			f.Close()
			if err := replacePath(root, "file", archive, "invalid"); err == nil {
				t.Fatal("accepted traversal")
			}
			data, _ := os.ReadFile(filepath.Join(root, "file"))
			if string(data) != "preserve" {
				t.Fatal("invalid archive changed the checkout")
			}
		})
	}
}

func TestRemovalFailureOffersRecoveryAndKeepsTarget(t *testing.T) {
	m := newModel(backend{Context: context.Background()})
	p := project{ID: "aaaaaaaaaaaa", Name: "original"}
	m.removalRecovery(p, "Synchronization needs attention")
	m.inv.Projects = []project{{ID: "bbbbbbbbbbbb", Name: "other"}}
	if m.menu.Items[0].Title != "Resolve synchronization issues" {
		t.Fatal("failed removal has no recovery action")
	}
	m.menu.Items[0].Run()
	if m.dialog.Title != "Synchronization / original" {
		t.Fatal("recovery switched projects")
	}
}

func TestConflictReplacementPreservesChosenContentAndRejectsChangedFiles(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "file.txt")
	archive := filepath.Join(t.TempDir(), "snapshot.tar")
	os.WriteFile(path, []byte("Mac version\n"), 0640)
	if err := archivePath(root, "file.txt", archive); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(path, []byte("VM version\n"), 0640)
	current := filepath.Join(t.TempDir(), "current.tar")
	archivePath(root, "file.txt", current)
	expected, _ := fileHash(current)
	if err := replacePath(root, "file.txt", archive, expected); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(path)
	if string(data) != "Mac version\n" {
		t.Fatal("wrong version selected")
	}
	os.WriteFile(path, []byte("Edited after preview\n"), 0640)
	if err := replacePath(root, "file.txt", archive, expected); err == nil {
		t.Fatal("overwrote a file edited after inspection")
	}
	data, _ = os.ReadFile(path)
	if !strings.Contains(string(data), "Edited after preview") {
		t.Fatal("stale resolution destroyed edits")
	}
}

func TestConflictPathsCannotEscapeCheckout(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	os.Symlink(outside, filepath.Join(root, "link"))
	for _, path := range []string{"../outside", "/absolute", "", ".", "link/file", "dir/../file", "file\nname"} {
		if _, err := endpointPath(root, path); err == nil {
			t.Fatalf("accepted unsafe path %q", path)
		}
	}
}

func TestGitConflictsAreGrouped(t *testing.T) {
	for path, want := range map[string]string{".git/index": ".git", "nested/.git/refs/heads/main": "nested/.git", "src/file.go": "src/file.go"} {
		if got := conflictRoot(path); got != want {
			t.Fatalf("%q grouped as %q", path, got)
		}
	}
}

func TestRetryRemovalRequiresClearSynchronization(t *testing.T) {
	for _, state := range []string{
		`{"name":"app","status":"watching","alpha":{"connected":true},"beta":{"connected":true}}`,
		`{"name":"app","conflicts":[{"root":"file"}]}`,
		`{"name":"app","lastError":"permission denied"}`,
		`{"name":"app","paused":true}`,
		`{"name":"app","status":"watching","alpha":{"connected":true},"beta":{"connected":true,"transitionProblems":[{"path":"test/committer.test.js","error":"unable to remove file: permission denied"}]}}`,
	} {
		m := newModel(backend{Context: context.Background()})
		p := project{ID: "aaaaaaaaaaaa", Name: "app", Sync: "app"}
		m.syncMenu(p, m.dashboard, m.dashboard)
		m.finishQuery(queryMsg{ID: m.queryID, Data: []byte("[" + state + "]")})
		found := false
		for _, item := range m.menu.Items {
			found = found || item.Title == "Retry removal"
		}
		if found != (strings.Contains(state, `"watching"`) && !strings.Contains(state, `"transitionProblems"`)) {
			t.Fatalf("incorrect retry availability: %s", state)
		}
	}
}

func TestSynchronizationExplainsFilesystemProblems(t *testing.T) {
	for _, endpoint := range []string{"alpha", "beta"} {
		for _, kind := range []string{"scanProblems", "transitionProblems"} {
			m := newModel(backend{Context: context.Background()})
			p := project{ID: "aaaaaaaaaaaa", Name: "app", Sync: "app"}
			m.syncMenu(p, m.dashboard, m.dashboard)
			data := `[{"name":"app","status":"watching","` + endpoint + `":{"connected":true,"` + kind + `":[{"path":"test/committer.test.js","error":"unable to remove file: permission denied"}]}}]`
			m.finishQuery(queryMsg{ID: m.queryID, Data: []byte(data)})
			var problem, repair *menuItem
			for i := range m.menu.Items {
				item := &m.menu.Items[i]
				if strings.Contains(item.Title, "test/committer.test.js") {
					problem = item
				}
				if item.Title == "Repair VM permissions" {
					repair = item
				}
			}
			if problem == nil {
				t.Fatalf("%s %s did not expose the failing path", endpoint, kind)
			}
			problem.Run()
			if !strings.Contains(m.dialog.Body, "unable to remove file: permission denied") {
				t.Fatal("filesystem problem omitted its error")
			}
			if (repair != nil) != (endpoint == "beta") {
				t.Fatal("VM permissions repair offered for the wrong endpoint")
			}
			if repair != nil {
				repair.Run()
				if m.overlay != "confirm" || !strings.Contains(m.dialog.Body, "stopped") {
					t.Fatal("permissions repair did not explain writer shutdown")
				}
			}
		}
	}
}

func TestConflictRecoveryFitsSmallTerminals(t *testing.T) {
	for _, size := range [][2]int{{100, 32}, {70, 24}, {42, 14}} {
		m := newModel(backend{Context: context.Background()})
		m.width, m.height = size[0], size[1]
		p := project{ID: "aaaaaaaaaaaa", Name: "app"}
		preview := conflictPreview{Path: "long/directory/file.txt", Directory: "/long/backup/path", Mac: "Mac version", VM: "VM version"}
		m.conflictMenu(p, preview, m.dashboard)
		for _, index := range []int{-1, 0, 3} {
			if index >= 0 {
				m.conflictMenu(p, preview, m.dashboard)
				m.menu.Items[index].Run()
			}
			view := m.View()
			if lipgloss.Width(view) > size[0] || lipgloss.Height(view) > size[1] || !strings.Contains(view, "Esc") {
				t.Fatalf("recovery view does not fit %v", size)
			}
		}
	}
}
