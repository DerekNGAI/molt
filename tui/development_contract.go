package main

import (
	bytebuf "bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

type DevelopmentSpec struct {
	Version int                 `json:"version"`
	Name    string              `json:"name"`
	Actions []DevelopmentAction `json:"actions"`
	Ports   []DevelopmentPort   `json:"ports"`
	Android DevelopmentAndroid  `json:"android"`
}

type DevelopmentAction struct {
	ID    string   `json:"id"`
	Label string   `json:"label"`
	Kind  string   `json:"kind"`
	Argv  []string `json:"argv"`
	Cwd   string   `json:"cwd"`
}

type DevelopmentPort struct {
	ID            string `json:"id"`
	Label         string `json:"label"`
	Service       string `json:"service"`
	ContainerPort int    `json:"container_port"`
	LocalPort     int    `json:"local_port"`
	Scheme        string `json:"scheme"`
}

type DevelopmentAndroid struct {
	Enabled bool `json:"enabled"`
}

type DevelopmentStatus struct {
	Version     int                          `json:"version"`
	ProjectID   string                       `json:"project_id"`
	Name        string                       `json:"name"`
	Environment DevelopmentEnvironmentStatus `json:"environment"`
	Services    []DevelopmentServiceStatus   `json:"services"`
	Ports       []DevelopmentForwardStatus   `json:"ports"`
	Android     DevelopmentAndroidStatus     `json:"android"`
	Cache       DevelopmentCacheStatus       `json:"cache"`
	Cleanup     DevelopmentCleanupStatus     `json:"cleanup"`
}

type DevelopmentEnvironmentStatus struct {
	State    string `json:"state"`
	Revision string `json:"revision"`
	Reason   string `json:"reason"`
}

type DevelopmentServiceStatus struct {
	ID     string `json:"id"`
	Label  string `json:"label"`
	State  string `json:"state"`
	Reason string `json:"reason"`
}

type DevelopmentForwardStatus struct {
	ID            string `json:"id"`
	Label         string `json:"label"`
	Service       string `json:"service"`
	ContainerPort int    `json:"container_port"`
	VMPort        int    `json:"vm_port"`
	LocalPort     int    `json:"local_port"`
	Scheme        string `json:"scheme"`
	URL           string `json:"url"`
	State         string `json:"state"`
	Reason        string `json:"reason"`
}

type DevelopmentAndroidStatus struct {
	Enabled            bool   `json:"enabled"`
	State              string `json:"state"`
	Reason             string `json:"reason"`
	Container          string `json:"container"`
	ADBVMPort          int    `json:"adb_vm_port"`
	ADBLocalPort       int    `json:"adb_local_port"`
	ADBServerLocalPort int    `json:"adb_server_local_port"`
	ViewerState        string `json:"viewer_state"`
}

type DevelopmentCacheStatus struct {
	ReclaimableBytes int64  `json:"reclaimable_bytes"`
	Reason           string `json:"reason"`
}

type DevelopmentCleanupStatus struct {
	State     string   `json:"state"`
	Remaining []string `json:"remaining"`
	Reason    string   `json:"reason"`
}

type DevelopmentCachePreview struct {
	Version          int                    `json:"version"`
	ProjectID        string                 `json:"project_id"`
	Revision         string                 `json:"revision"`
	ReclaimableBytes int64                  `json:"reclaimable_bytes"`
	Items            []DevelopmentCacheItem `json:"items"`
	Reason           string                 `json:"reason"`
}

type DevelopmentCacheItem struct {
	ID    string `json:"id"`
	Kind  string `json:"kind"`
	Path  string `json:"path"`
	Bytes int64  `json:"bytes"`
}

var developmentIDPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)
var developmentProjectPattern = regexp.MustCompile(`^[a-f0-9]{12}$`)

// The declared argv limits can occupy 48 MiB when JSON escapes each byte.
const developmentJSONLimit = 64 << 20

var developmentArrayLimits = map[string]int{"actions": 32, "services": 32, "ports": 16, "argv": 64, "artifacts": 32, "items": 4096}

