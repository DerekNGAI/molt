package main

import (
	"archive/tar"
	"archive/zip"
	bytebuf "bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"debug/macho"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func developmentArchive(t *testing.T, entries ...*tar.Header) []byte {
	t.Helper()
	var out bytebuf.Buffer
	compressed := gzip.NewWriter(&out)
	writer := tar.NewWriter(compressed)
	for _, entry := range entries {
		copy := *entry
		copy.Size = 0
		if copy.Typeflag == tar.TypeReg {
			copy.Size = 4
		}
		if err := writer.WriteHeader(&copy); err != nil {
			t.Fatal(err)
		}
		if copy.Size != 0 {
			writer.Write([]byte("tool"))
		}
	}
	writer.Close()
	compressed.Close()
	return out.Bytes()
}

func developmentViewerFixture(t *testing.T) (string, DevelopmentToolLock, *http.Client, *atomic.Bool) {
	t.Helper()
	home, _ := filepath.EvalSymlinks(t.TempDir())
	os.WriteFile(filepath.Join(home, ".install-manifest"), []byte("FORMAT=2\nINSTALL_ID="+strings.Repeat("a", 32)+"\nROOT="+home+"\nSTATUS=ready\n"), 0600)
	archive := developmentArchive(t, &tar.Header{Name: "bundle/scrcpy", Mode: 0755, Typeflag: tar.TypeReg}, &tar.Header{Name: "bundle/adb", Mode: 0755, Typeflag: tar.TypeReg}, &tar.Header{Name: "bundle/scrcpy-server", Mode: 0644, Typeflag: tar.TypeReg})
	digest := sha256.Sum256(archive)
	lock := DevelopmentToolLock{Version: 1, Artifacts: []DevelopmentArtifact{}}
	for _, role := range []string{"viewer", "adb"} {
		lock.Artifacts = append(lock.Artifacts, DevelopmentArtifact{Role: role, OS: "darwin", Arch: "arm64", Version: "4.1", URL: "https://example.invalid/bundle.tar.gz", SHA256: hex.EncodeToString(digest[:])})
	}
	var broken atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if broken.Load() {
			w.Write([]byte("corrupt archive"))
		} else {
			w.Write(archive)
		}
	}))
	t.Cleanup(server.Close)
	endpoint, _ := url.Parse(server.URL)
	return home, lock, &http.Client{Transport: releaseTransport{endpoint}}, &broken
}

func TestDevelopmentLockRejectsUnverifiedAndAmbiguousArtifacts(t *testing.T) {
	_, lock, _, _ := developmentViewerFixture(t)
	if _, err := decodeDevelopmentToolLock(developmentFixtureJSON(t, lock)); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name string
		edit func(*DevelopmentToolLock)
	}{
		{"bad version", func(l *DevelopmentToolLock) { l.Version = 2 }},
		{"duplicate platform", func(l *DevelopmentToolLock) { l.Artifacts = append(l.Artifacts, l.Artifacts[0]) }},
		{"missing hash", func(l *DevelopmentToolLock) { l.Artifacts[0].SHA256 = "" }},
		{"insecure URL", func(l *DevelopmentToolLock) { l.Artifacts[0].URL = "http://example.invalid/tool" }},
		{"credential URL", func(l *DevelopmentToolLock) { l.Artifacts[0].URL = "https://secret@example.invalid/tool" }},
		{"mixed formats", func(l *DevelopmentToolLock) {
			l.Artifacts[0].Image = "nixos/nix"
			l.Artifacts[0].Digest = "sha256:" + strings.Repeat("b", 64)
		}},
		{"unsafe version", func(l *DevelopmentToolLock) { l.Artifacts[0].Version = "../../outside" }},
		{"unknown architecture", func(l *DevelopmentToolLock) { l.Artifacts[0].Arch = "armv7" }},
	} {
		t.Run(test.name, func(t *testing.T) {
			candidate := lock
			candidate.Artifacts = append([]DevelopmentArtifact{}, lock.Artifacts...)
			test.edit(&candidate)
			if _, err := decodeDevelopmentToolLock(developmentFixtureJSON(t, candidate)); err == nil {
				t.Fatal("accepted unusable artifact lock")
			}
		})
	}
}

