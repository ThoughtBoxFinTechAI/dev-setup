package ui

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/ThoughtBoxFinTechAI/dev-setup/tui/internal/gita"
	"github.com/ThoughtBoxFinTechAI/dev-setup/tui/internal/setup"
	"github.com/ThoughtBoxFinTechAI/dev-setup/tui/internal/state"
	"github.com/ThoughtBoxFinTechAI/dev-setup/tui/internal/tokens"
)

// Config is everything the TUI needs from outside.
type Config struct {
	Driver   gita.Driver
	File     *setup.File
	FilePath string
	Store    state.Store
	Home     string
	Dry      bool
	Name     string            // from TB_NAME, may be empty
	Emails   map[string]string // account id -> email, from TB_EMAIL_*, may be empty
	Now      func() time.Time
	Client   *http.Client
	APIURL   string // https://api.github.com/user
}

type stepStatus int

const (
	stepPending stepStatus = iota
	stepRunning
	stepDone
	stepFailed
	stepSkipped
)

// Messages the pipeline sends to the UI.
type (
	logMsg  struct{ line string }
	stepMsg struct {
		i      int
		status stepStatus
		note   string
	}
	codeMsg struct{ code string }
	askMsg  struct{ a ask }
	doneMsg struct {
		failed    bool
		cancelled bool
	}
)

type askKind int

const (
	askChoice askKind = iota
	askText
	askSecret
)

// ask is a question for the person at the keyboard.
type ask struct {
	kind    askKind
	title   string
	help    string
	options []string
	def     int
	reply   chan reply
}

type reply struct {
	idx       int
	text      string
	cancelled bool
}

// pipeline runs the setup in the background and talks to the UI only through emit and asker.
type pipeline struct {
	cfg   Config
	emit  func(tea.Msg)
	askFn func(ask) reply
}

func (p *pipeline) log(format string, a ...any) {
	p.emit(logMsg{fmt.Sprintf(format, a...)})
}

func (p *pipeline) step(i int, s stepStatus, note string) { p.emit(stepMsg{i, s, note}) }

// stepNames lists the steps shown on the left, in order.
func stepNames(f *setup.File) []string {
	names := []string{"Gita", "Profiles"}
	for _, a := range f.Accounts {
		names = append(names, "Sign in: "+a.Label)
	}
	return append(names, "Tools and repositories", "Check")
}

func (p *pipeline) onboardArgs(extra ...string) []string {
	args := []string{"onboard", p.cfg.FilePath}
	if p.cfg.Name != "" {
		args = append(args, "--name", p.cfg.Name)
	}
	for _, a := range p.cfg.File.Accounts {
		if e := p.cfg.Emails[a.ID]; e != "" {
			args = append(args, "--email", a.ID+"="+e)
		}
	}
	if p.cfg.Dry {
		args = append(args, "--dry-run")
	}
	return append(args, extra...)
}

func profileFor(profiles []gita.Profile, a setup.Account) (gita.Profile, bool) {
	for _, pr := range profiles {
		if a.EmailDomain != "" && strings.HasSuffix(strings.ToLower(pr.Email), "@"+strings.ToLower(a.EmailDomain)) {
			return pr, true
		}
	}
	return gita.Profile{}, false
}