func developmentText(value string, maximum int, empty bool) bool {
	if !utf8.ValidString(value) || utf8.RuneCountInString(value) > maximum || !empty && strings.TrimSpace(value) == "" {
		return false
	}
	for _, r := range value {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

// Decode tokens against the declared fields so duplicate, case-folded, and null fields cannot bypass validation.
func developmentJSONValue(decoder *json.Decoder, typ reflect.Type, depth, arrayLimit int) error {
	if depth > 16 {
		return errors.New("development JSON is too deeply nested")
	}
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	if token == nil {
		return errors.New("development JSON cannot contain null")
	}
	switch token {
	case json.Delim('{'):
		if typ.Kind() != reflect.Struct {
			return errors.New("unexpected development JSON object")
		}
		fields := map[string]reflect.Type{}
		for i := 0; i < typ.NumField(); i++ {
			field := typ.Field(i)
			fields[strings.Split(field.Tag.Get("json"), ",")[0]] = field.Type
		}
		seen := map[string]bool{}
		for decoder.More() {
			key, err := decoder.Token()
			if err != nil {
				return err
			}
			name, ok := key.(string)
			field, exists := fields[name]
			if !ok || !exists || seen[name] {
				return fmt.Errorf("unknown or duplicate development field %q", name)
			}
			seen[name] = true
			if err := developmentJSONValue(decoder, field, depth+1, developmentArrayLimits[name]); err != nil {
				return err
			}
		}
		_, err = decoder.Token()
	case json.Delim('['):
		if typ.Kind() != reflect.Slice {
			return errors.New("unexpected development JSON array")
		}
		for count := 0; decoder.More(); count++ {
			if arrayLimit != 0 && count >= arrayLimit {
				return errors.New("development JSON array exceeds its declared limit")
			}
			if err := developmentJSONValue(decoder, typ.Elem(), depth+1, 0); err != nil {
				return err
			}
		}
		_, err = decoder.Token()
	}
	return err
}

func decodeDevelopmentJSON(data []byte, target any) error {
	if len(data) > developmentJSONLimit || !utf8.Valid(data) {
		return errors.New("development JSON is too large or is not UTF-8")
	}
	decoder := json.NewDecoder(bytebuf.NewReader(data))
	decoder.UseNumber()
	if err := developmentJSONValue(decoder, reflect.TypeOf(target).Elem(), 0, 0); err != nil {
		return err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return errors.New("development JSON contains trailing data")
	}
	return json.Unmarshal(data, target)
}

func decodeDevelopmentSpec(data []byte) (DevelopmentSpec, error) {
	var spec DevelopmentSpec
	if err := decodeDevelopmentJSON(data, &spec); err != nil {
		return spec, err
	}
	if spec.Version != 1 || !developmentText(spec.Name, 80, false) || len(spec.Actions) > 32 || len(spec.Ports) > 16 {
		return spec, errors.New("invalid development profile version, name, or entry count")
	}
	if spec.Actions == nil {
		spec.Actions = []DevelopmentAction{}
	}
	if spec.Ports == nil {
		spec.Ports = []DevelopmentPort{}
	}
	actions := map[string]string{}
	for i := range spec.Actions {
		action := &spec.Actions[i]
		if !developmentIDPattern.MatchString(action.ID) || actions[action.ID] != "" || !developmentText(action.Label, 80, false) || action.Kind != "task" && action.Kind != "service" {
			return spec, fmt.Errorf("invalid or duplicate development action %q", action.ID)
		}
		if len(action.Argv) == 0 || len(action.Argv) > 64 {
			return spec, fmt.Errorf("action %q needs 1–64 argv elements", action.ID)
		}
		for _, arg := range action.Argv {
			if len(arg) == 0 || len(arg) > 4096 || strings.ContainsAny(arg, "\x00\r\n") {
				return spec, fmt.Errorf("invalid argv in action %q", action.ID)
			}
		}
		if action.Cwd == "" {
			action.Cwd = "."
		}
		if !developmentText(action.Cwd, 4096, false) || filepath.IsAbs(action.Cwd) {
			return spec, fmt.Errorf("invalid cwd in action %q", action.ID)
		}
		action.Cwd = filepath.Clean(action.Cwd)
		if action.Cwd == ".." || strings.HasPrefix(action.Cwd, ".."+string(filepath.Separator)) {
			return spec, fmt.Errorf("cwd escapes repository in action %q", action.ID)
		}
		actions[action.ID] = action.Kind
	}
	ids, ports := map[string]bool{}, map[int]bool{}
	for _, port := range spec.Ports {
		if !developmentIDPattern.MatchString(port.ID) || ids[port.ID] || !developmentText(port.Label, 80, false) || actions[port.Service] != "service" || port.ContainerPort < 1 || port.ContainerPort > 65535 || port.ContainerPort == 4096 || ports[port.ContainerPort] || port.LocalPort < 1024 || port.LocalPort > 65535 || port.Scheme != "http" && port.Scheme != "https" {
			return spec, fmt.Errorf("invalid or duplicate development port %q", port.ID)
		}
		ids[port.ID], ports[port.ContainerPort] = true, true
	}
	return spec, nil
}

func canonicalDevelopmentPath(name string) error {
	if !filepath.IsAbs(name) || filepath.Clean(name) != name || !developmentText(name, 4096, false) {
		return errors.New("development path must be a clean absolute path")
	}
	resolved, err := filepath.EvalSymlinks(name)
	if err != nil {
		return err
	}
	if resolved != name {
		return fmt.Errorf("redirected development path: %s", name)
	}
	return nil
}

func readDevelopmentSpec(profilePath, repoRoot string) (DevelopmentSpec, error) {
	var spec DevelopmentSpec
	if err := canonicalDevelopmentPath(repoRoot); err != nil {
		return spec, err
	}
	if err := canonicalDevelopmentPath(profilePath); err != nil {
		return spec, err
	}
	relative, err := filepath.Rel(repoRoot, profilePath)
	if err != nil || !filepath.IsLocal(relative) {
		return spec, errors.New("development profile is outside the repository")
	}
	root, err := os.OpenRoot(repoRoot)
	if err != nil {
		return spec, err
	}
	defer root.Close()
	file, err := root.Open(relative)
	if err != nil {
		return spec, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return spec, errors.New("development profile must be a regular file")
	}
	data, err := io.ReadAll(io.LimitReader(file, developmentJSONLimit+1))
	if err != nil {
		return spec, err
	}
	spec, err = decodeDevelopmentSpec(data)
	if err != nil {
		return spec, err
	}
	for _, action := range spec.Actions {
		info, err := root.Stat(action.Cwd)
		if err != nil || !info.IsDir() {
			return spec, fmt.Errorf("action %q cwd is unavailable or escapes the repository", action.ID)
		}
	}
	return spec, nil
}

func decodeDevelopmentStatus(data []byte) (DevelopmentStatus, error) {
	var status DevelopmentStatus
	if err := decodeDevelopmentJSON(data, &status); err != nil {
		return status, err
	}
	if status.Version != 1 || !developmentProjectPattern.MatchString(status.ProjectID) || !developmentText(status.Name, 80, false) || len(status.Services) > 32 || len(status.Ports) > 16 {
		return status, errors.New("invalid development status identity or entry count")
	}
	if !developmentEnum(status.Environment.State, "absent", "preparing", "ready", "blocked", "failed", "unknown") || !developmentRevision(status.Environment.Revision) || !developmentText(status.Environment.Reason, 4096, true) {
		return status, errors.New("invalid development environment status")
	}
	services := map[string]bool{}
	if status.Services == nil {
		status.Services = []DevelopmentServiceStatus{}
	}
	if status.Ports == nil {
		status.Ports = []DevelopmentForwardStatus{}
	}
	for _, service := range status.Services {
		if !developmentIDPattern.MatchString(service.ID) || services[service.ID] || !developmentText(service.Label, 80, false) || !developmentText(service.Reason, 4096, true) || !developmentEnum(service.State, "stopped", "starting", "running", "failed", "unknown") {
			return status, fmt.Errorf("invalid development service status %q", service.ID)
		}
		services[service.ID] = true
	}
	ids, ports := map[string]bool{}, map[int]bool{}
	for _, port := range status.Ports {
		if !developmentIDPattern.MatchString(port.ID) || ids[port.ID] || !developmentText(port.Label, 80, false) || !services[port.Service] || port.ContainerPort < 1 || port.ContainerPort > 65535 || port.ContainerPort == 4096 || ports[port.ContainerPort] || !developmentAllocatedPort(port.VMPort) || !developmentLocalPort(port.LocalPort) || !developmentEnum(port.Scheme, "http", "https") || !developmentEnum(port.State, "inactive", "forwarded", "failed", "unknown") || !developmentText(port.Reason, 4096, true) {
			return status, fmt.Errorf("invalid development forward status %q", port.ID)
		}
		if port.State == "forwarded" {
			endpoint, err := url.Parse(port.URL)
			if err != nil || endpoint.User != nil || endpoint.Scheme != port.Scheme || !net.ParseIP(endpoint.Hostname()).IsLoopback() || endpoint.Port() != strconv.Itoa(port.LocalPort) || port.LocalPort == 0 || port.VMPort == 0 || !developmentText(port.URL, 4096, false) {
				return status, fmt.Errorf("invalid loopback URL for development port %q", port.ID)
			}
		} else if port.URL != "" {
			return status, fmt.Errorf("non-forwarded development port %q has a URL", port.ID)
		}
		ids[port.ID], ports[port.ContainerPort] = true, true
	}
	android := status.Android
	if !developmentEnum(android.State, "disabled", "unsupported", "stopped", "starting", "ready", "failed", "unknown") || !developmentEnum(android.ViewerState, "closed", "running", "failed", "unknown") || !developmentText(android.Reason, 4096, true) || !developmentText(android.Container, 256, true) || !developmentAllocatedPort(android.ADBVMPort) || !developmentLocalPort(android.ADBLocalPort) || !developmentLocalPort(android.ADBServerLocalPort) || android.Enabled && android.State == "disabled" || !android.Enabled && developmentEnum(android.State, "starting", "ready") {
		return status, errors.New("invalid development Android status")
	}
	if status.Cache.ReclaimableBytes < 0 || !developmentText(status.Cache.Reason, 4096, true) || !developmentEnum(status.Cleanup.State, "clean", "pending", "failed") || !developmentText(status.Cleanup.Reason, 4096, true) || status.Cleanup.State == "clean" && len(status.Cleanup.Remaining) != 0 {
		return status, errors.New("invalid development cache or cleanup status")
	}
	if status.Cleanup.Remaining == nil {
		status.Cleanup.Remaining = []string{}
	}
	for _, item := range status.Cleanup.Remaining {
		if !developmentText(item, 4096, false) {
			return status, errors.New("invalid development cleanup resource")
		}
	}
	return status, nil
}

func decodeDevelopmentCachePreview(data []byte) (DevelopmentCachePreview, error) {
	var preview DevelopmentCachePreview
	if err := decodeDevelopmentJSON(data, &preview); err != nil {
		return preview, err
	}
	if preview.Version != 1 || !developmentProjectPattern.MatchString(preview.ProjectID) || !developmentRevision(preview.Revision) || preview.ReclaimableBytes < 0 || !developmentText(preview.Reason, 4096, true) || len(preview.Items) > 4096 || preview.Revision == "" && len(preview.Items) != 0 {
		return preview, errors.New("invalid development cache preview")
	}
	if preview.Items == nil {
		preview.Items = []DevelopmentCacheItem{}
	}
	ids, paths, total := map[string]bool{}, map[string]bool{}, int64(0)
	for _, item := range preview.Items {
		if !developmentIDPattern.MatchString(item.ID) || ids[item.ID] || paths[item.Path] || !developmentEnum(item.Kind, "build-output", "image", "nix-root") || !developmentText(item.Path, 4096, false) || item.Bytes < 0 || item.Bytes > math.MaxInt64-total {
			return preview, fmt.Errorf("invalid development cache item %q", item.ID)
		}
		if item.Kind == "image" {
			if !developmentImagePattern.MatchString(item.Path) {
				return preview, errors.New("invalid development cache image reference")
			}
		} else if !filepath.IsAbs(item.Path) || filepath.Clean(item.Path) != item.Path || item.Path == string(filepath.Separator) {
			return preview, errors.New("invalid development cache path")
		}
		ids[item.ID], paths[item.Path] = true, true
		total += item.Bytes
	}
	if total != preview.ReclaimableBytes {
		return preview, errors.New("development cache byte total does not match its inventory")
	}
	sort.Slice(preview.Items, func(i, j int) bool { return preview.Items[i].ID < preview.Items[j].ID })
	return preview, nil
}

var developmentImagePattern = regexp.MustCompile(`^(sha256:[a-f0-9]{64}|[a-z0-9][a-z0-9._:/-]*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}|@sha256:[a-f0-9]{64}))$`)

func developmentRevision(value string) bool {
	return value == "" || opencodeDigestPattern.MatchString(value)
}

func developmentAllocatedPort(value int) bool {
	return value >= 0 && value <= 65535
}

func developmentLocalPort(value int) bool {
	return value == 0 || value >= 1024 && value <= 65535
}

func developmentEnum(value string, allowed ...string) bool {
	for _, candidate := range allowed {
		if value == candidate {
			return true
		}
	}
	return false
}