func TestDevelopmentArchivesRejectEscapeLinksAndDuplicatePaths(t *testing.T) {
	for _, entries := range [][]*tar.Header{
		{{Name: "../outside", Mode: 0755, Typeflag: tar.TypeReg}},
		{{Name: "/outside", Mode: 0755, Typeflag: tar.TypeReg}},
		{{Name: "bundle/link", Linkname: "../../outside", Typeflag: tar.TypeSymlink}},
		{{Name: "bundle/link", Linkname: "other", Typeflag: tar.TypeLink}},
		{{Name: "bundle/tool", Typeflag: tar.TypeReg}, {Name: "bundle/tool", Typeflag: tar.TypeReg}},
		{{Name: "bundle", Typeflag: tar.TypeReg}, {Name: "bundle/tool", Typeflag: tar.TypeReg}},
	} {
		if _, err := decodeDevelopmentArchive(developmentArchive(t, entries...), false); err == nil {
			t.Fatalf("accepted unsafe archive entries: %+v", entries)
		}
	}
}

func TestDevelopmentViewerVerifiesCacheAndPreservesWorkingBundle(t *testing.T) {
	home, lock, client, broken := developmentViewerFixture(t)
	viewer, err := ensureDevelopmentViewer(context.Background(), home, lock, "arm64", client)
	if err != nil || !filepath.IsAbs(viewer.Scrcpy) || !filepath.IsAbs(viewer.ADB) || viewer.Version != "4.1" || !strings.HasPrefix(viewer.Scrcpy, viewer.OwnedRoot+string(filepath.Separator)) {
		t.Fatalf("private viewer: %+v %v", viewer, err)
	}
	broken.Store(true)
	if cached, err := ensureDevelopmentViewer(context.Background(), home, lock, "arm64", client); err != nil || cached != viewer {
		t.Fatalf("checked cache required a download: %+v %v", cached, err)
	}
	changed := lock
	changed.Artifacts = append([]DevelopmentArtifact{}, lock.Artifacts...)
	changed.Artifacts[0].SHA256 = strings.Repeat("b", 64)
	if _, err := ensureDevelopmentViewer(context.Background(), home, changed, "arm64", client); err == nil {
		t.Fatal("accepted corrupt replacement")
	}
	if data, err := os.ReadFile(viewer.Scrcpy); err != nil || string(data) != "tool" {
		t.Fatalf("failed replacement changed working viewer: %q %v", data, err)
	}
	os.WriteFile(viewer.Scrcpy, []byte("tampered"), 0700)
	if _, err := ensureDevelopmentViewer(context.Background(), home, lock, "arm64", client); err == nil {
		t.Fatal("trusted a tampered cached executable")
	}
}

func TestDevelopmentViewerRejectsRedirectsAndCancellation(t *testing.T) {
	home, lock, client, _ := developmentViewerFixture(t)
	outside := t.TempDir()
	os.Symlink(outside, filepath.Join(home, "tools"))
	if _, err := ensureDevelopmentViewer(context.Background(), home, lock, "arm64", client); err == nil {
		t.Fatal("accepted external tools redirect")
	}
	files, _ := os.ReadDir(outside)
	if len(files) != 0 {
		t.Fatal("wrote through an external tools symlink")
	}
	os.Remove(filepath.Join(home, "tools"))
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := ensureDevelopmentViewer(ctx, home, lock, "arm64", client); !errors.Is(err, context.Canceled) {
		t.Fatalf("lost cancellation: %v", err)
	}
}

func TestDevelopmentViewerAcceptsOnlyOwnedReleaseAlias(t *testing.T) {
	home, lock, client, _ := developmentViewerFixture(t)
	release := filepath.Join(home, "releases", "install.fixture")
	os.MkdirAll(filepath.Join(release, "tools"), 0700)
	manifest, _ := os.ReadFile(filepath.Join(home, ".install-manifest"))
	os.WriteFile(filepath.Join(release, ".molt-release"), manifest, 0600)
	os.Symlink("releases/install.fixture", filepath.Join(home, "current"))
	os.Symlink("current/tools", filepath.Join(home, "tools"))
	viewer, err := ensureDevelopmentViewer(context.Background(), home, lock, "arm64", client)
	if err != nil || !strings.HasPrefix(viewer.OwnedRoot, release+string(filepath.Separator)) {
		t.Fatalf("owned release alias: %+v %v", viewer, err)
	}
	os.Remove(filepath.Join(release, ".molt-release"))
	if _, err := ensureDevelopmentViewer(context.Background(), home, lock, "arm64", client); err == nil {
		t.Fatal("accepted a release without its ownership marker")
	}
	var output map[string]any
	if json.Unmarshal(developmentFixtureJSON(t, viewer), &output) != nil || output["owned_root"] != viewer.OwnedRoot {
		t.Fatal("viewer result does not follow the JSON ABI")
	}
}

