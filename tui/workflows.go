package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

func localPath(value string) string {
	home := os.Getenv("MOLT_USER_HOME")
	if home == "" {
		home, _ = os.UserHomeDir()
	}
	switch {
	case value == "~" || value == "$HOME":
		return home
	case strings.HasPrefix(value, "~/"):
		return filepath.Join(home, value[2:])
	case strings.HasPrefix(value, "$HOME/"):
		return filepath.Join(home, value[6:])
	default:
		return value
	}
}
func readValue(path string) string {
	data, _ := os.ReadFile(path)
	return strings.TrimRight(string(data), "\r\n")
}

func (m *model) openScreen(name string) tea.Cmd {
	if m.action != "" {
		m.overlay = "action"
		return nil
	}
	switch name {
	case "projects":
		items := []menuItem{
			{"Scan / add repositories", func() tea.Cmd { return m.scanForm() }},
			{"Register a repository by path", func() tea.Cmd { return m.registerForm(m.screen("projects")) }},
		}
		details := []string{"Find Git checkouts in your project folder.", "Register an existing Git checkout by its full path."}
		for _, p := range m.inv.Projects {
			p := p
			items = append(items, menuItem{p.Name, func() tea.Cmd { return m.projectMenu(p) }})
			details = append(details, "VM: "+p.Host+"\nLocal: "+p.Path)
		}
		items = append(items, menuItem{"Start all projects", func() tea.Cmd { return m.run("Start all projects", m.screen("projects"), nil, "up") }}, menuItem{"Stop all projects", func() tea.Cmd {
			return m.confirm("Stop all projects?", "Connected server sessions will be interrupted.", m.screen("projects"), func() tea.Cmd { return m.run("Stop all projects", m.screen("projects"), nil, "down") })
		}})
		m.showMenu("Repositories", "Project folder: "+m.inv.Config["MOLT_ROOT"], m.dashboard, items...)
		m.menu.Details = append(details, "Start every registered workspace.", "Stop all workspaces and flush synchronization. Confirmation required.")
		return nil
	case "connections":
		items := []menuItem{
			{"Add a connection", func() tea.Cmd { return m.connectionForm("") }},
			{"Use an existing SSH alias", m.aliases},
		}
		for _, host := range m.inv.Hosts {
			host := host
			items = append(items, menuItem{host, func() tea.Cmd { return m.connectionMenu(host) }})
		}
		return m.showMenu("Connections", "Selected: "+m.inv.Config["MOLT_HOST"], m.dashboard, items...)
	case "setup":
		items := []menuItem{{"Configure a connection", m.screen("connections")}}
		if host := m.inv.Config["MOLT_HOST"]; host != "" {
			items = append([]menuItem{{"Use configured connection (" + host + ")", func() tea.Cmd { return m.withConnections([]string{host}, m.screen("setup"), m.setupFolders) }}}, items...)
		}
		return m.showMenu("Guided setup", "Connect your VM, choose folders, and prepare Docker.", m.dashboard, items...)
	case "opencode":
		var items []menuItem
		var details []string
		for _, p := range m.inv.Projects {
			p := p
			items = append(items, menuItem{p.Name, func() tea.Cmd { return m.opencodeMenu(p) }})
			details = append(details, "VM: "+p.Host+"\nLocal: "+p.Path)
		}
		if len(items) == 0 {
			items = append(items, menuItem{"Register a repository first", m.screen("projects")})
		}
		m.showMenu("OpenCode projects", "Providers and settings are shared by projects on the same VM workspace.", m.dashboard, items...)
		m.menu.Details = details
		return nil
	case "settings":
		items := []menuItem{}
		var details []string
		for _, entry := range [][2]string{{"Project folder", "MOLT_ROOT"}, {"Remote workspace", "MOLT_REMOTE_HOME"}, {"OpenCode base port", "MOLT_OPENCODE_BASE_PORT"}, {"SSH configuration file", "MOLT_SSH_CONFIG"}} {
			label, key := entry[0], entry[1]
			items = append(items, menuItem{label, func() tea.Cmd { return m.settingForm(label, key) }})
			value := m.inv.Config[key]
			if value == "" {
				value = "Not configured"
			}
			details = append(details, "Current value: "+value)
		}
		on := "Off"
		if m.inv.Config["MOLT_ANIMATIONS"] != "0" {
			on = "On"
		}
		items = append(items, menuItem{"Animations: " + on, func() tea.Cmd {
			value := "0"
			if m.inv.Config["MOLT_ANIMATIONS"] == "0" {
				value = "1"
			}
			return m.run("Save animations", m.screen("settings"), func() tea.Cmd {
				m.inv.Config["MOLT_ANIMATIONS"] = value
				m.animation = value == "1" && os.Getenv("NO_COLOR") == ""
				return m.openScreen("settings")
			}, "config", "set", "MOLT_ANIMATIONS", value)
		}}, menuItem{"Shell activation", m.shellMenu})
		m.showMenu("Settings", "Preferences are saved in this installation.", m.dashboard, items...)
		m.menu.Details = append(details, "Press Enter to turn animations on or off.", "Enable or disable MOLT commands in new Zsh terminals.")
		return nil
	case "maintenance":
		return m.maintenanceMenu()
	case "uninstall":
		return m.uninstallMenu()
	default:
		return m.showMessage("Unknown screen", name, m.dashboard)
	}
}

