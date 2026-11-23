package ui

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/ThoughtBoxFinTechAI/dev-setup/tui/internal/gita"
	"github.com/ThoughtBoxFinTechAI/dev-setup/tui/internal/setup"
	"github.com/ThoughtBoxFinTechAI/dev-setup/tui/internal/state"
)

var fixedNow = time.Date(2026, 11, 23, 12, 0, 0, 0, time.UTC)

type harness struct {
	t     *testing.T
	cfg   Config
	fake  *gita.Fake
	mu    sync.Mutex
	msgs  []tea.Msg
	asked []ask
	ans   []reply
	store state.Store
}

// expiry is what the fake GitHub reports for the token's expiry header.
func newHarness(t *testing.T, expiry string) *harness {
	t.Helper()
	f, err := setup.Load("../../../thoughtbox-onboarding.json")
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if expiry != "" {
			w.Header().Set("github-authentication-token-expiration", expiry)
		}
	}))
	t.Cleanup(srv.Close)
	fake := &gita.Fake{
		VersionText: "1.2.0",
		ProfileList: []gita.Profile{
			{ID: "1", Label: "ThoughtBox", Email: "a@thoughtbox.io", GithubLogin: "io", SignedIn: true},
			{ID: "2", Label: "ThoughtBox AI", Email: "a@thoughtbox.one", GithubLogin: "one", SignedIn: true, SignInError: "stopped"},
		},
		DoctorResult: gita.Doctor{OK: true},
		RunLines:     []string{"==> gita output"},
	}
	store := state.Store{Dir: t.TempDir()}
	h := &harness{t: t, fake: fake, store: store}
	h.cfg = Config{
		Driver: fake, File: f, FilePath: "onboarding.json", Store: store, Home: t.TempDir(),
		Now: func() time.Time { return fixedNow }, Client: srv.Client(), APIURL: srv.URL,
		Name: "Tester", Emails: map[string]string{"io": "a@thoughtbox.io", "one": "a@thoughtbox.one"},
	}
	return h
}

func (h *harness) pipeline() *pipeline {
	return &pipeline{
		cfg: h.cfg,
		emit: func(m tea.Msg) {
			h.mu.Lock()
			h.msgs = append(h.msgs, m)
			h.mu.Unlock()
		},
		askFn: func(a ask) reply {
			h.asked = append(h.asked, a)
			if len(h.ans) == 0 {
				h.t.Fatalf("unexpected question: %q", a.title)
			}
			r := h.ans[0]
			h.ans = h.ans[1:]
			return r
		},
	}
}

func (h *harness) logText() string {
	var b strings.Builder
	for _, m := range h.msgs {
		if l, ok := m.(logMsg); ok {
			b.WriteString(l.line + "\n")
		}
	}
	return b.String()
}

func (h *harness) status(i int) stepStatus {
	s := stepPending
	for _, m := range h.msgs {
		if sm, ok := m.(stepMsg); ok && sm.i == i {
			s = sm.status
		}
	}
	return s
}

func TestPipelineTokenSignIn(t *testing.T) {
	h := newHarness(t, "2027-11-23 00:00:00 UTC")
	h.ans = []reply{{idx: 0}, {idx: 3}, {text: " ghp_good123 \n"}} // token, one year, paste
	if !h.pipeline().run(context.Background()) {
		t.Fatalf("setup failed:\n%s", h.logText())
	}
	for i := 0; i < 6; i++ {
		if st := h.status(i); st != stepDone {
			t.Errorf("step %d status %v", i, st)
		}
	}
	if got := h.fake.TokensGot; len(got) != 1 || got[0] != "ghp_good123" {
		t.Fatalf("the token must reach Gita cleaned, once: %q", got)
	}
	log := h.logText()
	if strings.Contains(log, "ghp_good123") {
		t.Fatal("the token appeared in the log")
	}
	for _, want := range []string{"Under Expiration", "2027-11-23", "expires on 2027-11-23"} {
		if !strings.Contains(log, want) {
			t.Errorf("log lacks %q:\n%s", want, log)
		}
	}
	if d, never, known := h.store.DaysLeft("ThoughtBox AI", fixedNow); !known || never || d != 365 {
		t.Fatalf("remembered expiry: %d %v %v", d, never, known)
	}
	// The first run creates profiles without signing in; the second does everything else.
	calls := strings.Join(h.fake.CallList(), "\n")
	if !strings.Contains(calls, "onboard onboarding.json --name Tester") || !strings.Contains(calls, "--skip-sign-in --skip-repos") {
		t.Fatalf("calls:\n%s", calls)
	}
	if !strings.Contains(calls, "sign-in ThoughtBox AI --with-token") {
		t.Fatalf("calls:\n%s", calls)
	}
}

