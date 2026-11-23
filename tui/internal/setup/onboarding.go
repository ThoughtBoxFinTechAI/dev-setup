// Package setup reads the onboarding file (thoughtbox-onboarding.json), which says
// which accounts and steps the setup has. The file is pinned by checksum by the
// installers; this package only reads it.
package setup

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

// Account is one GitHub account the setup signs in.
type Account struct {
	ID          string `json:"id"`
	Label       string `json:"label"`
	EmailDomain string `json:"emailDomain"`
	Question    string `json:"question"`
}

// Step is one step of the onboarding file.
type Step struct {
	Type    string `json:"type"`
	Account string `json:"account"`
	URL     string `json:"url"`
}

// File is the parts of the onboarding file the TUI shows.
type File struct {
	Format   int       `json:"format"`
	Name     string    `json:"name"`
	Accounts []Account `json:"accounts"`
	Steps    []Step    `json:"steps"`
}

// maxFileSize caps how much of the file is read.
const maxFileSize = 1 << 20

// Load reads and checks the onboarding file at path.
func Load(path string) (*File, error) {
	st, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read the onboarding file: %w", err)
	}
	if st.Size() > maxFileSize {
		return nil, fmt.Errorf("the onboarding file is too large")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read the onboarding file: %w", err)
	}
	var f File
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, fmt.Errorf("the onboarding file is not valid JSON")
	}
	if len(f.Accounts) == 0 {
		return nil, fmt.Errorf("the onboarding file has no accounts")
	}
	for i := range f.Accounts {
		a := &f.Accounts[i]
		a.ID, a.Label = Sanitize(a.ID), Sanitize(a.Label)
		a.EmailDomain, a.Question = Sanitize(a.EmailDomain), Sanitize(a.Question)
		if a.ID == "" || a.Label == "" {
			return nil, fmt.Errorf("an account in the onboarding file has no id or label")
		}
	}
	return &f, nil
}

// Sanitize removes control characters (including escape sequences' introducer)
// from text that comes from a file or a program, before it is shown.
func Sanitize(s string) string {
	return strings.Map(func(r rune) rune {
		if r < 0x20 && r != '\t' || r == 0x7f || (r >= 0x80 && r < 0xa0) {
			return -1
		}
		return r
	}, s)
}

// Account returns the account with the given id.
func (f *File) Account(id string) (Account, bool) {
	for _, a := range f.Accounts {
		if a.ID == id {
			return a, true
		}
	}
	return Account{}, false
}