func (m *model) registerForm(returnTo func() tea.Cmd) tea.Cmd {
	return m.showForm("Add repository", "Path to an existing Git checkout.", returnTo, func(v []string) tea.Cmd {
		return m.run("Register repository", returnTo, nil, "register", localPath(v[0]))
	}, formField{Label: "Repository path"})
}
func (m *model) scanForm() tea.Cmd {
	return m.showForm("Scan repositories", "Choose a folder containing Git checkouts.", m.screen("projects"), func(v []string) tea.Cmd {
		root := localPath(v[0])
		return m.fetch("Scan repositories", m.scanForm, func(data []byte) tea.Cmd {
			var items []menuItem
			var paths []string
			for _, path := range strings.Split(strings.TrimRight(string(data), "\r\n"), "\n") {
				if path == "" {
					continue
				}
				path := path
				rel, _ := filepath.Rel(root, path)
				items = append(items, menuItem{filepath.Base(path) + " · " + rel, func() tea.Cmd { return m.run("Register repository", m.screen("projects"), nil, "register", path) }})
				paths = append(paths, path)
			}
			if len(items) == 0 {
				return m.showMessage("No repositories found", "No Git checkouts found under "+root+". Choose another folder.", m.scanForm)
			}
			m.showMenu("Scan results", fmt.Sprintf("%d repositories under %s", len(items), root), m.scanForm, items...)
			m.menu.Details = paths
			return nil
		}, "scan", root)
	}, formField{Label: "Project folder", Value: m.inv.Config["MOLT_ROOT"]})
}
func (m *model) projectMenu(p project) tea.Cmd {
	returnTo := func() tea.Cmd { return m.projectMenu(p) }
	items := []menuItem{
		{"Open OpenCode", func() tea.Cmd { m.sessionBack = returnTo; return m.terminal("oc-project", "@"+p.ID) }},
		{"Start", func() tea.Cmd { return m.run("Start "+p.Name, returnTo, nil, "start", "@"+p.ID) }},
	}
	for _, verb := range []string{"stop", "restart"} {
		verb := verb
		label := strings.ToUpper(verb[:1]) + verb[1:]
		items = append(items, menuItem{label, func() tea.Cmd {
			return m.confirm(label+" · "+p.Name, "This interrupts the project's server session.", returnTo, func() tea.Cmd {
				return m.run(label+" "+p.Name, returnTo, nil, verb, "@"+p.ID)
			})
		}})
	}
	items = append(items, menuItem{"Remove project", func() tea.Cmd { return m.removeProjectMenu(p) }})
	items = append(items, menuItem{"Server logs", func() tea.Cmd { return m.run("Server logs", returnTo, nil, "logs", "@"+p.ID) }}, menuItem{"Synchronization", func() tea.Cmd { return m.syncMenu(p, returnTo, nil) }}, menuItem{"Providers and settings", func() tea.Cmd { return m.opencodeMenu(p) }})
	return m.showMenu(p.Name, "VM: "+p.Host+"\nLocal: "+p.Path, m.screen("projects"), items...)
}