func TestPipelineBadTokensThenGood(t *testing.T) {
	h := newHarness(t, "2026-12-01 00:00:00 UTC") // sooner than a year
	h.ans = []reply{{idx: 0}, {idx: 3}, {text: "nope"}, {text: "ghp_bad1"}, {text: "ghp_good2"}}
	if !h.pipeline().run(context.Background()) {
		t.Fatalf("setup failed:\n%s", h.logText())
	}
	log := h.logText()
	for _, want := range []string{"does not look like a GitHub token", "did not accept that token", "sooner than the 2027-11-23 you chose"} {
		if !strings.Contains(log, want) {
			t.Errorf("log lacks %q:\n%s", want, log)
		}
	}
	for _, tok := range []string{"nope", "ghp_bad1", "ghp_good2"} {
		if strings.Contains(log, tok) {
			t.Errorf("token %q appeared in the log", tok)
		}
	}
	if len(h.fake.TokensGot) != 2 {
		t.Fatalf("only real-looking tokens go to Gita: %q", h.fake.TokensGot)
	}
}

func TestPipelineNoExpiryChoice(t *testing.T) {
	h := newHarness(t, "") // GitHub reports no expiry
	h.ans = []reply{{idx: 0}, {idx: 4}, {text: "ghp_good3"}}
	if !h.pipeline().run(context.Background()) {
		t.Fatal(h.logText())
	}
	if !strings.Contains(h.logText(), "choose \"No expiration\"") || !strings.Contains(h.logText(), "does not expire") {
		t.Fatal(h.logText())
	}
	if _, never, known := h.store.DaysLeft("ThoughtBox AI", fixedNow); !known || !never {
		t.Fatal("a token without expiry must be remembered as such")
	}
}

func TestPipelineFallsBackToBrowserCode(t *testing.T) {
	h := newHarness(t, "")
	h.ans = []reply{{idx: 0}, {idx: 3}, {cancelled: true}} // token chosen, then Esc at the paste
	if !h.pipeline().run(context.Background()) {
		t.Fatal(h.logText())
	}
	if !strings.Contains(strings.Join(h.fake.CallList(), "\n"), "sign-in ThoughtBox AI\n") &&
		!strings.Contains(strings.Join(h.fake.CallList(), "\n"), "sign-in --profile ThoughtBox AI") {
		t.Fatalf("expected the browser-code sign-in:\n%s", strings.Join(h.fake.CallList(), "\n"))
	}
	if len(h.fake.TokensGot) != 0 {
		t.Fatal("no token was entered")
	}
}

func TestPipelineSkipsWorkingSignInsAndDryRun(t *testing.T) {
	h := newHarness(t, "")
	h.fake.ProfileList[1].SignInError = "" // both work
	if !h.pipeline().run(context.Background()) || len(h.asked) != 0 {
		t.Fatalf("a working sign-in needs no question; asked %d", len(h.asked))
	}
	h2 := newHarness(t, "")
	h2.cfg.Dry = true
	if !h2.pipeline().run(context.Background()) || len(h2.asked) != 0 {
		t.Fatal("a dry run asks nothing")
	}
	if !strings.Contains(strings.Join(h2.fake.CallList(), "\n"), "--dry-run") {
		t.Fatal("a dry run must pass --dry-run to gita")
	}
	for _, c := range h2.fake.CallList() {
		if strings.HasPrefix(c, "sign-in") {
			t.Fatalf("a dry run must not sign in: %s", c)
		}
	}
}

func TestPipelineAsksForMissingNameAndEmails(t *testing.T) {
	h := newHarness(t, "")
	h.cfg.Name, h.cfg.Emails = "", nil
	h.fake.ProfileList = nil
	h.ans = []reply{{text: "a@thoughtbox.io"}, {text: "a@thoughtbox.one"}, {text: "Test Person"}}
	// profiles stay empty in the fake, so the sign-in steps are skipped ("no profile"); the run still finishes.
	if !h.pipeline().run(context.Background()) {
		t.Fatal(h.logText())
	}
	calls := strings.Join(h.fake.CallList(), "\n")
	for _, want := range []string{"--name Test Person", "--email io=a@thoughtbox.io", "--email one=a@thoughtbox.one"} {
		if !strings.Contains(calls, want) {
			t.Errorf("calls lack %q:\n%s", want, calls)
		}
	}
}

func TestPipelineStopsOnProblems(t *testing.T) {
	h := newHarness(t, "")
	h.fake.ProfileList[1].SignInError = ""
	h.fake.DoctorResult = gita.Doctor{OK: false, Issues: []gita.Issue{{Message: "a sign-in stopped working"}}}
	if h.pipeline().run(context.Background()) {
		t.Fatal("a failing check must fail the run")
	}
	if !strings.Contains(h.logText(), "a sign-in stopped working") {
		t.Fatal(h.logText())
	}
	h2 := newHarness(t, "")
	h2.fake.RunExit = 7
	if h2.pipeline().run(context.Background()) || h2.status(1) != stepFailed {
		t.Fatal("a gita failure must fail the run at that step")
	}
}

// ---- model

func newModel(t *testing.T) *Model {
	h := newHarness(t, "")
	m := New(h.cfg)
	m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	return m
}

func key(s string) tea.KeyMsg {
	switch s {
	case "enter":
		return tea.KeyMsg{Type: tea.KeyEnter}
	case "esc":
		return tea.KeyMsg{Type: tea.KeyEsc}
	case "tab":
		return tea.KeyMsg{Type: tea.KeyTab}
	case "down":
		return tea.KeyMsg{Type: tea.KeyDown}
	}
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)}
}

