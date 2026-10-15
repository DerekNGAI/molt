package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func developmentFixtureJSON(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestDevelopmentStatusValidatesObservedLoopbackMappings(t *testing.T) {
	status := DevelopmentStatus{Version: 1, ProjectID: "012345abcdef", Name: "Example",
		Environment: DevelopmentEnvironmentStatus{State: "ready", Revision: strings.Repeat("a", 64)},
		Services:    []DevelopmentServiceStatus{{ID: "dev", Label: "Development", State: "running"}},
		Ports:       []DevelopmentForwardStatus{{ID: "web", Label: "Web", Service: "dev", ContainerPort: 3000, VMPort: 33000, LocalPort: 3001, Scheme: "http", URL: "http://127.0.0.1:3001", State: "forwarded"}},
		Android:     DevelopmentAndroidStatus{State: "disabled", ViewerState: "closed"}, Cleanup: DevelopmentCleanupStatus{State: "clean", Remaining: []string{}}}
	decoded, err := decodeDevelopmentStatus(developmentFixtureJSON(t, status))
	if err != nil || decoded.Ports[0].LocalPort != 3001 || decoded.Cleanup.Remaining == nil {
		t.Fatalf("valid observed mapping: %+v %v", decoded, err)
	}
	lowVM := status
	lowVM.Ports = append([]DevelopmentForwardStatus{}, status.Ports...)
	lowVM.Ports[0].VMPort = 80
	if _, err := decodeDevelopmentStatus(developmentFixtureJSON(t, lowVM)); err != nil {
		t.Fatalf("VM ports do not have the Mac's local-port minimum: %v", err)
	}
	for _, test := range []struct {
		name string
		edit func(*DevelopmentStatus)
	}{
		{"remote URL", func(s *DevelopmentStatus) { s.Ports[0].URL = "http://example.com:3001" }},
		{"hostname URL", func(s *DevelopmentStatus) { s.Ports[0].URL = "http://localhost:3001" }},
		{"wrong URL port", func(s *DevelopmentStatus) { s.Ports[0].URL = "http://127.0.0.1:3000" }},
		{"URL credentials", func(s *DevelopmentStatus) { s.Ports[0].URL = "http://user:secret@127.0.0.1:3001" }},
		{"inactive URL", func(s *DevelopmentStatus) { s.Ports[0].State = "inactive" }},
		{"missing VM mapping", func(s *DevelopmentStatus) { s.Ports[0].VMPort = 0 }},
		{"privileged local mapping", func(s *DevelopmentStatus) { s.Ports[0].LocalPort = 80; s.Ports[0].URL = "http://127.0.0.1:80" }},
		{"foreign service", func(s *DevelopmentStatus) { s.Ports[0].Service = "other" }},
		{"control text", func(s *DevelopmentStatus) { s.Environment.Reason = "\x1b[31m" }},
		{"unknown state", func(s *DevelopmentStatus) { s.Environment.State = "healthy" }},
		{"negative cache", func(s *DevelopmentStatus) { s.Cache.ReclaimableBytes = -1 }},
		{"bad project", func(s *DevelopmentStatus) { s.ProjectID = "../project" }},
	} {
		t.Run(test.name, func(t *testing.T) {
			candidate := status
			candidate.Ports = append([]DevelopmentForwardStatus{}, status.Ports...)
			test.edit(&candidate)
			if _, err := decodeDevelopmentStatus(developmentFixtureJSON(t, candidate)); err == nil {
				t.Fatal("accepted unsafe observed status")
			}
		})
	}
}

func TestDevelopmentCachePreviewRejectsAmbiguousDeletionInventory(t *testing.T) {
	preview := DevelopmentCachePreview{Version: 1, ProjectID: "012345abcdef", Revision: strings.Repeat("b", 64), ReclaimableBytes: 10,
		Items: []DevelopmentCacheItem{{ID: "build", Kind: "build-output", Path: "/owned/cache/build", Bytes: 10}}}
	if _, err := decodeDevelopmentCachePreview(developmentFixtureJSON(t, preview)); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name string
		edit func(*DevelopmentCachePreview)
	}{
		{"escaped path", func(p *DevelopmentCachePreview) { p.Items[0].Path = "/owned/../foreign" }},
		{"root path", func(p *DevelopmentCachePreview) { p.Items[0].Path = "/" }},
		{"relative path", func(p *DevelopmentCachePreview) { p.Items[0].Path = "cache/build" }},
		{"persistent kind", func(p *DevelopmentCachePreview) { p.Items[0].Kind = "android-data" }},
		{"negative item", func(p *DevelopmentCachePreview) { p.Items[0].Bytes = -1 }},
		{"wrong total", func(p *DevelopmentCachePreview) { p.ReclaimableBytes = 11 }},
		{"duplicate item", func(p *DevelopmentCachePreview) { p.Items = append(p.Items, p.Items[0]); p.ReclaimableBytes = 20 }},
		{"no revision", func(p *DevelopmentCachePreview) { p.Revision = "" }},
		{"overflow", func(p *DevelopmentCachePreview) {
			p.Items[0].Bytes = math.MaxInt64
			p.Items = append(p.Items, DevelopmentCacheItem{ID: "next", Kind: "nix-root", Path: "/owned/next", Bytes: 1})
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			candidate := preview
			candidate.Items = append([]DevelopmentCacheItem{}, preview.Items...)
			test.edit(&candidate)
			if _, err := decodeDevelopmentCachePreview(developmentFixtureJSON(t, candidate)); err == nil {
				t.Fatal("accepted unsafe cache preview")
			}
		})
	}
}