func (m *model) removeProjectMenu(p project) tea.Cmd {
	returnTo := func() tea.Cmd { return m.projectMenu(p) }
	return m.fetch("Project setup state", returnTo, func(data []byte) tea.Cmd {
		untouched := strings.TrimSpace(string(data)) == "untouched"
		confirm := func(localOnly bool) tea.Cmd {
			body := "Remove its local registration? Your Mac checkout is kept."
			args := []string{"MOLT_ASSUME_YES=1", m.b.CLI, "reset", "@" + p.ID}
			if !untouched {
				body = "Remove its container, image, synchronization, VM mirror, and MOLT state? Your Mac checkout is kept."
			}
			if localOnly {
				args = append(args, "--local-only")
				body = "VM resources may remain running. Remote edits will not be synchronized, and project cleanup records will be deleted. Remove local registration and synchronization anyway? Your Mac checkout is kept."
			}
			return m.confirm("Remove project · "+p.Name, body, returnTo, func() tea.Cmd {
				run := func() tea.Cmd {
					cmd := m.runProgram("Remove project", m.screen("projects"), nil, "env", args...)
					if !localOnly && !untouched {
						m.actionFailure = func(err error) tea.Cmd { return m.removalRecovery(p, err.Error()+"\n\n"+strings.Join(m.output, "\n")) }
					}
					return cmd
				}
				if !localOnly && !untouched {
					return m.withConnections([]string{p.Host}, func() tea.Cmd { return m.removeProjectMenu(p) }, run)
				}
				return run()
			})
		}
		if untouched {
			return confirm(false)
		}
		return m.showMenu("Remove project / "+p.Name, "VM changes are recorded. Local-only removal leaves them behind.", returnTo,
			menuItem{"Remove project and VM resources", func() tea.Cmd { return confirm(false) }},
			menuItem{"Remove project locally only", func() tea.Cmd { return confirm(true) }})
	}, "setup-state", "@"+p.ID)
}

