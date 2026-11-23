// Package state keeps the small amount of data the TUI remembers between runs, in
// ~/.thoughtbox: when each saved token expires (the date only, never the token) and what
// the daily update has done. It is also where the dashboard reads the update log and the
// schedule from.
package state

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"time"
)

// Token is what is remembered about a token saved for a profile. Never the token itself.
type Token struct {
	Expires string `json:"expires"` // YYYY-MM-DD; "" means it never expires
	Saved   string `json:"saved"`   // YYYY-MM-DD
}

// Store is the ~/.thoughtbox folder.
type Store struct{ Dir string }

// Default returns the store in the user's home folder.
func Default() (Store, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return Store{}, err
	}
	return Store{Dir: filepath.Join(home, ".thoughtbox")}, nil
}

func (s Store) tokensPath() string { return filepath.Join(s.Dir, "tokens.json") }

// Tokens returns the remembered token dates by profile label.
func (s Store) Tokens() map[string]Token {
	out := map[string]Token{}
	b, err := os.ReadFile(s.tokensPath())
	if err != nil {
		return out
	}
	_ = json.Unmarshal(b, &out)
	return out
}

// SaveToken remembers when the token for a profile expires (expires "" for never).
func (s Store) SaveToken(profile, expires string, now time.Time) error {
	all := s.Tokens()
	all[profile] = Token{Expires: expires, Saved: now.Format("2006-01-02")}
	b, err := json.MarshalIndent(all, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(s.Dir, 0o700); err != nil {
		return err
	}
	// Write next to the target, then rename: a half-written file is never left behind.
	tmp, err := os.CreateTemp(s.Dir, "tokens-*.tmp")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err := os.Chmod(name, 0o600); err != nil && runtime.GOOS != "windows" {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(name, s.tokensPath())
}

// DaysLeft says how many whole days remain until the token for profile expires.
// known is false when nothing is remembered; never is true for a token without expiry.
func (s Store) DaysLeft(profile string, now time.Time) (days int, never, known bool) {
	t, ok := s.Tokens()[profile]
	if !ok {
		return 0, false, false
	}
	if t.Expires == "" {
		return 0, true, true
	}
	d, err := time.Parse("2006-01-02", t.Expires)
	if err != nil {
		return 0, false, false
	}
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	return int(d.Sub(today).Hours() / 24), false, true
}

// Update describes the daily update.
type Update struct {
	Scheduled bool      // the update wrapper exists (written by --schedule, removed by --unschedule)
	LastRun   time.Time // when the update log was last written; zero if never
	Running   bool      // the update lock is held
}

// UpdateInfo reads the update state. home is the user's home folder.
func (s Store) UpdateInfo(home string) Update {
	var u Update
	for _, name := range []string{"auto-update.sh", "auto-update.ps1"} {
		if _, err := os.Stat(filepath.Join(s.Dir, name)); err == nil {
			u.Scheduled = true
		}
	}
	if st, err := os.Stat(filepath.Join(home, ".thoughtbox-update.log")); err == nil {
		u.LastRun = st.ModTime()
	}
	if _, err := os.Stat(filepath.Join(s.Dir, "update.lock")); err == nil {
		u.Running = true
	}
	return u
}

// Labels returns the profile labels that have a remembered token, sorted.
func (s Store) Labels() []string {
	var out []string
	for k := range s.Tokens() {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// ErrNone is returned where there is nothing to show.
var ErrNone = errors.New("nothing recorded")
