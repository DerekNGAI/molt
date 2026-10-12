package main

import (
	"archive/tar"
	"archive/zip"
	bytebuf "bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
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

type releaseTransport struct{ endpoint *url.URL }

func (r releaseTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	copy := req.Clone(req.Context())
	copy.URL.Scheme, copy.URL.Host = r.endpoint.Scheme, r.endpoint.Host
	return http.DefaultTransport.RoundTrip(copy)
}

func opencodeArchive(t *testing.T, asset, version string) []byte {
	t.Helper()
	var out bytebuf.Buffer
	contents := []byte("#!/bin/sh\nprintf '" + version + "\\n'\n")
	if strings.HasSuffix(asset, ".zip") {
		writer := zip.NewWriter(&out)
		header := &zip.FileHeader{Name: "opencode"}
		header.SetMode(0755)
		file, _ := writer.CreateHeader(header)
		file.Write(contents)
		writer.Close()
	} else {
		compressed := gzip.NewWriter(&out)
		writer := tar.NewWriter(compressed)
		writer.WriteHeader(&tar.Header{Name: "opencode", Mode: 0755, Size: int64(len(contents))})
		writer.Write(contents)
		writer.Close()
		compressed.Close()
	}
	return out.Bytes()
}

func releaseFixture(t *testing.T) (*opencodeTools, *atomic.Int32, *atomic.Bool) {
	t.Helper()
	home := t.TempDir()
	lock := filepath.Join(home, "tools.lock")
	var lines []string
	for _, name := range opencodeAssets {
		digest := sha256.Sum256(opencodeArchive(t, name, "1.18.34"))
		lines = append(lines, hex.EncodeToString(digest[:])+" "+name)
	}
	lines = append(lines, strings.Repeat("b", 64)+" node-v24.21.0-linux-arm64.tar.gz")
	os.WriteFile(lock, []byte(strings.Join(lines, "\n")+"\n"), 0600)
	var requests atomic.Int32
	var broken atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "/releases/latest") || strings.Contains(r.URL.Path, "/releases/tags/") {
			requests.Add(1)
			if broken.Load() {
				w.WriteHeader(503)
				return
			}
			version := "1.19.0"
			if strings.Contains(r.URL.Path, "/tags/") {
				version = strings.TrimPrefix(filepath.Base(r.URL.Path), "v")
			}
			var assets []map[string]string
			for _, name := range opencodeAssets {
				digest := sha256.Sum256(opencodeArchive(t, name, version))
				assets = append(assets, map[string]string{"name": name, "digest": "sha256:" + hex.EncodeToString(digest[:])})
			}
			json.NewEncoder(w).Encode(map[string]any{"tag_name": "v" + version, "assets": assets})
			return
		}
		if broken.Load() {
			fmt.Fprint(w, "corrupted download")
			return
		}
		parts := strings.Split(r.URL.Path, "/")
		version := strings.TrimPrefix(parts[len(parts)-2], "v")
		w.Write(opencodeArchive(t, parts[len(parts)-1], version))
	}))
	t.Cleanup(server.Close)
	endpoint, _ := url.Parse(server.URL)
	return &opencodeTools{home: home, lockFile: lock, client: &http.Client{Transport: releaseTransport{endpoint}, Timeout: 5 * time.Second}}, &requests, &broken
}

func TestOpenCodeReleaseCachesChecksAndKeepsWorkingReleaseOffline(t *testing.T) {
	tools, requests, broken := releaseFixture(t)
	ctx := context.Background()
	release, err := tools.latest(ctx, false)
	if err != nil || release.Version != "1.19.0" {
		t.Fatalf("latest stable: %+v %v", release, err)
	}
	broken.Store(true)
	if release, err = tools.latest(ctx, false); err != nil || release.Version != "1.19.0" || requests.Load() != 1 {
		t.Fatalf("cached check used network: %+v %v requests=%d", release, err, requests.Load())
	}
	if release, err = tools.latest(ctx, true); err == nil || release.Version != "1.19.0" {
		t.Fatalf("failed refresh lost known release or hid failure: %+v %v", release, err)
	}
	if release, err = tools.latest(ctx, false); err != nil || release.Version != "1.19.0" || requests.Load() != 2 {
		t.Fatalf("offline launches repeatedly checked network: %+v %v requests=%d", release, err, requests.Load())
	}
}

func TestOpenCodeReleaseValidatesCompleteStableMetadata(t *testing.T) {
	tools, _, _ := releaseFixture(t)
	base, err := tools.release(context.Background(), "1.19.0")
	if err != nil {
		t.Fatal(err)
	}
	assets := []map[string]string{}
	for name, digest := range base.Assets {
		assets = append(assets, map[string]string{"name": name, "digest": "sha256:" + digest})
	}
	for _, test := range []struct {
		name string
		data map[string]any
	}{
		{"prerelease", map[string]any{"tag_name": "v1.19.1", "prerelease": true, "assets": assets}},
		{"unsafe version", map[string]any{"tag_name": "v../../outside", "assets": assets}},
		{"missing checksum", map[string]any{"tag_name": "v1.19.1", "assets": []map[string]string{{"name": opencodeAssets[0]}}}},
		{"duplicate asset", map[string]any{"tag_name": "v1.19.1", "assets": append(append([]map[string]string{}, assets...), assets[0])}},
	} {
		t.Run(test.name, func(t *testing.T) {
			data, _ := json.Marshal(test.data)
			if _, err := parseOpenCodeRelease(data); err == nil {
				t.Fatal("accepted unusable release metadata")
			}
		})
	}
}