func (m *model) connectionForm(alias string) tea.Cmd {
	profile := filepath.Join(m.b.Home, "state", "ssh", "profiles", alias)
	fields := []formField{{Label: "Connection name", Value: alias}, {Label: "VM address", Value: readValue(filepath.Join(profile, "hostname"))}, {Label: "SSH username", Value: readValue(filepath.Join(profile, "user"))}, {Label: "SSH port", Value: readValue(filepath.Join(profile, "port"))}, {Label: "Identity file (blank uses SSH agent or password)", Value: readValue(filepath.Join(profile, "identity")), Optional: true}}
	if alias == "" {
		fields[0].Value = "molt-vm"
		fields[2].Value = "ubuntu"
		fields[3].Value = "22"
	}
	return m.showForm("Connection profile", "Keys and passwords are entered through the embedded SSH session.", m.screen("connections"), func(v []string) tea.Cmd {
		identity := ""
		if v[4] != "" {
			identity = localPath(v[4])
		}
		return m.run("Save connection", func() tea.Cmd { return m.connectionForm(alias) }, func() tea.Cmd {
			return m.run("Select connection", m.screen("connections"), func() tea.Cmd { m.inv.Config["MOLT_HOST"] = v[0]; return m.connectionMenu(v[0]) }, "connection", "use", v[0])
		}, "connection", "add", v[0], v[1], v[2], v[3], identity)
	}, fields...)
}
func (m *model) aliases() tea.Cmd {
	return m.fetch("Existing SSH aliases", m.screen("connections"), func(data []byte) tea.Cmd {
		var items []menuItem
		var details []string
		for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
			alias, detail, ok := strings.Cut(line, "\t")
			if !ok {
				continue
			}
			items = append(items, menuItem{alias, func() tea.Cmd {
				return m.run("Select connection", m.aliases, func() tea.Cmd { m.inv.Config["MOLT_HOST"] = alias; return m.connectionMenu(alias) }, "connection", "use", alias)
			}})
			details = append(details, "Destination: "+detail)
		}
		if len(items) == 0 {
			items = append(items, menuItem{"No aliases found · add a connection", func() tea.Cmd { return m.connectionForm("") }})
		}
		m.showMenu("Existing SSH aliases", "Select an alias to see its destination.", m.screen("connections"), items...)
		m.menu.Details = details
		return nil
	}, "connection", "aliases")
}
func (m *model) connectionMenu(alias string) tea.Cmd {
	returnTo := func() tea.Cmd { return m.connectionMenu(alias) }
	return m.showMenu("Connection / "+alias, "Profiles used by existing resources are retained for cleanup.", m.screen("connections"),
		menuItem{"Select this connection", func() tea.Cmd {
			return m.run("Select connection", returnTo, func() tea.Cmd { m.inv.Config["MOLT_HOST"] = alias; return returnTo() }, "connection", "use", alias)
		}},
		menuItem{"Connect / authenticate", func() tea.Cmd { m.sessionBack = returnTo; return m.terminal("connection", "login", alias) }},
		menuItem{"Test connection", func() tea.Cmd { return m.run("Test connection", returnTo, nil, "connection", "test", alias) }},
		menuItem{"Edit / duplicate profile", func() tea.Cmd { return m.connectionForm(alias) }},
		menuItem{"Create a dedicated MOLT key", func() tea.Cmd { m.sessionBack = returnTo; return m.terminal("connection", "keygen", alias) }},
		menuItem{"Authorize dedicated key", func() tea.Cmd {
			return m.showForm("Authorize key", "Optional initial login key; blank uses SSH agent or password.", returnTo, func(v []string) tea.Cmd {
				m.sessionBack = returnTo
				return m.terminal("connection", "authorize", alias, localPath(v[0]))
			}, formField{Label: "Initial identity file", Optional: true})
		}},
		menuItem{"Revoke dedicated key", func() tea.Cmd {
			return m.confirm("Revoke key?", "Remove the recorded dedicated public key from "+alias+".", returnTo, func() tea.Cmd { m.sessionBack = returnTo; return m.terminal("connection", "revoke", alias) })
		}},
		menuItem{"Remove profile", func() tea.Cmd {
			return m.confirm("Remove profile?", alias, returnTo, func() tea.Cmd {
				return m.run("Remove connection", m.screen("connections"), nil, "connection", "remove", alias)
			})
		}})
}

