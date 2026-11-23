// tb-setup is the full-screen ThoughtBox setup. The installers (install.sh and
// install.ps1) download it, check its pinned SHA-256 and run it when there is a real
// terminal; otherwise they run the plain script.
//
//	tb-setup [--dry-run] <onboarding-file>
//
// Exit codes: 0 finished, 1 the setup stopped with a problem, 2 wrong usage,
// 3 no terminal (the caller should use the plain script), 130 stopped by the person.
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"golang.org/x/term"

	"github.com/ThoughtBoxFinTechAI/dev-setup/tui/internal/gita"
	"github.com/ThoughtBoxFinTechAI/dev-setup/tui/internal/setup"
	"github.com/ThoughtBoxFinTechAI/dev-setup/tui/internal/state"
	"github.com/ThoughtBoxFinTechAI/dev-setup/tui/internal/tokens"
	"github.com/ThoughtBoxFinTechAI/dev-setup/tui/internal/ui"
)

// version is set at build time (-ldflags "-X main.version=...").
var version = "dev"

const (
	exitUsage      = 2
	exitNoTerminal = 3
)

func main() { os.Exit(run()) }

func run() int {
	dry := flag.Bool("dry-run", os.Getenv("TB_DRY_RUN") == "1", "show what would change, change nothing")
	showVersion := flag.Bool("version", false, "print the version")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: tb-setup [--dry-run] <onboarding-file>")
		flag.PrintDefaults()
	}
	flag.Parse()
	if *showVersion {
		fmt.Println("tb-setup " + version)
		return 0
	}
	if flag.NArg() != 1 {
		flag.Usage()
		return exitUsage
	}
	if !term.IsTerminal(int(os.Stdin.Fd())) || !term.IsTerminal(int(os.Stdout.Fd())) {
		fmt.Fprintln(os.Stderr, "tb-setup needs a terminal; use the plain install script instead.")
		return exitNoTerminal
	}

	file, err := setup.Load(flag.Arg(0))
	if err != nil {
		fmt.Fprintln(os.Stderr, "tb-setup:", err)
		return exitUsage
	}
	store, err := state.Default()
	if err != nil {
		fmt.Fprintln(os.Stderr, "tb-setup: cannot find your home folder:", err)
		return exitUsage
	}
	home, _ := os.UserHomeDir()

	var drv gita.Driver
	if os.Getenv("TB_TUI_DEMO") == "1" {
		drv = demoDriver()
	} else {
		bin, err := gita.Find()
		if err != nil {
			fmt.Fprintln(os.Stderr, "tb-setup: gita was not found. Run the install script first.")
			return exitUsage
		}
		drv = gita.ExecDriver{Bin: bin}
	}

	emails := map[string]string{}
	for _, a := range file.Accounts {
		if e := strings.TrimSpace(os.Getenv("TB_EMAIL_" + strings.ToUpper(a.ID))); e != "" {
			emails[a.ID] = e
		}
	}
	m := ui.New(ui.Config{
		Driver:   drv,
		File:     file,
		FilePath: flag.Arg(0),
		Store:    store,
		Home:     home,
		Dry:      *dry,
		Name:     strings.TrimSpace(os.Getenv("TB_NAME")),
		Emails:   emails,
		Now:      time.Now,
		Client:   tokens.NewClient(),
		APIURL:   "https://api.github.com/user",
	})
	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "tb-setup:", err)
		return 1
	}
	code := m.ExitCode()
	switch code {
	case 0:
		fmt.Println("ThoughtBox setup finished.")
	case 130:
		fmt.Println("ThoughtBox setup stopped.")
	default:
		fmt.Println("ThoughtBox setup did not finish. The log is above; run the setup again after fixing the problem.")
	}
	return code
}

// demoDriver is a made-up Gita, to try the screens without changing anything (TB_TUI_DEMO=1).
func demoDriver() gita.Driver {
	return &gita.Fake{
		VersionText: "1.2.0",
		ProfileList: []gita.Profile{
			{ID: "1", Label: "ThoughtBox", Email: "demo@thoughtbox.io", GithubLogin: "demo-io", SignedIn: true},
			{ID: "2", Label: "ThoughtBox AI", Email: "demo@thoughtbox.one", GithubLogin: "demo-one", SignedIn: true, SignInError: "stopped"},
		},
		DoctorResult: gita.Doctor{OK: true},
		RunLines:     []string{"==> Setting up this computer (demo)", "    Git is installed.", "    Claude Code is installed."},
		AcceptToken:  func(t string) bool { return strings.HasPrefix(t, "ghp_") },
	}
}
