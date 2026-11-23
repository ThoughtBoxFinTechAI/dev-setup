// Package tokens holds the rules for a classic GitHub token: how long it may last,
// what a pasted token looks like, and how to check when GitHub says it expires.
//
// A token is only ever held in memory by the caller and handed to Gita on stdin.
// Nothing in this package logs, prints or stores one.
package tokens

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"
	"unicode"
)

// Choice is one entry of the duration menu. Days is 0 for "no expiry".
type Choice struct {
	Label string
	Days  int
}

// Choices is the duration menu, in display order.
var Choices = []Choice{
	{"30 days", 30},
	{"90 days", 90},
	{"180 days", 180},
	{"1 year (recommended)", 365},
	{"No expiry (not recommended)", 0},
}

// DefaultChoice is the index preselected in the menu: one year.
const DefaultChoice = 3

// URL is GitHub's "new classic token" page with the scopes Gita needs ticked.
// GitHub's documentation only describes pre-filling the expiry for fine-grained
// tokens, so the expiry of a classic token is picked by hand (see WantDate) and
// verified afterwards (see Check).
const URL = "https://github.com/settings/tokens/new?description=Gita&scopes=repo,workflow,read:user,user:email,write:public_key,read:org"

// MaxLength is the longest pasted token that is accepted. GitHub tokens are well under it.
const MaxLength = 255

// WantDate is the date (YYYY-MM-DD) that is days after now, or "" for no expiry.
func WantDate(now time.Time, days int) string {
	if days <= 0 {
		return ""
	}
	return now.AddDate(0, 0, days).Format("2006-01-02")
}

// Kind says what a pasted string looks like, from its prefix.
type Kind int

const (
	Unknown Kind = iota
	Classic
	FineGrained
)

// Classify looks at the prefix only; it does not ask GitHub.
func Classify(token string) Kind {
	switch {
	case strings.HasPrefix(token, "ghp_"):
		return Classic
	case strings.HasPrefix(token, "github_pat_"):
		return FineGrained
	default:
		return Unknown
	}
}

// Clean drops whitespace and control characters from a pasted token and rejects
// one that is empty or longer than MaxLength.
func Clean(s string) (string, error) {
	var b strings.Builder
	for _, r := range s {
		if unicode.IsSpace(r) || unicode.IsControl(r) {
			continue
		}
		b.WriteRune(r)
	}
	out := b.String()
	if out == "" {
		return "", fmt.Errorf("no token was entered")
	}
	if len(out) > MaxLength {
		return "", fmt.Errorf("that is too long to be a GitHub token")
	}
	return out, nil
}

// Outcome is how the token's real expiry compares with what was chosen.
type Outcome int

const (
	// OutcomeOK: expires on the day chosen, or within three days of it.
	OutcomeOK Outcome = iota
	// OutcomeSooner: expires more than three days before the chosen date.
	OutcomeSooner
	// OutcomeNeverButChosen: never expires, though an expiry was chosen.
	OutcomeNeverButChosen
	// OutcomeNone: never expires, as chosen.
	OutcomeNone
	// OutcomeExpiresButNoneChosen: expires, though "no expiry" was chosen.
	OutcomeExpiresButNoneChosen
)

// Compare judges the expiry GitHub reported ("2027-11-23 00:00:00 UTC", or "none")
// against wantDate ("" for no expiry). day is the actual expiry date, if any.
func Compare(actual, wantDate string) (o Outcome, day string) {
	actual = strings.TrimSpace(actual)
	if actual == "" || strings.EqualFold(actual, "none") {
		if wantDate != "" {
			return OutcomeNeverButChosen, ""
		}
		return OutcomeNone, ""
	}
	day = actual
	if i := strings.IndexByte(actual, ' '); i > 0 {
		day = actual[:i]
	}
	if wantDate == "" {
		return OutcomeExpiresButNoneChosen, day
	}
	a, errA := time.Parse("2006-01-02", day)
	w, errW := time.Parse("2006-01-02", wantDate)
	if errA != nil || errW != nil {
		return OutcomeOK, day
	}
	if w.Sub(a) > 3*24*time.Hour {
		return OutcomeSooner, day
	}
	return OutcomeOK, day
}

// Check asks GitHub when the token expires, using the header
// github-authentication-token-expiration on any authenticated API response.
// It returns the header value, or "none" when the header is absent. apiURL is
// https://api.github.com/user in production; tests pass a local server.
func Check(ctx context.Context, client *http.Client, apiURL, token string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, apiURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("could not reach GitHub")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("GitHub answered %d", resp.StatusCode)
	}
	if v := resp.Header.Get("github-authentication-token-expiration"); v != "" {
		return v, nil
	}
	return "none", nil
}

// NewClient returns an HTTPS client with a timeout, for Check.
func NewClient() *http.Client { return &http.Client{Timeout: 30 * time.Second} }
