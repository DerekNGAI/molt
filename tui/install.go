package main

import (
	"os"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"
)

func (m *model) installWizard(source string) tea.Cmd {
	m.source, m.installing = source, true
	return m.showForm("Install folder", "Choose a dedicated installation folder with an existing parent.", func() tea.Cmd { return tea.Quit }, func(v []string) tea.Cmd {
		home, err := filepath.Abs(localPath(v[0]))
		if err != nil {
			m.form.Error = err.Error()
			return nil
		}
		return m.confirm("Install MOLT?", "Install or upgrade MOLT in "+home+".", func() tea.Cmd { return m.installWizard(source) }, func() tea.Cmd {
			m.b.Home = home
			binary, err := os.Executable()
			if err != nil {
				return m.showMessage("Cannot install", err.Error(), func() tea.Cmd { return m.installWizard(source) })
			}
			return m.runProgram("Install MOLT", func() tea.Cmd { return m.installWizard(source) }, m.installComplete, "env", "MOLT_TUI_BINARY="+binary, "/bin/bash", filepath.Join(source, "install.sh"), "--non-interactive")
		})
	}, formField{Label: "Installation folder", Value: m.b.Home})
}
func (m *model) installComplete() tea.Cmd {
	m.installing = false
	m.b.CLI = filepath.Join(m.b.Home, "bin", "molt")
	returnTo := func() tea.Cmd {
		return m.showMenu("MOLT installed", m.b.Home, m.dashboard,
			menuItem{"Enable commands in new Zsh terminals", func() tea.Cmd {
				return m.run("Enable shell activation", m.dashboard, m.screen("setup"), "shell", "enable")
			}},
			menuItem{"Guided VM setup", m.screen("setup")}, menuItem{"Open control center", m.dashboard})
	}
	return tea.Batch(returnTo(), m.poll(), pollTick())
}