// run does the whole setup. It returns true when every step worked.
func (p *pipeline) run(ctx context.Context) (ok bool) {
	drv, f := p.cfg.Driver, p.cfg.File
	fail := func(i int, note string) bool {
		p.step(i, stepFailed, note)
		p.log("x %s", note)
		return false
	}

	// 0. Gita
	p.step(0, stepRunning, "")
	ver, err := drv.Version(ctx)
	if err != nil {
		return fail(0, err.Error())
	}
	p.log("Gita %s is installed and runs.", ver)
	p.step(0, stepDone, ver)

	// 1. Profiles (no sign-in yet, no repositories)
	p.step(1, stepRunning, "")
	existing, _ := drv.Profiles(ctx)
	for _, a := range f.Accounts {
		if _, have := profileFor(existing, a); have || p.cfg.Emails[a.ID] != "" {
			continue
		}
		r := p.askFn(ask{kind: askText, title: a.Label + ": your email", help: a.Question})
		if r.cancelled {
			return fail(1, "cancelled")
		}
		if p.cfg.Emails == nil {
			p.cfg.Emails = map[string]string{}
		}
		p.cfg.Emails[a.ID] = strings.TrimSpace(r.text)
	}
	if p.cfg.Name == "" && len(existing) == 0 {
		r := p.askFn(ask{kind: askText, title: "Your full name", help: "Used for your git commits."})
		if r.cancelled {
			return fail(1, "cancelled")
		}
		p.cfg.Name = strings.TrimSpace(r.text)
	}
	code, err := drv.Run(ctx, p.onboardArgs("--skip-sign-in", "--skip-repos"), func(l string) { p.log("%s", l) })
	if err != nil || code != 0 {
		return fail(1, fmt.Sprintf("gita stopped with exit code %d", code))
	}
	p.step(1, stepDone, "")

	// 2.. Sign in, one account at a time
	profiles, _ := drv.Profiles(ctx)
	for i, a := range f.Accounts {
		si := 2 + i
		if p.cfg.Dry {
			p.step(si, stepSkipped, "dry run")
			continue
		}
		p.step(si, stepRunning, "")
		pr, found := profileFor(profiles, a)
		switch {
		case !found:
			p.step(si, stepSkipped, "no profile")
		case pr.SignedIn && pr.SignInError == "":
			p.log("%s is signed in as @%s.", a.Label, pr.GithubLogin)
			p.step(si, stepDone, "signed in")
		default:
			if !p.signIn(ctx, a, pr, si) {
				return false
			}
		}
	}

	// Tools and repositories: the full onboarding run
	ti := 2 + len(f.Accounts)
	p.step(ti, stepRunning, "")
	code, err = drv.Run(ctx, p.onboardArgs("--skip-sign-in"), func(l string) { p.log("%s", l) })
	if err != nil || code != 0 {
		return fail(ti, fmt.Sprintf("gita stopped with exit code %d", code))
	}
	p.step(ti, stepDone, "")

	// Check
	ci := ti + 1
	p.step(ci, stepRunning, "")
	d, err := drv.Doctor(ctx)
	if err != nil {
		return fail(ci, err.Error())
	}
	if !d.OK {
		for _, is := range d.Issues {
			p.log("! %s", is.Message)
		}
		p.step(ci, stepFailed, fmt.Sprintf("%d problem(s)", len(d.Issues)))
		return false
	}
	p.log("Gita's check: all good.")
	p.step(ci, stepDone, "")
	return true
}

// signIn asks how to sign an account in and does it. false means the setup should stop.
func (p *pipeline) signIn(ctx context.Context, a setup.Account, pr gita.Profile, si int) bool {
	why := "has no GitHub sign-in yet"
	if pr.SignInError != "" {
		why = "has a sign-in that stopped working"
	}
	r := p.askFn(ask{
		kind:    askChoice,
		title:   fmt.Sprintf("%s %s. How do you want to sign in?", a.Label, why),
		help:    "A classic token is not cancelled when you sign in elsewhere, and lasts as long as you choose.",
		options: []string{"Classic token (recommended)", "Browser code", "Skip for now"},
	})
	if r.cancelled {
		p.step(si, stepFailed, "cancelled")
		return false
	}
	switch r.idx {
	case 0:
		if p.tokenSignIn(ctx, a, pr, si) {
			return true
		}
		// A token was not saved: use the browser code instead, as the scripts do.
		p.log("Using the browser code for %s.", a.Label)
		fallthrough
	case 1:
		code, err := p.cfg.Driver.Run(ctx, []string{"sign-in", "--profile", pr.Label}, func(l string) {
			p.log("%s", l)
			if i := strings.Index(l, "Enter this code:"); i >= 0 {
				p.emit(codeMsg{strings.TrimSpace(l[i+len("Enter this code:"):])})
			}
		})
		p.emit(codeMsg{""})
		if err != nil || code != 0 {
			p.step(si, stepFailed, "sign-in failed")
			return false
		}
		p.step(si, stepDone, "browser code")
		return true
	default:
		p.step(si, stepSkipped, "skipped")
		return true
	}
}

