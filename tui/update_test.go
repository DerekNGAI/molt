package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

func TestUpdateConfirmationAndRestart(t *testing.T) {
	home := t.TempDir()
	cli := filepath.Join(home, "molt")
	if err := os.WriteFile(cli, []byte("#!/bin/sh\nprintf 'updated source installed\\n'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	m := newModel(backend{Home: home, CLI: cli, Context: ctx})
	defer func() { m.collectorCancel() }()
	m.maintenanceMenu()
	found := false
	for _, item := range m.menu.Items {
		if item.Title == "Update MOLT" {
			item.Run()
			found = true
			break
		}
	}
	if !found || m.overlay != "confirm" || m.action != "" {
		t.Fatal("update did not require confirmation")
	}
	m.key(tea.KeyMsg{Type: tea.KeyEsc})
	if m.menu.Title != "Maintenance" || m.action != "" {
		t.Fatal("declining update did not return to maintenance")
	}

	m.collectors.Add(1)
	cmd := m.updateMolt(m.screen("maintenance"))
	if !m.exclusive || m.poll() != nil || m.collectorContext.Err() == nil {
		t.Fatal("update did not stop collectors")
	}
	result := make(chan actionMsg, 1)
	go func() {
		for _, command := range cmd().(tea.BatchMsg) {
			if msg, ok := command().(actionMsg); ok {
				result <- msg
			}
		}
	}()
	select {
	case <-result:
		m.collectors.Done()
		t.Fatal("update started before collectors finished")
	case <-time.After(150 * time.Millisecond):
	}
	m.collectors.Done()
	msg := <-result
	if msg.Error != nil {
		t.Fatal(msg.Error)
	}
	m.Update(msg)
	if m.exclusive || m.updating || m.collectorContext.Err() != nil || m.menu.Title != "MOLT updated" {
		t.Fatal("successful update did not resume the dashboard and offer restart")
	}
	if !strings.Contains(readValue(filepath.Join(home, "state", "ui", "last.log")), "updated source installed") {
		t.Fatal("update output was not saved")
	}
	if _, err := os.Stat(msg.Work); !os.IsNotExist(err) {
		t.Fatal("update action directory was not removed")
	}
	m.menu.Items[0].Run()
	if !m.restart {
		t.Fatal("restart action did not request the installed TUI")
	}
}

func TestUpdateFailureResumesCollectorsAndRetryIsExclusive(t *testing.T) {
	m := newModel(backend{Home: t.TempDir(), CLI: "/missing/molt", Context: context.Background()})
	defer func() { m.collectorCancel() }()
	cmd := m.updateMolt(m.screen("maintenance"))
	var msg actionMsg
	for _, command := range cmd().(tea.BatchMsg) {
		if result, ok := command().(actionMsg); ok {
			msg = result
		}
	}
	if msg.Error == nil {
		t.Fatal("missing CLI update succeeded")
	}
	m.Update(msg)
	if m.exclusive || m.updating || m.collectorContext.Err() != nil || m.restart || m.dialog.Retry == nil {
		t.Fatal("failed update did not restore polling and retry")
	}
	m.dialog.Retry()
	if !m.exclusive || !m.updating || m.collectorContext.Err() == nil {
		t.Fatal("retry did not pause collectors again")
	}
	m.cancelAction()
	m.Update(actionMsg{Name: m.action, Work: m.work, Error: errors.New("cancelled")})
	if m.exclusive || m.updating || m.restart || m.collectorContext.Err() != nil {
		t.Fatal("cancelled update did not restore polling")
	}
}

func TestUpdateStartupFailureResumesCollectors(t *testing.T) {
	t.Setenv("TMPDIR", filepath.Join(t.TempDir(), "missing"))
	m := newModel(backend{Home: t.TempDir(), CLI: "/missing/molt", Context: context.Background()})
	defer func() { m.collectorCancel() }()
	m.updateMolt(m.dashboard)
	if m.exclusive || m.updating || m.action != "" || m.collectorContext.Err() != nil {
		t.Fatal("failure to create an action directory left collectors stopped")
	}
}
