package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

func (m *model) removalRecovery(p project, output string) tea.Cmd {
	returnTo := func() tea.Cmd { return m.projectMenu(p) }
	recovery := func() tea.Cmd { return m.removalRecovery(p, output) }
	return m.showMenu("Remove project failed / "+p.Name, "Your checkout and cleanup records are retained. Inspect the failure or resolve synchronization before retrying.", returnTo,
		menuItem{"Resolve synchronization issues", func() tea.Cmd { return m.syncMenu(p, recovery, func() tea.Cmd { return m.removeProjectMenu(p) }) }},
		menuItem{"View failure details", func() tea.Cmd { return m.showMessage("Removal failure / "+p.Name, output, recovery) }},
		menuItem{"Retry removal", func() tea.Cmd { return m.removeProjectMenu(p) }})
}

func (m *model) syncMenu(p project, returnTo, retryRemoval func() tea.Cmd) tea.Cmd {
	refresh := func() tea.Cmd { return m.syncMenu(p, returnTo, retryRemoval) }
	return m.fetch("Synchronization / "+p.Name, returnTo, func(data []byte) tea.Cmd {
		states, err := parseSync(data)
		if err != nil {
			return m.showMessage("Cannot read synchronization", err.Error(), returnTo)
		}
		s, exists := states[p.Sync]
		paths := map[string]bool{}
		for _, c := range s.Conflicts {
			paths[conflictRoot(c.Root)] = true
		}
		var sorted []string
		for name := range paths {
			sorted = append(sorted, name)
		}
		sort.Strings(sorted)
		items := []menuItem{}
		for _, name := range sorted {
			name := name
			items = append(items, menuItem{name, func() tea.Cmd { return m.previewSyncConflict(p, name, refresh) }})
		}
		problems, repairable := 0, false
		for _, endpoint := range []struct {
			Name  string
			State syncEndpoint
		}{{"Mac", s.Alpha}, {"VM", s.Beta}} {
			for _, group := range []struct {
				Name  string
				Items []syncProblem
			}{{"Scan", endpoint.State.ScanProblems}, {"Transition", endpoint.State.TransitionProblems}} {
				for _, problem := range group.Items {
					title := endpoint.Name + " · " + problem.Path
					body := group.Name + " problem on " + endpoint.Name + "\nPath: " + problem.Path + "\n\n" + problem.Error
					items = append(items, menuItem{title, func() tea.Cmd { return m.showMessage(title, body, refresh) }})
					problems++
					repairable = repairable || endpoint.Name == "VM" && strings.Contains(strings.ToLower(problem.Error), "permission denied")
				}
			}
		}
		help := "No synchronization session."
		if exists {
			help = "Status: " + s.label()
		}
		if len(sorted) > 0 {
			help += fmt.Sprintf(" · %d conflicts. Select a path to inspect both versions.", len(sorted))
		}
		if exists && s.label() == "error" {
			if problems > 0 {
				help += fmt.Sprintf(" · %d filesystem problems. Select a path for details.", problems)
			} else {
				help += ". View the error details before rechecking."
			}
		}
		if s.LastError != "" {
			items = append(items, menuItem{"View synchronization error", func() tea.Cmd { return m.showMessage("Synchronization error", s.LastError, refresh) }})
		}
		if repairable {
			items = append(items, menuItem{"Repair VM permissions", func() tea.Cmd {
				return m.confirm("Repair VM permissions?", "Restore the VM user's access to root-owned project files and OpenCode state? The project's server will be stopped. File contents are kept.", refresh, func() tea.Cmd {
					return m.run("Repair VM permissions", refresh, refresh, "sync-repair", "@"+p.ID)
				})
			}})
		}
		items = append(items, menuItem{"View synchronization details", func() tea.Cmd { return m.run("Synchronization details", refresh, nil, "sync", "@"+p.ID) }})
		if exists {
			items = append(items, menuItem{"Recheck synchronization", func() tea.Cmd {
				return m.run("Recheck synchronization", refresh, refresh, "sync-cycle", "@"+p.ID)
			}})
		}
		if retryRemoval != nil && (!exists || s.label() == "synced") {
			items = append(items, menuItem{"Retry removal", retryRemoval})
		}
		items = append(items, menuItem{"Refresh", refresh})
		return m.showMenu("Synchronization / "+p.Name, help, returnTo, items...)
	}, "sync", "@"+p.ID, "--json")
}

func (m *model) previewSyncConflict(p project, name string, returnTo func() tea.Cmd) tea.Cmd {
	return m.withConnections([]string{p.Host}, returnTo, func() tea.Cmd {
		return m.fetch("Inspect conflict / "+name, returnTo, func(data []byte) tea.Cmd {
			var preview conflictPreview
			if err := json.Unmarshal(data, &preview); err != nil {
				return m.showMessage("Cannot inspect conflict", err.Error(), returnTo)
			}
			return m.conflictMenu(p, preview, returnTo)
		}, "sync-preview", "@"+p.ID, name)
	})
}

func (m *model) conflictMenu(p project, preview conflictPreview, returnTo func() tea.Cmd) tea.Cmd {
	menu := func() tea.Cmd { return m.conflictMenu(p, preview, returnTo) }
	choose := func(side, label string) tea.Cmd {
		body := "Use the " + label + " version of " + preview.Path + " on both sides? The project's server will be stopped. Close local editors or Git operations that could change these files.\n\nBoth versions are backed up at:\n" + preview.Directory
		if conflictRoot(preview.Path) == preview.Path && (preview.Path == ".git" || strings.HasSuffix(preview.Path, "/.git")) {
			body += "\n\nThis replaces Git metadata as a complete group, including its index and refs."
		}
		return m.confirm("Keep "+label+" version?", body, menu, func() tea.Cmd {
			return m.run("Resolve conflict", returnTo, returnTo, "sync-resolve", "@"+p.ID, preview.Directory, side)
		})
	}
	return m.showMenu("Conflict / "+preview.Path, "Inspect each side, then choose which version to keep. Both snapshots are retained after project removal.", returnTo,
		menuItem{"View Mac version", func() tea.Cmd { return m.showMessage("Mac / "+preview.Path, preview.Mac, menu) }},
		menuItem{"View VM version", func() tea.Cmd { return m.showMessage("VM / "+preview.Path, preview.VM, menu) }},
		menuItem{"Keep Mac version", func() tea.Cmd { return choose("mac", "Mac") }},
		menuItem{"Keep VM version", func() tea.Cmd { return choose("vm", "VM") }},
		menuItem{"Open backups in Finder", func() tea.Cmd { return m.runProgram("Open backups", menu, nil, "open", preview.Directory) }})
}