func (m *model) setupFolders() tea.Cmd {
	return m.showForm("Setup folders", "Choose your Mac project folder and an owned workspace on the VM.", m.screen("setup"), func(v []string) tea.Cmd {
		return m.run("Save project folder", m.setupFolders, func() tea.Cmd {
			return m.run("Save remote workspace", m.setupFolders, func() tea.Cmd {
				m.inv.Config["MOLT_ROOT"], m.inv.Config["MOLT_REMOTE_HOME"] = localPath(v[0]), v[1]
				return m.prepareVM(m.screen("setup"), func() tea.Cmd {
					return m.showMenu("Setup complete", "Your VM is ready. Register a repository to start its workspace.", m.dashboard, menuItem{"Register repositories", m.screen("projects")}, menuItem{"Enable shell activation", func() tea.Cmd {
						return m.run("Enable shell activation", m.screen("setup"), m.dashboard, "shell", "enable")
					}}, menuItem{"Open control center", m.dashboard})
				})
			}, "config", "set", "MOLT_REMOTE_HOME", v[1])
		}, "config", "set", "MOLT_ROOT", localPath(v[0]))
	}, formField{Label: "Project folder", Value: m.inv.Config["MOLT_ROOT"]}, formField{Label: "Remote workspace", Value: m.inv.Config["MOLT_REMOTE_HOME"]})
}
func (m *model) prepareVM(returnTo, next func() tea.Cmd) tea.Cmd {
	return m.confirm("Prepare VM?", "Install Docker and grant the SSH user access if needed. Administrator authentication may be required.", returnTo, func() tea.Cmd {
		return m.withConnections([]string{m.inv.Config["MOLT_HOST"]}, returnTo, func() tea.Cmd { m.sessionBack, m.afterSession = returnTo, next; return m.terminal("bootstrap") })
	})
}
func (m *model) settingForm(label, key string) tea.Cmd {
	return m.showForm(label, "Enter a new value.", m.screen("settings"), func(v []string) tea.Cmd {
		value := v[0]
		if key == "MOLT_ROOT" || key == "MOLT_SSH_CONFIG" {
			value = localPath(value)
		}
		return m.run("Save "+label, func() tea.Cmd { return m.settingForm(label, key) }, func() tea.Cmd { m.inv.Config[key] = value; return m.openScreen("settings") }, "config", "set", key, value)
	}, formField{Label: label, Value: m.inv.Config[key]})
}
func (m *model) shellMenu() tea.Cmd {
	return m.fetch("Shell activation", m.screen("settings"), func(data []byte) tea.Cmd {
		return m.showMenu("Shell activation", strings.TrimSpace(string(data)), m.screen("settings"), menuItem{"Enable in new Zsh terminals", func() tea.Cmd { return m.run("Enable shell activation", m.shellMenu, m.shellMenu, "shell", "enable") }}, menuItem{"Disable", func() tea.Cmd { return m.run("Disable shell activation", m.shellMenu, m.shellMenu, "shell", "disable") }})
	}, "shell", "status")
}

func (m *model) opencodeMenu(p project) tea.Cmd {
	returnTo := func() tea.Cmd { return m.opencodeMenu(p) }
	items := []menuItem{{"Attach to project", func() tea.Cmd { m.sessionBack = returnTo; return m.terminal("oc-project", "@"+p.ID) }}}
	for _, verb := range []string{"login", "list", "logout", "models"} {
		verb := verb
		label := map[string]string{"login": "Log in to a provider", "list": "List providers", "logout": "Log out of a provider", "models": "Available models"}[verb]
		items = append(items, menuItem{label, func() tea.Cmd {
			return m.run("Start "+p.Name, returnTo, func() tea.Cmd {
				args := []string{"remote-oc", "@" + p.ID, "auth", verb}
				if verb == "models" {
					args = []string{"remote-oc", "@" + p.ID, "models"}
				}
				if verb == "login" || verb == "logout" {
					m.sessionBack = returnTo
					return m.terminal(args...)
				}
				return m.run(label, returnTo, nil, args...)
			}, "start", "@"+p.ID)
		}})
	}
	items = append(items, menuItem{"Edit server settings", func() tea.Cmd {
		return m.run("Start "+p.Name, returnTo, func() tea.Cmd { return m.editServer(p) }, "start", "@"+p.ID)
	}})
	return m.showMenu("OpenCode / "+p.Name, "Authentication and configuration are shared on "+p.Host+".", m.screen("opencode"), items...)
}
func (m *model) editServer(p project) tea.Cmd {
	returnTo := func() tea.Cmd {
		if m.editor.File != "" {
			os.Remove(m.editor.File)
			m.editor.File = ""
		}
		return m.opencodeMenu(p)
	}
	return m.fetch("Server settings", returnTo, func(data []byte) tea.Cmd {
		m.overlay = "editor"
		m.editor = editorState{Text: []rune(safeText(string(data))), Back: returnTo, Save: func(value string) tea.Cmd {
			if m.editor.File != "" {
				os.Remove(m.editor.File)
				m.editor.File = ""
			}
			file, err := os.CreateTemp(filepath.Join(m.b.Home, "state", "tmp"), "server-settings.")
			if err != nil {
				return m.showMessage("Cannot save settings", err.Error(), returnTo)
			}
			name := file.Name()
			m.editor.File = name
			_, err = file.WriteString(value)
			closeErr := file.Close()
			if err == nil {
				err = closeErr
			}
			if err != nil {
				os.Remove(name)
				return m.showMessage("Cannot save settings", err.Error(), returnTo)
			}
			// The CLI validates JSONC and performs the atomic remote replacement.
			return m.run("Save server settings", func() tea.Cmd { m.overlay = "editor"; return nil }, func() tea.Cmd { os.Remove(name); return returnTo() }, "server-config", "@"+p.ID, "set", name)
		}}
		return nil
	}, "server-config", "@"+p.ID, "get")
}

