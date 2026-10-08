package main

import (
	"strings"
	"testing"
)

func TestTelemetryDoesNotMistakeSavedActiveForRunning(t *testing.T) {
	h, err := parseRemote("vm", []byte("system\t1000\t700\t8192\t4096\t100000\t30000\t3600\t1.2 0.8 0.5\t2048\t4096\tAMD EPYC\ncontainer\t{\"Names\":\"molt-app\",\"State\":\"exited\",\"Status\":\"Exited (1)\"}\ndocker\tready\n"))
	if err != nil {
		t.Fatal(err)
	}
	p := project{Container: "molt-app", Active: true}
	if got := p.runtime(h); got != "exited" {
		t.Fatalf("container exited but dashboard says %q", got)
	}
	h.Error = "SSH unavailable"
	if got := p.runtime(h); got != "unknown" {
		t.Fatalf("unreachable VM reported %q", got)
	}
	if _, err := parseRemote("vm", []byte("container\t{broken}\n")); err == nil {
		t.Fatal("malformed telemetry appeared healthy")
	}
}

func TestSynchronizationReportsConflictsAndRealTransfer(t *testing.T) {
	input := `[{"name":"app","status":"watching","alpha":{"connected":true},"beta":{"connected":true},"conflicts":[{}]},{"name":"transfer","status":"staging-beta","alpha":{"connected":true},"beta":{"connected":true,"stagingProgress":{"receivedSize":1048576,"totalSize":2097152}}},{"name":"paused","paused":true}]`
	s, err := parseSync([]byte(input))
	if err != nil {
		t.Fatal(err)
	}
	if got := s["app"].label(); got != "conflict" {
		t.Fatal(got)
	}
	if got := s["transfer"].label(); got != "transferring" {
		t.Fatal(got)
	}
	if got := s["paused"].label(); got != "paused" {
		t.Fatal(got)
	}
	if _, err := parseSync([]byte("not JSON")); err == nil {
		t.Fatal("invalid sync data silently accepted")
	}
}

func TestTerminalInputCannotInjectEscapeSequences(t *testing.T) {
	got := clean("safe\x1b[2J\x1b]52;c;secret\a\rname")
	if strings.ContainsAny(got, "\x1b\a\r") || !strings.Contains(got, "safe") {
		t.Fatalf("unsafe terminal text %q", got)
	}
}