func TestOpenCodeClientVersionsAndChecksumFailure(t *testing.T) {
	tools, _, broken := releaseFixture(t)
	ctx := context.Background()
	first, err := tools.ensureClient(ctx, "1.18.34", "")
	if err != nil {
		t.Fatal(err)
	}
	second, err := tools.ensureClient(ctx, "1.19.0", "")
	if err != nil || first == second {
		t.Fatalf("client versions were overwritten: %q %q %v", first, second, err)
	}
	tools.release(ctx, "1.19.1")
	broken.Store(true)
	if _, err := tools.ensureClient(ctx, "1.19.1", ""); err == nil {
		t.Fatal("accepted a corrupt archive")
	}
	if got, err := tools.ensureClient(ctx, "1.18.34", ""); err != nil || got != first {
		t.Fatalf("download failure damaged previous client: %q %v", got, err)
	}
	data, _ := os.ReadFile(first)
	if !strings.Contains(string(data), "1.18.34") {
		t.Fatal("old client changed")
	}
}

func TestOpenCodeToolsRejectRedirectedState(t *testing.T) {
	tools, _, _ := releaseFixture(t)
	outside := t.TempDir()
	os.Mkdir(filepath.Join(tools.home, "state"), 0700)
	os.Symlink(outside, filepath.Join(tools.home, "state", "opencode"))
	if _, err := tools.latest(context.Background(), false); err == nil {
		t.Fatal("wrote release state through a symlink")
	}
	files, _ := os.ReadDir(outside)
	if len(files) != 0 {
		t.Fatal("changed external directory")
	}
}

func TestOpenCodeServerChecksSubdirectoriesAndPagination(t *testing.T) {
	var busy atomic.Bool
	busy.Store(true)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if user, pass, ok := r.BasicAuth(); !ok || user != "opencode" || pass != "fixture" {
			t.Error("probe lost authentication")
			w.WriteHeader(401)
			return
		}
		switch r.URL.Path {
		case "/global/health":
			fmt.Fprint(w, `{"healthy":true,"version":"1.18.34"}`)
		case "/experimental/session":
			if r.URL.Query().Get("cursor") == "" {
				w.Header().Set("x-next-cursor", "123")
				fmt.Fprint(w, `[{"directory":"/workspace"}]`)
			} else {
				fmt.Fprint(w, `[{"directory":"/workspace/src"}]`)
			}
		case "/session/status":
			if r.URL.Query().Get("directory") == "/workspace/src" && busy.Load() {
				fmt.Fprint(w, `{"ses_child":{"type":"busy"}}`)
			} else {
				fmt.Fprint(w, `{}`)
			}
		default:
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	version, idle, err := probeOpenCodeServer(context.Background(), server.Client(), server.URL, "opencode", "fixture")
	if err != nil || idle || version != "1.18.34" {
		t.Fatalf("missed work in a subdirectory: %q idle=%v %v", version, idle, err)
	}
	busy.Store(false)
	version, idle, err = probeOpenCodeServer(context.Background(), server.Client(), server.URL, "opencode", "fixture")
	if err != nil || !idle || version != "1.18.34" {
		t.Fatalf("idle server blocked update: %q idle=%v %v", version, idle, err)
	}
}

func TestOpenCodeServerUnknownStatusCannotAuthorizeUpdate(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/global/health" {
			fmt.Fprint(w, `{"healthy":true,"version":"1.18.34"}`)
			return
		}
		w.WriteHeader(503)
	}))
	defer server.Close()
	version, idle, err := probeOpenCodeServer(context.Background(), server.Client(), server.URL, "opencode", "fixture")
	if err == nil || idle || version != "1.18.34" {
		t.Fatalf("unknown activity allowed a restart: %q idle=%v %v", version, idle, err)
	}
}

func TestOpenCodeServerPaginationKeepsEqualTimestampSessions(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/global/health":
			fmt.Fprint(w, `{"healthy":true,"version":"1.18.34"}`)
		case "/experimental/session":
			if r.URL.Query().Get("cursor") == "123" {
				fmt.Fprint(w, `[]`)
				return
			}
			if r.URL.Query().Get("limit") == "200" {
				w.Header().Set("x-next-cursor", "123")
				fmt.Fprint(w, `[{"directory":"/workspace"}]`)
			} else {
				fmt.Fprint(w, `[{"directory":"/workspace"},{"directory":"/workspace/src"}]`)
			}
		case "/session/status":
			if r.URL.Query().Get("directory") == "/workspace/src" {
				fmt.Fprint(w, `{"ses_tied_timestamp":{"type":"busy"}}`)
			} else {
				fmt.Fprint(w, `{}`)
			}
		}
	}))
	defer server.Close()
	_, idle, err := probeOpenCodeServer(context.Background(), server.Client(), server.URL, "opencode", "fixture")
	if err != nil || idle {
		t.Fatalf("timestamp pagination skipped active work: idle=%v %v", idle, err)
	}
}
