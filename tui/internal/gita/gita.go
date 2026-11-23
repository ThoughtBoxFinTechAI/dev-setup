// Package gita runs the gita command for the TUI. The TUI never decides what the setup
// does and never touches the key store: it asks Gita through its documented commands.
//
// A token is handed to "gita sign-in --with-token" on standard input only, never as an
// argument or an environment variable, and nothing here logs it.
package gita

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"
)

// Profile is one entry of "gita profiles --json".
type Profile struct {
	ID          string `json:"id"`
	Label       string `json:"label"`
	Name        string `json:"name"`
	Email       string `json:"email"`
	GithubLogin string `json:"githubLogin"`
	SignedIn    bool   `json:"signedIn"`
	SignInError string `json:"signInError"`
}

// Issue is one problem reported by "gita doctor --json".
type Issue struct {
	Category string `json:"category"`
	Severity string `json:"severity"`
	Message  string `json:"message"`
}

// Doctor is the result of "gita doctor".
type Doctor struct {
	OK     bool
	Issues []Issue
}

// Driver is what the TUI needs from Gita. ExecDriver runs the real command; Fake is for tests.
type Driver interface {
	// Version returns Gita's version, for example "1.2.0".
	Version(ctx context.Context) (string, error)
	Profiles(ctx context.Context) ([]Profile, error)
	Doctor(ctx context.Context) (Doctor, error)
	// SignInToken saves a token for the profile (through stdin) and returns Gita's message.
	SignInToken(ctx context.Context, profile, token string) (string, error)
	// Run runs gita with args and with no input, calling onLine for each line of output
	// (already free of terminal escape sequences). It returns the exit code.
	Run(ctx context.Context, args []string, onLine func(string)) (int, error)
}

// ExecDriver runs the gita program at Bin.
type ExecDriver struct{ Bin string }

// Find locates gita: $TB_GITA, then ~/.gita/bin, then PATH.
func Find() (string, error) {
	if p := os.Getenv("TB_GITA"); p != "" {
		return p, nil
	}
	name := "gita"
	if runtime.GOOS == "windows" {
		name = "gita.exe"
	}
	if home, err := os.UserHomeDir(); err == nil {
		p := filepath.Join(home, ".gita", "bin", name)
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p, nil
		}
	}
	return exec.LookPath(name)
}

var ansi = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[@-Z\\-_]`)

// Clean removes terminal escape sequences and other control characters from program output.
func Clean(s string) string {
	s = ansi.ReplaceAllString(s, "")
	return strings.Map(func(r rune) rune {
		if r == '\t' {
			return ' '
		}
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) {
			return -1
		}
		return r
	}, s)
}

func (d ExecDriver) output(ctx context.Context, stdin io.Reader, args ...string) ([]byte, int, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, d.Bin, args...)
	cmd.Stdin = stdin
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err := cmd.Run()
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return out.Bytes(), ee.ExitCode(), nil
	}
	if err != nil {
		return nil, -1, fmt.Errorf("could not run gita: %w", err)
	}
	return out.Bytes(), 0, nil
}

// Version implements Driver.
func (d ExecDriver) Version(ctx context.Context) (string, error) {
	b, code, err := d.output(ctx, nil, "--version")
	if err != nil {
		return "", err
	}
	v := strings.TrimSpace(Clean(string(b)))
	if code != 0 || !strings.HasPrefix(v, "gita ") {
		return "", fmt.Errorf("gita does not start (exit code %d)", code)
	}
	return strings.TrimPrefix(v, "gita "), nil
}

// Profiles implements Driver.
func (d ExecDriver) Profiles(ctx context.Context) ([]Profile, error) {
	b, code, err := d.output(ctx, nil, "profiles", "--json")
	if err != nil {
		return nil, err
	}
	var r struct {
		OK       bool      `json:"ok"`
		Profiles []Profile `json:"profiles"`
	}
	if jerr := json.Unmarshal(b, &r); jerr != nil || code != 0 {
		return nil, fmt.Errorf("could not read the profiles from gita")
	}
	for i := range r.Profiles {
		p := &r.Profiles[i]
		p.Label, p.Name, p.Email = Clean(p.Label), Clean(p.Name), Clean(p.Email)
		p.GithubLogin, p.SignInError = Clean(p.GithubLogin), Clean(p.SignInError)
	}
	return r.Profiles, nil
}

// Doctor implements Driver.
func (d ExecDriver) Doctor(ctx context.Context) (Doctor, error) {
	b, _, err := d.output(ctx, nil, "doctor", "--json")
	if err != nil {
		return Doctor{}, err
	}
	var r struct {
		OK     bool    `json:"ok"`
		Issues []Issue `json:"issues"`
	}
	if jerr := json.Unmarshal(b, &r); jerr != nil {
		return Doctor{}, fmt.Errorf("could not read gita's check result")
	}
	for i := range r.Issues {
		r.Issues[i].Message = Clean(r.Issues[i].Message)
	}
	return Doctor{OK: r.OK, Issues: r.Issues}, nil
}

// SignInToken implements Driver. The token goes in on stdin.
func (d ExecDriver) SignInToken(ctx context.Context, profile, token string) (string, error) {
	b, code, err := d.output(ctx, strings.NewReader(token), "sign-in", "--profile", profile, "--with-token", "--force")
	msg := strings.TrimSpace(Clean(string(b)))
	// Gita never prints a token, but make sure one cannot reach the screen or the log.
	msg = strings.ReplaceAll(msg, token, "[token]")
	if err != nil {
		return "", err
	}
	if code != 0 {
		return msg, fmt.Errorf("GitHub did not accept that token")
	}
	return msg, nil
}

// Run implements Driver.
func (d ExecDriver) Run(ctx context.Context, args []string, onLine func(string)) (int, error) {
	cmd := exec.CommandContext(ctx, d.Bin, args...)
	pr, pw := io.Pipe()
	cmd.Stdout, cmd.Stderr = pw, pw
	if err := cmd.Start(); err != nil {
		return -1, fmt.Errorf("could not run gita: %w", err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		sc := bufio.NewScanner(pr)
		sc.Buffer(make([]byte, 64*1024), 1<<20)
		for sc.Scan() {
			if line := Clean(sc.Text()); strings.TrimSpace(line) != "" {
				onLine(line)
			}
		}
	}()
	err := cmd.Wait()
	_ = pw.Close()
	<-done
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode(), nil
	}
	if err != nil {
		return -1, err
	}
	return 0, nil
}
