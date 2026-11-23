package state

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestTokenDatesRoundTripAndNeverStoreAToken(t *testing.T) {
	s := Store{Dir: filepath.Join(t.TempDir(), ".thoughtbox")}
	now := time.Date(2026, 11, 23, 10, 0, 0, 0, time.UTC)
	if err := s.SaveToken("ThoughtBox", "2027-11-23", now); err != nil {
		t.Fatal(err)
	}
	if err := s.SaveToken("ThoughtBox AI", "", now); err != nil {
		t.Fatal(err)
	}
	if d, never, known := s.DaysLeft("ThoughtBox", now); !known || never || d != 365 {
		t.Fatalf("days left: %d %v %v", d, never, known)
	}
	if _, never, known := s.DaysLeft("ThoughtBox AI", now); !known || !never {
		t.Fatalf("no-expiry token: never=%v known=%v", never, known)
	}
	if _, _, known := s.DaysLeft("Other", now); known {
		t.Fatal("an unknown profile must not be known")
	}
	b, _ := os.ReadFile(filepath.Join(s.Dir, "tokens.json"))
	if len(b) == 0 || string(b) == "" {
		t.Fatal("tokens.json was not written")
	}
	if st, _ := os.Stat(filepath.Join(s.Dir, "tokens.json")); st.Mode().Perm()&0o077 != 0 && os.PathSeparator == '/' {
		t.Fatalf("tokens.json must be private, mode %v", st.Mode())
	}
	left, _ := filepath.Glob(filepath.Join(s.Dir, "tokens-*.tmp"))
	if len(left) != 0 {
		t.Fatalf("temporary files left behind: %v", left)
	}
}

func TestUpdateInfo(t *testing.T) {
	home := t.TempDir()
	s := Store{Dir: filepath.Join(home, ".thoughtbox")}
	if u := s.UpdateInfo(home); u.Scheduled || !u.LastRun.IsZero() || u.Running {
		t.Fatalf("empty state: %+v", u)
	}
	_ = os.MkdirAll(filepath.Join(s.Dir, "update.lock"), 0o700)
	_ = os.WriteFile(filepath.Join(s.Dir, "auto-update.sh"), []byte("x"), 0o700)
	_ = os.WriteFile(filepath.Join(home, ".thoughtbox-update.log"), []byte("x"), 0o600)
	u := s.UpdateInfo(home)
	if !u.Scheduled || u.LastRun.IsZero() || !u.Running {
		t.Fatalf("filled state: %+v", u)
	}
}