func TestDevelopmentZIPRetainsExecutablesAndRejectsLinks(t *testing.T) {
	for _, mode := range []os.FileMode{0755, os.ModeSymlink | 0755} {
		var data bytebuf.Buffer
		writer := zip.NewWriter(&data)
		header := &zip.FileHeader{Name: "platform-tools/adb", Method: zip.Deflate}
		header.SetMode(mode)
		file, _ := writer.CreateHeader(header)
		file.Write([]byte("tool"))
		writer.Close()
		files, err := decodeDevelopmentArchive(data.Bytes(), true)
		if mode&os.ModeSymlink != 0 {
			if err == nil {
				t.Fatal("accepted ZIP symlink")
			}
		} else if err != nil || string(files["platform-tools/adb"].Data) != "tool" || files["platform-tools/adb"].Mode != 0700 {
			t.Fatalf("checked ZIP executable: %+v %v", files, err)
		}
	}
}

func TestDevelopmentViewerCancelsIncompleteDownload(t *testing.T) {
	home, lock, _, _ := developmentViewerFixture(t)
	started := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		w.(http.Flusher).Flush()
		close(started)
		<-r.Context().Done()
	}))
	defer server.Close()
	endpoint, _ := url.Parse(server.URL)
	client := &http.Client{Transport: releaseTransport{endpoint}}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := ensureDevelopmentViewer(ctx, home, lock, "arm64", client)
		done <- err
	}()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("download did not start")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("download did not preserve cancellation: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("cancelled download did not finish")
	}
	entries, _ := os.ReadDir(filepath.Join(home, "tools", "development"))
	for _, entry := range entries {
		if entry.Name() != ".lock" {
			t.Fatalf("cancelled acquisition published a bundle or staging directory: %s", entry.Name())
		}
	}
}

func TestDevelopmentViewerRejectsWritableCacheDirectories(t *testing.T) {
	home, lock, client, _ := developmentViewerFixture(t)
	viewer, err := ensureDevelopmentViewer(context.Background(), home, lock, "arm64", client)
	if err != nil {
		t.Fatal(err)
	}
	os.Mkdir(filepath.Join(viewer.OwnedRoot, "untrusted"), 0700)
	os.Chmod(filepath.Join(viewer.OwnedRoot, "untrusted"), 0777)
	if _, err := ensureDevelopmentViewer(context.Background(), home, lock, "arm64", client); err == nil {
		t.Fatal("accepted writable cache directory")
	}
}

func TestDevelopmentViewerRejectsAmbiguousInstallationMarker(t *testing.T) {
	home, lock, client, _ := developmentViewerFixture(t)
	marker := filepath.Join(home, ".install-manifest")
	data, _ := os.ReadFile(marker)
	os.WriteFile(marker, append([]byte("ROOT=\n"), data...), 0600)
	if _, err := ensureDevelopmentViewer(context.Background(), home, lock, "arm64", client); err == nil {
		t.Fatal("accepted duplicate ROOT with an empty first value")
	}
}

func TestDevelopmentOfficialMacArchivePlatforms(t *testing.T) {
	root := os.Getenv("MOLT_DEVELOPMENT_TEST_ARCHIVE_ROOT")
	if root == "" {
		t.Skip("supply the verified downloaded archives for the platform inspection")
	}
	for _, platform := range []struct {
		name string
		cpu  macho.Cpu
	}{
		{"aarch64", macho.CpuArm64}, {"x86_64", macho.CpuAmd64},
	} {
		data, err := os.ReadFile(filepath.Join(root, "scrcpy-macos-"+platform.name+"-v4.1.tar.gz"))
		if err != nil {
			t.Fatal(err)
		}
		files, err := decodeDevelopmentArchive(data, false)
		if err != nil {
			t.Fatal(err)
		}
		prefix := "scrcpy-macos-" + platform.name + "-v4.1/"
		if len(files[prefix+"scrcpy-server"].Data) == 0 {
			t.Fatal("official archive does not include the scrcpy server")
		}
		for _, name := range []string{"scrcpy", "adb"} {
			binary := files[prefix+name]
			if binary.Mode&0100 == 0 {
				t.Fatalf("official %s archive has no executable %s", platform.name, name)
			}
			file, err := macho.NewFile(bytebuf.NewReader(binary.Data))
			if err == nil {
				if file.Cpu != platform.cpu {
					t.Fatalf("wrong %s architecture in official %s archive", name, platform.name)
				}
				file.Close()
				continue
			}
			fat, err := macho.NewFatFile(bytebuf.NewReader(binary.Data))
			if err != nil {
				t.Fatal(err)
			}
			found := false
			for _, architecture := range fat.Arches {
				found = found || architecture.Cpu == platform.cpu
			}
			fat.Close()
			if !found {
				t.Fatalf("universal %s is missing %s", name, platform.name)
			}
		}
	}
}