func (m *model) maintenanceMenu() tea.Cmd {
	returnTo := m.screen("maintenance")
	m.showMenu("Maintenance", "Manage this installation and its recorded resources.", m.dashboard,
		menuItem{"Tool versions", func() tea.Cmd { return m.run("Tool versions", returnTo, nil, "tools") }},
		menuItem{"Diagnostics", func() tea.Cmd { return m.run("Diagnostics", returnTo, nil, "doctor") }},
		menuItem{"Prepare / repair VM", func() tea.Cmd { return m.prepareVM(returnTo, nil) }},
		menuItem{"Stop local helpers", func() tea.Cmd { return m.run("Stop local helpers", returnTo, nil, "local-down") }},
		menuItem{"Reset all projects", func() tea.Cmd {
			return m.confirm("Reset all projects?", "Remove owned project resources and MOLT state. Mac checkouts are kept.", returnTo, func() tea.Cmd {
				return m.runProgram("Reset all projects", returnTo, nil, "env", "MOLT_ASSUME_YES=1", m.b.CLI, "reset", "--all")
			})
		}},
		menuItem{"Clean empty VM workspaces", func() tea.Cmd {
			return m.confirm("Remove remote workspaces?", "Remove recorded empty workspace roots from the VMs.", returnTo, func() tea.Cmd { return m.run("Remove remote workspaces", returnTo, nil, "remove-remote-roots") })
		}},
		menuItem{"Update MOLT", func() tea.Cmd {
			return m.confirm("Update MOLT?", "Download and install the latest MOLT from main. Settings, credentials, and project records are kept. Go 1.26 or newer is required to build the interface. Synchronization may pause briefly; restart the control center afterward.", returnTo, func() tea.Cmd { return m.updateMolt(returnTo) })
		}},
		menuItem{"Repair installation", func() tea.Cmd { return m.installFrom(filepath.Join(m.b.Home, "current"), returnTo) }},
		menuItem{"Upgrade from checkout", func() tea.Cmd {
			return m.showForm("Upgrade MOLT", "Select a MOLT source checkout.", returnTo, func(v []string) tea.Cmd {
				source := localPath(v[0])
				if _, err := os.Stat(filepath.Join(source, "tools.lock")); err != nil {
					m.form.Error = "Choose a MOLT checkout containing tools.lock"
					return nil
				}
				return m.confirm("Upgrade MOLT?", "Install from "+source+".", returnTo, func() tea.Cmd { return m.installFrom(source, returnTo) })
			}, formField{Label: "Source checkout", Value: localPath("~")})
		}},
		menuItem{"Open installation folder", func() tea.Cmd { return m.runProgram("Open Finder", returnTo, nil, "open", m.b.Home) }})
	m.menu.Details = []string{
		"Show the installed MOLT, Mutagen, and OpenCode versions.",
		"Check VM connectivity and workspace health.",
		"Prepare Docker and repair the owned VM workspace.",
		"Stop the local SSH and synchronization helpers.",
		"Remove all owned project resources. Mac checkouts are kept. Confirmation required.",
		"Remove recorded empty workspace roots from the VMs. Confirmation required.",
		"Download the latest MOLT from main and install it here. Requires internet access and Go 1.26 or newer.",
		"Reinstall from the current installation's source.",
		"Choose a MOLT source checkout to install an upgrade.",
		"Open in Finder: " + m.b.Home,
	}
	return nil
}
func (m *model) updateMolt(returnTo func() tea.Cmd) tea.Cmd {
	if m.action != "" || m.sessionCancel != nil {
		return m.showMessage("Action in progress", "Finish or cancel the current operation first.", returnTo)
	}
	if m.queryCancel != nil {
		m.queryCancel()
		m.queryID++
	}
	m.updating, m.exclusive = true, true
	m.collectorCancel()
	cmd := m.run("Update MOLT", returnTo, func() tea.Cmd {
		return m.showMenu("MOLT updated", "Restart the control center to load the update.", returnTo,
			menuItem{"Restart control center", func() tea.Cmd { m.restart = true; return tea.Quit }})
	}, "update")
	m.retry = func() tea.Cmd { return m.updateMolt(returnTo) }
	if m.action == "" {
		m.updating, m.exclusive = false, false
		m.resumeCollectors()
		return tea.Batch(cmd, m.poll())
	}
	return cmd
}
func (m *model) installFrom(source string, returnTo func() tea.Cmd) tea.Cmd {
	return m.runProgram("Install MOLT", returnTo, nil, "/bin/bash", filepath.Join(source, "install.sh"), "--non-interactive")
}
func (m *model) uninstallMenu() tea.Cmd {
	returnTo := m.screen("uninstall")
	m.showMenu("Uninstall", "Mac checkouts are kept. Cleanup failures retain retry records.", m.dashboard,
		menuItem{"Preview cleanup inventory", func() tea.Cmd {
			return m.fetch("Cleanup inventory", returnTo, func(data []byte) tea.Cmd {
				value := strings.TrimSpace(string(data))
				if value == "" {
					value = "No remote resources recorded."
				}
				return m.showMessage("Cleanup inventory", value, returnTo)
			}, "cleanup-inventory")
		}},
		menuItem{"Remove MOLT and VM resources", func() tea.Cmd { return m.confirmUninstall(false, false) }},
		menuItem{"Also undo Docker preparation", func() tea.Cmd { return m.confirmUninstall(false, true) }},
		menuItem{"Remove Mac installation only", func() tea.Cmd { return m.confirmUninstall(true, false) }})
	m.menu.Details = []string{
		"Review the recorded resources before choosing a removal option.",
		"Remove this installation and its owned VM resources. Mac checkouts are kept.",
		"Remove MOLT and VM resources, and undo MOLT-recorded Docker preparation when safe.",
		"Remove only the Mac installation. VM resources may remain running when VM changes are recorded.",
	}
	return nil
}
func (m *model) confirmUninstall(localOnly, undo bool) tea.Cmd {
	args := []string{"--yes"}
	if undo {
		args = append(args, "--undo-vm")
	}
	if localOnly {
		args = append(args, "--local-only")
	}
	returnTo := m.screen("uninstall")
	return m.fetch("Recorded setup state", returnTo, func(data []byte) tea.Cmd {
		untouched := strings.TrimSpace(string(data)) == "untouched"
		body := "Remove this Mac installation? Your Mac checkouts are kept."
		if !untouched {
			if localOnly {
				body = "VM resources may remain running, including workspaces, images, caches, provider credentials, SSH authorization, and VM preparation. Remote edits will not be synchronized, and local cleanup records will be deleted. Remove this Mac installation anyway?"
			} else {
				body = "Remove this installation and its owned VM resources? Mac checkouts are kept."
			}
		}
		return m.confirm("Remove MOLT?", body, returnTo, func() tea.Cmd {
			remove := func() tea.Cmd { return m.removeInstallation(args, returnTo) }
			if !localOnly && !untouched {
				return m.withConnections(m.resourceHosts(false), returnTo, remove)
			}
			return remove()
		})
	}, "setup-state")
}
func (m *model) removeInstallation(args []string, returnTo func() tea.Cmd) tea.Cmd {
	if m.queryCancel != nil {
		m.queryCancel()
		m.queryID++
	}
	m.exclusive = true
	m.collectorCancel()
	if contains(args, "--undo-vm") {
		m.sessionBack = returnTo
		return m.terminalProgram("Uninstall MOLT", filepath.Join(m.b.Home, "bin", "molt-uninstall"), args...)
	}
	return m.runProgram("Uninstall MOLT", returnTo, nil, filepath.Join(m.b.Home, "bin", "molt-uninstall"), args...)
}
func contains(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}