func TestViewTooSmallAndResize(t *testing.T) {
	m := newModel(t)
	m.Update(tea.WindowSizeMsg{Width: 60, Height: 20})
	if v := m.View(); !strings.Contains(v, "Make the window larger") {
		t.Fatalf("small window:\n%s", v)
	}
	m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	v := m.View()
	if !strings.Contains(v, "Steps") || !strings.Contains(v, "Press Enter to start") || !strings.Contains(v, "Sign in: ThoughtBox AI") {
		t.Fatalf("setup screen:\n%s", v)
	}
	for _, line := range strings.Split(v, "\n") {
		if len([]rune(line)) > 0 && lipgloss.Width(line) > 100 {
			t.Fatalf("a line is wider than the window (%d): %q", lipgloss.Width(line), line)
		}
	}
}

func TestScreensAndKeys(t *testing.T) {
	m := newModel(t)
	m.Update(key("2"))
	if m.scr != screenDash {
		t.Fatal("2 opens the dashboard")
	}
	if _, cmd := m.Update(key("enter")); cmd != nil {
		t.Fatal("Enter must only start the setup on the Setup screen")
	}
	m.Update(key("tab"))
	if m.scr != screenHelp {
		t.Fatalf("tab goes to the next screen, got %v", m.scr)
	}
	if !strings.Contains(m.View(), "never shown, logged or stored") {
		t.Fatal("the help explains how tokens are handled")
	}
	m.Update(key("1"))
	if _, cmd := m.Update(key("q")); cmd == nil {
		t.Fatal("q quits")
	}
}

func TestSecretModalIsMasked(t *testing.T) {
	m := newModel(t)
	reply := make(chan reply, 1)
	m.Update(askMsg{ask{kind: askSecret, title: "Paste the token", reply: reply}})
	for _, r := range "ghp_topsecret" {
		m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
	v := m.View()
	if strings.Contains(v, "topsecret") || strings.Contains(v, "ghp_") {
		t.Fatalf("the token is visible on screen:\n%s", v)
	}
	if !strings.Contains(v, "•") {
		t.Fatalf("expected masked characters:\n%s", v)
	}
	m.Update(key("enter"))
	if got := (<-reply).text; got != "ghp_topsecret" {
		t.Fatalf("answer %q", got)
	}
	if m.modal != nil {
		t.Fatal("the form closes after Enter")
	}
}

func TestChoiceModalMovesAndEscCancels(t *testing.T) {
	m := newModel(t)
	r := make(chan reply, 1)
	m.Update(askMsg{ask{kind: askChoice, title: "How long?", options: []string{"a", "b", "c"}, def: 2, reply: r}})
	m.Update(key("up"))
	m.Update(key("down"))
	m.Update(tea.KeyMsg{Type: tea.KeyUp})
	m.Update(key("enter"))
	if got := <-r; got.idx != 1 {
		t.Fatalf("expected the middle entry, got %+v", got)
	}
	m.Update(askMsg{ask{kind: askChoice, options: []string{"a"}, reply: r}})
	m.Update(key("esc"))
	if got := <-r; !got.cancelled {
		t.Fatal("Esc cancels")
	}
}

func TestDashboardShowsProblems(t *testing.T) {
	m := newModel(t)
	m.Update(dashData{
		loaded: true, version: "1.2.0", at: fixedNow, doctorOK: true,
		profiles: []gita.Profile{{Label: "ThoughtBox AI", GithubLogin: "one", SignedIn: true, SignInError: "stopped"}},
		doctor:   gita.Doctor{OK: false, Issues: []gita.Issue{{Message: "sign-in stopped working"}}},
		tokens:   map[string]state.Token{"ThoughtBox AI": {Expires: "2026-12-03"}},
		update:   state.Update{Scheduled: true, LastRun: fixedNow.Add(-2 * time.Hour)},
	})
	m.Update(key("2"))
	v := m.View()
	for _, want := range []string{"sign-in stopped working", "renew soon", "scheduled: on", "2 h ago", "Gita 1.2.0"} {
		if !strings.Contains(v, want) {
			t.Errorf("dashboard lacks %q:\n%s", want, v)
		}
	}
	if !strings.Contains(m.View(), "ThoughtBox AI token: 10 days left") {
		t.Errorf("status bar lacks the token summary:\n%s", m.View())
	}
}

func TestLogLinesAreCleaned(t *testing.T) {
	m := newModel(t)
	m.Update(logMsg{"\x1b[31mred\x1b[0m \x1b]0;title\x07text\x00"})
	if got := m.log[0]; got != "red text" {
		t.Fatalf("got %q", got)
	}
}

func TestExitCodes(t *testing.T) {
	m := newModel(t)
	if m.ExitCode() != 0 {
		t.Fatal("0 before anything fails")
	}
	m.Update(doneMsg{failed: true})
	if m.ExitCode() != 1 {
		t.Fatal("1 when the setup failed")
	}
	m.Update(doneMsg{failed: true, cancelled: true})
	if m.ExitCode() != 130 {
		t.Fatal("130 when stopped")
	}
}
