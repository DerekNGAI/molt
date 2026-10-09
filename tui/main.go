package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"syscall"

	tea "github.com/charmbracelet/bubbletea"
)

func main() {
	cli := flag.String("cli", "", "path to the MOLT CLI")
	home := flag.String("home", os.Getenv("MOLT_HOME"), "MOLT installation folder")
	source := flag.String("install-source", "", "source checkout for the installation wizard")
	screen := flag.String("screen", "", "initial management screen")
	flag.Parse()
	if (*cli == "" && *source == "") || *home == "" {
		fmt.Fprintln(os.Stderr, "molt-tui: launch through molt, or supply --cli and --home")
		os.Exit(2)
	}
	ctx, cancel := context.WithCancel(context.Background())
	m := newModel(backend{CLI: *cli, Home: *home, Context: ctx})
	m.startScreen = *screen
	if *source != "" {
		m.installWizard(*source)
	}
	_, err := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion(), tea.WithFPS(30)).Run()
	cancel()
	m.collectorCancel()
	if m.cancelAction != nil {
		m.cancelAction()
	}
	if m.sessionCancel != nil {
		m.sessionCancel()
	}
	if m.session != nil {
		m.session.close()
	}
	if m.queryCancel != nil {
		m.queryCancel()
	}
	if m.editor.File != "" {
		os.Remove(m.editor.File)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "molt-tui:", err)
		os.Exit(1)
	}
	if m.restart {
		m.collectors.Wait()
		if err := syscall.Exec(m.b.CLI, []string{m.b.CLI, "menu", "maintenance"}, append(os.Environ(), "MOLT_HOME="+m.b.Home)); err != nil {
			fmt.Fprintln(os.Stderr, "molt-tui: cannot restart:", err)
			os.Exit(1)
		}
	}
}