func (m *model) resourceHosts(includeRegistered bool) []string {
	hosts := map[string]bool{}
	for _, p := range m.inv.Projects {
		state := filepath.Join(m.b.Home, "projects", p.ID)
		setup := readValue(filepath.Join(state, "setup_state"))
		touched := p.Active || setup != "" && setup != "untouched" || readValue(filepath.Join(state, "sync_created")) == "1"
		for _, field := range []string{"remote_path", "remote_meta", "remote_home", "remote_opencode_config"} {
			touched = touched || readValue(filepath.Join(state, field)) != ""
		}
		if p.Host != "" && (includeRegistered || touched) {
			hosts[p.Host] = true
		}
	}
	files, _ := filepath.Glob(filepath.Join(m.b.Home, "state", "remotes", "*", "host"))
	for _, file := range files {
		if host := readValue(file); host != "" {
			hosts[host] = true
		}
	}
	files, _ = filepath.Glob(filepath.Join(m.b.Home, "state", "ssh", "profiles", "*", "authorized"))
	for _, file := range files {
		hosts[filepath.Base(filepath.Dir(file))] = true
	}
	var list []string
	for host := range hosts {
		list = append(list, host)
	}
	sort.Strings(list)
	return list
}
func (m *model) withActionConnections(args []string, returnTo, next func() tea.Cmd) tea.Cmd {
	if len(args) == 0 {
		return next()
	}
	switch args[0] {
	case "up", "down", "remove-remote-roots":
		return m.withConnections(m.resourceHosts(args[0] == "up"), returnTo, next)
	case "start", "stop", "restart", "logs", "doctor", "remote-oc", "server-config", "sync-resolve", "sync-cycle":
		host := m.inv.Config["MOLT_HOST"]
		if len(args) > 1 {
			for _, p := range m.inv.Projects {
				if args[1] == "@"+p.ID || args[1] == p.Path {
					host = p.Host
					break
				}
			}
		}
		if host != "" {
			return m.withConnections([]string{host}, returnTo, next)
		}
	}
	return next()
}
func (m *model) withConnections(hosts []string, returnTo, next func() tea.Cmd) tea.Cmd {
	if len(hosts) == 0 {
		return next()
	}
	host := hosts[0]
	continueAction := func() tea.Cmd { return m.withConnections(hosts[1:], returnTo, next) }
	cmd := m.fetch("Check connection / "+host, returnTo, func([]byte) tea.Cmd { return continueAction() }, "connection", "test", host)
	m.onQueryError = func(err error) tea.Cmd {
		return m.showMenu("Connection unavailable / "+host, err.Error(), returnTo,
			menuItem{"Authenticate through SSH", func() tea.Cmd {
				m.sessionBack = returnTo
				m.afterSession = func() tea.Cmd { return m.withConnections(hosts, returnTo, next) }
				return m.terminal("connection", "login", host)
			}},
			menuItem{"Retry connection", func() tea.Cmd { return m.withConnections(hosts, returnTo, next) }})
	}
	return cmd
}