// tokenSignIn returns true when a token was saved.
func (p *pipeline) tokenSignIn(ctx context.Context, a setup.Account, pr gita.Profile, si int) bool {
	days := p.askFn(ask{kind: askChoice, title: "How long should the token last?", options: labels(tokens.Choices), def: tokens.DefaultChoice})
	if days.cancelled {
		return false
	}
	choice := tokens.Choices[days.idx]
	now := p.cfg.Now()
	want := tokens.WantDate(now, choice.Days)
	p.log("Create a classic token while signed in to GitHub as the %s account (the scopes are ticked for you):", a.Label)
	p.log("  %s", tokens.URL)
	if want == "" {
		p.log("Under Expiration, choose \"No expiration\".")
	} else {
		p.log("Under Expiration, pick \"Custom\" and set %s (%d days), or the closest choice.", want, choice.Days)
	}
	for try := 1; try <= 3; try++ {
		r := p.askFn(ask{kind: askSecret, title: fmt.Sprintf("Paste the token for %s", a.Label), help: "Nothing is shown while you type. Esc to use the browser code."})
		if r.cancelled || strings.TrimSpace(r.text) == "" {
			return false
		}
		tok, err := tokens.Clean(r.text)
		if err != nil {
			p.log("! %s", err)
			continue
		}
		switch tokens.Classify(tok) {
		case tokens.Unknown:
			p.log("! That does not look like a GitHub token (a classic one starts with ghp_).")
			continue
		case tokens.FineGrained:
			p.log("! That is a fine-grained token. A classic token (ghp_...) is expected; fine-grained ones can miss scopes Gita needs.")
		}
		msg, err := p.cfg.Driver.SignInToken(ctx, pr.Label, tok)
		if msg != "" {
			p.log("%s", msg)
		}
		if err != nil {
			p.log("! GitHub did not accept that token.")
			continue
		}
		p.reportExpiry(ctx, tok, want, pr.Label, now)
		p.step(si, stepDone, "token")
		return true
	}
	p.log("Giving up on a token for %s.", a.Label)
	return false
}

func (p *pipeline) reportExpiry(ctx context.Context, tok, want, label string, now time.Time) {
	actual, err := tokens.Check(ctx, p.cfg.Client, p.cfg.APIURL, tok)
	if err != nil {
		p.log("Could not ask GitHub when this token expires.")
		_ = p.cfg.Store.SaveToken(label, want, now) // remember what was chosen
		return
	}
	o, day := tokens.Compare(actual, want)
	switch o {
	case tokens.OutcomeOK:
		p.log("This token expires on %s. Run the setup again before then to renew it.", day)
	case tokens.OutcomeSooner:
		p.log("! This token expires on %s, sooner than the %s you chose. Run the setup again before then, or create a longer one.", day, want)
	case tokens.OutcomeNeverButChosen:
		p.log("! This token never expires, but you chose %s. Fine, or create a new one with an expiry.", want)
	case tokens.OutcomeNone:
		p.log("This token does not expire.")
	case tokens.OutcomeExpiresButNoneChosen:
		p.log("! This token expires on %s, but you chose no expiry.", day)
	}
	_ = p.cfg.Store.SaveToken(label, day, now)
}

func labels(cs []tokens.Choice) []string {
	out := make([]string, len(cs))
	for i, c := range cs {
		out[i] = c.Label
	}
	return out
}
