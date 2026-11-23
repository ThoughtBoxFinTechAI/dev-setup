package tokens

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestWantDate(t *testing.T) {
	now := time.Date(2026, 11, 23, 15, 0, 0, 0, time.UTC)
	if got := WantDate(now, 365); got != "2027-11-23" {
		t.Fatalf("365 days: %s", got)
	}
	if got := WantDate(now, 180); got != "2027-05-22" {
		t.Fatalf("180 days: %s", got)
	}
	if got := WantDate(now, 0); got != "" {
		t.Fatalf("no expiry should give an empty date, got %q", got)
	}
}

func TestDefaultIsOneYear(t *testing.T) {
	if c := Choices[DefaultChoice]; c.Days != 365 {
		t.Fatalf("default choice is %+v", c)
	}
}

func TestClassify(t *testing.T) {
	cases := map[string]Kind{"ghp_abc": Classic, "github_pat_abc": FineGrained, "gho_abc": Unknown, "": Unknown, "abc": Unknown}
	for in, want := range cases {
		if got := Classify(in); got != want {
			t.Errorf("Classify(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestClean(t *testing.T) {
	got, err := Clean("  ghp_abc\r\n\t123 \x1b[A")
	if err != nil || got != "ghp_abc123[A" {
		// control characters are dropped, printable ones kept
		t.Fatalf("got %q, %v", got, err)
	}
	if _, err := Clean(" \n "); err == nil {
		t.Fatal("empty input must be refused")
	}
	if _, err := Clean(strings.Repeat("a", MaxLength+1)); err == nil {
		t.Fatal("over-long input must be refused")
	}
}

func TestCompare(t *testing.T) {
	cases := []struct {
		actual, want string
		outcome      Outcome
		day          string
	}{
		{"2027-11-23 00:00:00 UTC", "2027-11-23", OutcomeOK, "2027-11-23"},
		{"2027-11-21 00:00:00 UTC", "2027-11-23", OutcomeOK, "2027-11-21"}, // within 3 days
		{"2026-12-01 00:00:00 UTC", "2027-11-23", OutcomeSooner, "2026-12-01"},
		{"none", "2027-11-23", OutcomeNeverButChosen, ""},
		{"none", "", OutcomeNone, ""},
		{"2027-01-01 00:00:00 UTC", "", OutcomeExpiresButNoneChosen, "2027-01-01"},
	}
	for _, c := range cases {
		o, day := Compare(c.actual, c.want)
		if o != c.outcome || day != c.day {
			t.Errorf("Compare(%q,%q) = %v,%q want %v,%q", c.actual, c.want, o, day, c.outcome, c.day)
		}
	}
}

func TestCheck(t *testing.T) {
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		if r.Method != http.MethodHead {
			t.Errorf("method %s", r.Method)
		}
		switch gotAuth {
		case "Bearer ghp_good":
			w.Header().Set("github-authentication-token-expiration", "2027-11-23 00:00:00 UTC")
		case "Bearer ghp_noexp":
		default:
			w.WriteHeader(http.StatusUnauthorized)
		}
	}))
	defer srv.Close()
	ctx := context.Background()
	if v, err := Check(ctx, srv.Client(), srv.URL, "ghp_good"); err != nil || v != "2027-11-23 00:00:00 UTC" {
		t.Fatalf("good: %q %v", v, err)
	}
	if v, err := Check(ctx, srv.Client(), srv.URL, "ghp_noexp"); err != nil || v != "none" {
		t.Fatalf("no expiry: %q %v", v, err)
	}
	_, err := Check(ctx, srv.Client(), srv.URL, "ghp_bad")
	if err == nil || strings.Contains(err.Error(), "ghp_bad") {
		t.Fatalf("a rejected token must give an error that does not contain it: %v", err)
	}
}
