package ui

import (
	"context"
	"fmt"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/ThoughtBoxFinTechAI/dev-setup/tui/internal/gita"
	"github.com/ThoughtBoxFinTechAI/dev-setup/tui/internal/state"
)

type dashData struct {
	loaded   bool
	err      string
	version  string
	profiles []gita.Profile
	doctor   gita.Doctor
	doctorOK bool // doctor was asked
	tokens   map[string]state.Token
	update   state.Update
	at       time.Time
}

type dashTickMsg struct{}

// dashTick refreshes the dashboard every minute. Nothing is fetched from the network here.
func dashTick() tea.Cmd {
	return tea.Tick(time.Minute, func(time.Time) tea.Msg { return dashTickMsg{} })
}

func loadDash(cfg Config) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := contextWithTimeout()
		defer cancel()
		d := dashData{loaded: true, at: cfg.Now(), tokens: cfg.Store.Tokens(), update: cfg.Store.UpdateInfo(cfg.Home)}
		var err error
		if d.version, err = cfg.Driver.Version(ctx); err != nil {
			d.err = err.Error()
			return d
		}
		if d.profiles, err = cfg.Driver.Profiles(ctx); err != nil {
			d.err = err.Error()
		}
		if doc, err := cfg.Driver.Doctor(ctx); err == nil {
			d.doctor, d.doctorOK = doc, true
		}
		return d
	}
}

// tokenSummary is the status-bar text about token expiry: the soonest one.
func (d dashData) tokenSummary(now time.Time) string {
	best, name := 1<<30, ""
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	for label, t := range d.tokens {
		if t.Expires == "" {
			continue
		}
		e, err := time.Parse("2006-01-02", t.Expires)
		if err != nil {
			continue
		}
		if days := int(e.Sub(today).Hours() / 24); days < best {
			best, name = days, label
		}
	}
	if name == "" {
		return ""
	}
	if best < 0 {
		return fmt.Sprintf("%s token expired", name)
	}
	return fmt.Sprintf("%s token: %d days left", name, best)
}

func ago(t, now time.Time) string {
	if t.IsZero() {
		return "never"
	}
	d := now.Sub(t)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%d min ago", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%d h ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%d days ago", int(d.Hours()/24))
	}
}

func (m *Model) dashView(w, h int) string {
	d := m.dash
	if !d.loaded {
		return panel("Dashboard", w, h, "Reading the state of this computer…", true)
	}
	now := m.cfg.Now()
	var sb strings.Builder
	dim := lipgloss.NewStyle().Foreground(cDim)
	ok := lipgloss.NewStyle().Foreground(cOK)
	bad := lipgloss.NewStyle().Foreground(cBad)
	warn := lipgloss.NewStyle().Foreground(cWarn)

	if d.err != "" {
		sb.WriteString(bad.Render("✘ "+d.err) + "\n\n")
	}
	sb.WriteString(fmt.Sprintf("Gita %s\n\n", d.version))
	sb.WriteString(lipgloss.NewStyle().Bold(true).Render("Accounts") + "\n")
	for _, p := range d.profiles {
		state := ok.Render("✔ signed in")
		switch {
		case !p.SignedIn:
			state = warn.Render("– no sign-in")
		case p.SignInError != "":
			state = bad.Render("✘ sign-in stopped working")
		}
		login := p.GithubLogin
		if login != "" {
			login = "@" + login
		}
		line := fmt.Sprintf("  %-16s %-22s %s", trunc(p.Label, 16), trunc(login, 22), state)
		if t, found := d.tokens[p.Label]; found {
			line += "   " + dim.Render(expiryText(t, now))
		}
		sb.WriteString(line + "\n")
	}
	if len(d.profiles) == 0 {
		sb.WriteString(dim.Render("  no profiles yet") + "\n")
	}

	sb.WriteString("\n" + lipgloss.NewStyle().Bold(true).Render("Gita's check") + "\n")
	switch {
	case !d.doctorOK:
		sb.WriteString(dim.Render("  not available") + "\n")
	case d.doctor.OK:
		sb.WriteString(ok.Render("  ✔ all good") + "\n")
	default:
		for _, is := range d.doctor.Issues {
			sb.WriteString(bad.Render("  ✘ ") + trunc(is.Message, w-10) + "\n")
		}
	}

	sb.WriteString("\n" + lipgloss.NewStyle().Bold(true).Render("Daily update") + "\n")
	sched := dim.Render("off  (turn on: run the install command and answer yes)")
	if d.update.Scheduled {
		sched = ok.Render("on")
	}
	sb.WriteString("  scheduled: " + sched + "\n")
	last := ago(d.update.LastRun, now)
	if d.update.Running {
		last += "  (running now)"
	}
	sb.WriteString("  last run:  " + last + "\n")
	sb.WriteString("\n" + dim.Render("Updated "+ago(d.at, now)+" · r refresh"))
	return panel("Dashboard", w, h, sb.String(), true)
}

func expiryText(t state.Token, now time.Time) string {
	if t.Expires == "" {
		return "token never expires"
	}
	e, err := time.Parse("2006-01-02", t.Expires)
	if err != nil {
		return ""
	}
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	days := int(e.Sub(today).Hours() / 24)
	switch {
	case days < 0:
		return "token expired " + t.Expires
	case days <= 14:
		return fmt.Sprintf("%d days left: renew soon", days)
	default:
		return fmt.Sprintf("%d days left (%s)", days, t.Expires)
	}
}

func trunc(s string, n int) string {
	if n < 2 || lipgloss.Width(s) <= n {
		return s
	}
	return truncate(s, n)
}

func contextWithTimeout() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 20*time.Second)
}