func TestDevelopmentSpecLoadsOnlyContainedProfileAndCwd(t *testing.T) {
	repo, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	os.Mkdir(filepath.Join(repo, ".molt"), 0700)
	path := filepath.Join(repo, ".molt", "development.json")
	profile := `{"version":1,"name":"Example","actions":[{"id":"test","label":"Test","kind":"task","argv":["printf","$(literal)"]}]}`
	os.WriteFile(path, []byte(profile), 0600)
	if spec, err := readDevelopmentSpec(path, repo); err != nil || spec.Actions[0].Argv[1] != "$(literal)" {
		t.Fatalf("contained profile: %+v %v", spec, err)
	}
	outside, _ := filepath.EvalSymlinks(t.TempDir())
	os.Symlink(outside, filepath.Join(repo, "redirect"))
	os.WriteFile(path, []byte(strings.Replace(profile, `"argv":`, `"cwd":"redirect","argv":`, 1)), 0600)
	if _, err := readDevelopmentSpec(path, repo); err == nil {
		t.Fatal("accepted escaping cwd")
	}
	os.Remove(path)
	os.WriteFile(filepath.Join(outside, "profile.json"), []byte(profile), 0600)
	os.Symlink(filepath.Join(outside, "profile.json"), path)
	if _, err := readDevelopmentSpec(path, repo); err == nil {
		t.Fatal("accepted redirected profile")
	}
}

func TestDevelopmentSpecAllowsDeclaredCombinedLimits(t *testing.T) {
	spec := DevelopmentSpec{Version: 1, Name: "Maximum declared arguments", Actions: []DevelopmentAction{}, Ports: []DevelopmentPort{}}
	for i := 0; i < 32; i++ {
		action := DevelopmentAction{ID: fmt.Sprintf("action-%d", i), Label: "Test", Kind: "task", Cwd: ".", Argv: []string{}}
		for j := 0; j < 64; j++ {
			action.Argv = append(action.Argv, strings.Repeat("x", 4096))
		}
		spec.Actions = append(spec.Actions, action)
	}
	data := developmentFixtureJSON(t, spec)
	if _, err := decodeDevelopmentSpec(data); err != nil {
		t.Fatalf("rejected valid combined v1 limits: %v", err)
	}
	repo, _ := filepath.EvalSymlinks(t.TempDir())
	os.Mkdir(filepath.Join(repo, ".molt"), 0700)
	profile := filepath.Join(repo, ".molt", "development.json")
	os.WriteFile(profile, data, 0600)
	if _, err := readDevelopmentSpec(profile, repo); err != nil {
		t.Fatalf("filesystem loader rejected valid combined v1 limits: %v", err)
	}
	spec.Actions = append(spec.Actions, DevelopmentAction{ID: "overflow", Label: "Too many", Kind: "task", Cwd: ".", Argv: []string{"node"}})
	if _, err := decodeDevelopmentSpec(developmentFixtureJSON(t, spec)); err == nil {
		t.Fatal("accepted more than 32 actions")
	}
}
