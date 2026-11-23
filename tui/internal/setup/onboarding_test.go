package setup

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadRealOnboardingFile(t *testing.T) {
	f, err := Load("../../../thoughtbox-onboarding.json")
	if err != nil {
		t.Fatal(err)
	}
	if len(f.Accounts) != 2 || f.Accounts[0].Label != "ThoughtBox" || f.Accounts[1].EmailDomain != "thoughtbox.one" {
		t.Fatalf("unexpected accounts: %+v", f.Accounts)
	}
	if _, ok := f.Account("one"); !ok {
		t.Fatal("account one not found")
	}
}

func TestLoadRejectsBadFiles(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	for name, body := range map[string]string{
		"notjson": "{",
		"empty":   `{"format":1,"accounts":[]}`,
		"nolabel": `{"format":1,"accounts":[{"id":"x"}]}`,
	} {
		if _, err := Load(write(name, body)); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
	if _, err := Load(filepath.Join(dir, "missing")); err == nil {
		t.Error("missing file: expected an error")
	}
}

func TestSanitizeStripsControlCharacters(t *testing.T) {
	if got := Sanitize("Thought\x1b[31mBox\x07\n"); got != "Thought[31mBox" {
		t.Fatalf("got %q", got)
	}
}
