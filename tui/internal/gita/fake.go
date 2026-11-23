package gita

import (
	"context"
	"fmt"
	"strings"
	"sync"
)

// Fake is a Driver for tests and for the demo mode (TB_TUI_DEMO=1). It records what it
// was asked and answers from its fields.
type Fake struct {
	mu sync.Mutex

	VersionText  string
	ProfileList  []Profile
	DoctorResult Doctor
	// AcceptToken decides whether SignInToken succeeds; nil accepts tokens that start with "ghp_good".
	AcceptToken func(token string) bool
	// RunLines are printed by every Run; RunExit is its exit code.
	RunLines []string
	RunExit  int

	Calls     []string // one entry per call, without any token
	TokensGot []string // tokens that arrived on "stdin", for tests to check
}

func (f *Fake) record(s string) {
	f.mu.Lock()
	f.Calls = append(f.Calls, s)
	f.mu.Unlock()
}

// Version implements Driver.
func (f *Fake) Version(context.Context) (string, error) {
	f.record("version")
	if f.VersionText == "" {
		return "1.2.0", nil
	}
	return f.VersionText, nil
}

// Profiles implements Driver.
func (f *Fake) Profiles(context.Context) ([]Profile, error) {
	f.record("profiles")
	return f.ProfileList, nil
}

// Doctor implements Driver.
func (f *Fake) Doctor(context.Context) (Doctor, error) {
	f.record("doctor")
	return f.DoctorResult, nil
}

// SignInToken implements Driver.
func (f *Fake) SignInToken(_ context.Context, profile, token string) (string, error) {
	f.record("sign-in " + profile + " --with-token")
	f.mu.Lock()
	f.TokensGot = append(f.TokensGot, token)
	f.mu.Unlock()
	ok := strings.HasPrefix(token, "ghp_good")
	if f.AcceptToken != nil {
		ok = f.AcceptToken(token)
	}
	if !ok {
		return "GitHub rejected the token.", fmt.Errorf("GitHub did not accept that token")
	}
	return "Done: signed in as @fake.", nil
}

// Run implements Driver.
func (f *Fake) Run(_ context.Context, args []string, onLine func(string)) (int, error) {
	f.record(strings.Join(args, " "))
	for _, l := range f.RunLines {
		onLine(l)
	}
	return f.RunExit, nil
}

// CallList returns a copy of the recorded calls.
func (f *Fake) CallList() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.Calls...)
}
