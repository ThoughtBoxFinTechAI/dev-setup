// Package ui is the full-screen terminal interface: the setup run (steps and a live log),
// questions as forms, and the status dashboard.
package ui

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/ThoughtBoxFinTechAI/dev-setup/tui/internal/gita"
	"github.com/ThoughtBoxFinTechAI/dev-setup/tui/internal/setup"
	"github.com/ThoughtBoxFinTechAI/dev-setup/tui/internal/tokens"
)

// MinWidth and MinHeight are the smallest terminal the layout works in.
const (
	MinWidth  = 80
	MinHeight = 24
)

const maxLogLines = 2000

type screen int

const (
	screenSetup screen = iota
	screenDash
	screenHelp
)

type phase int

const (
	phaseIdle phase = iota
	phaseRunning
	phaseDone
)

type step struct {
	name   string
	status stepStatus
	note   string
}

type modal struct {
	a     ask
	sel   int
	input textinput.Model
}

// Model is the Bubble Tea model.
type Model struct {
	cfg    Config
	w, h   int
	scr    screen
	phase  phase
	steps  []step
	log    []string
	scroll int // lines scrolled up from the bottom of the log
	code   string
	modal  *modal
	dash   dashData

	events chan tea.Msg
	cancel context.CancelFunc
	// Result of the run, for the exit code.
	failed    bool
	cancelled bool
}

// New returns the model for a setup run.
func New(cfg Config) *Model {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	m := &Model{cfg: cfg, events: make(chan tea.Msg, 64)}
	for _, n := range stepNames(cfg.File) {
		m.steps = append(m.steps, step{name: n})
	}
	return m
}

// ExitCode is 0 when every step worked, 130 when stopped by the person, otherwise 1.
func (m *Model) ExitCode() int {
	switch {
	case m.cancelled:
		return 130
	case m.failed:
		return 1
	default:
		return 0
	}
}

// Init implements tea.Model.
func (m *Model) Init() tea.Cmd { return tea.Batch(loadDash(m.cfg), dashTick()) }

func listen(ch <-chan tea.Msg) tea.Cmd { return func() tea.Msg { return <-ch } }

func (m *Model) start() tea.Cmd {
	ctx, cancel := context.WithCancel(context.Background())
	m.cancel = cancel
	m.phase = phaseRunning
	p := &pipeline{
		cfg:  m.cfg,
		emit: func(msg tea.Msg) { m.events <- msg },
		askFn: func(a ask) reply {
			a.reply = make(chan reply, 1)
			m.events <- askMsg{a}
			select {
			case r := <-a.reply:
				return r
			case <-ctx.Done():
				return reply{cancelled: true}
			}
		},
	}
	go func() {
		ok := p.run(ctx)
		m.events <- doneMsg{failed: !ok, cancelled: ctx.Err() != nil}
	}()
	return listen(m.events)
}

// Update implements tea.Model.
func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		return m, nil

	case logMsg:
		m.addLog(msg.line)
		return m, listen(m.events)
	case stepMsg:
		if msg.i >= 0 && msg.i < len(m.steps) {
			m.steps[msg.i].status, m.steps[msg.i].note = msg.status, setup.Sanitize(msg.note)
		}
		return m, listen(m.events)
	case codeMsg:
		m.code = setup.Sanitize(msg.code)
		return m, listen(m.events)
	case askMsg:
		m.modal = newModal(msg.a)
		return m, tea.Batch(listen(m.events), textinput.Blink)
	case doneMsg:
		m.phase, m.failed, m.cancelled = phaseDone, msg.failed, msg.cancelled
		if m.failed {
			m.addLog("x The setup did not finish. See the lines above, fix the problem and run it again.")
		} else {
			m.addLog("The setup is finished. Press q to leave, or 2 for the dashboard.")
		}
		return m, loadDash(m.cfg)

	case dashData:
		m.dash = msg
		return m, nil
	case dashTickMsg:
		return m, tea.Batch(loadDash(m.cfg), dashTick())

	case tea.KeyMsg:
		if m.modal != nil {
			return m.updateModal(msg)
		}
		return m.updateKeys(msg)
	}
	return m, nil
}

func (m *Model) addLog(line string) {
	m.log = append(m.log, gita.Clean(line))
	if len(m.log) > maxLogLines {
		m.log = m.log[len(m.log)-maxLogLines:]
	}
}

func (m *Model) updateKeys(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c", "q":
		if m.cancel != nil && m.phase == phaseRunning {
			m.cancel()
			m.cancelled = true
		}
		return m, tea.Quit
	case "1":
		m.scr = screenSetup
	case "2":
		m.scr = screenDash
		return m, loadDash(m.cfg)
	case "3", "?":
		m.scr = screenHelp
	case "tab":
		m.scr = (m.scr + 1) % 3
	case "r":
		return m, loadDash(m.cfg)
	case "enter":
		if m.scr == screenSetup && m.phase == phaseIdle {
			return m, m.start()
		}
	case "up", "k":
		if m.scroll < len(m.log) {
			m.scroll++
		}
	case "down", "j":
		if m.scroll > 0 {
			m.scroll--
		}
	case "pgup":
		m.scroll = min(m.scroll+10, len(m.log))
	case "pgdown":
		m.scroll = max(m.scroll-10, 0)
	}
	return m, nil
}

func newModal(a ask) *modal {
	md := &modal{a: a, sel: a.def}
	if a.kind != askChoice {
		ti := textinput.New()
		ti.CharLimit = tokens.MaxLength
		ti.Width = 50
		if a.kind == askSecret {
			ti.EchoMode = textinput.EchoPassword
			ti.EchoCharacter = '•'
		}
		ti.Focus()
		md.input = ti
	}
	return md
}

func (m *Model) answer(r reply) {
	md := m.modal
	m.modal = nil
	md.a.reply <- r
}

func (m *Model) updateModal(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	md := m.modal
	if msg.String() == "ctrl+c" {
		m.answer(reply{cancelled: true})
		if m.cancel != nil {
			m.cancel()
			m.cancelled = true
		}
		return m, tea.Quit
	}
	if md.a.kind == askChoice {
		switch msg.String() {
		case "up", "k":
			if md.sel > 0 {
				md.sel--
			}
		case "down", "j":
			if md.sel < len(md.a.options)-1 {
				md.sel++
			}
		case "enter":
			m.answer(reply{idx: md.sel})
		case "esc":
			m.answer(reply{cancelled: true})
		default:
			if s := msg.String(); len(s) == 1 && s[0] >= '1' && int(s[0]-'1') < len(md.a.options) {
				md.sel = int(s[0] - '1')
			}
		}
		return m, nil
	}
	switch msg.String() {
	case "enter":
		m.answer(reply{text: md.input.Value()})
		return m, nil
	case "esc":
		m.answer(reply{cancelled: true})
		return m, nil
	}
	var cmd tea.Cmd
	md.input, cmd = md.input.Update(msg)
	return m, cmd
}

// ---- view

var (
	cBorder = lipgloss.AdaptiveColor{Light: "#5f6b7a", Dark: "#7f8c9b"}
	cAccent = lipgloss.AdaptiveColor{Light: "#0b6bcb", Dark: "#5cb3ff"}
	cOK     = lipgloss.AdaptiveColor{Light: "#1a7f37", Dark: "#56d364"}
	cBad    = lipgloss.AdaptiveColor{Light: "#cf222e", Dark: "#ff7b72"}
	cWarn   = lipgloss.AdaptiveColor{Light: "#9a6700", Dark: "#e3b341"}
	cDim    = lipgloss.AdaptiveColor{Light: "#6e7781", Dark: "#8b949e"}
)

func panel(title string, w, h int, body string, focused bool) string {
	bc := cBorder
	if focused {
		bc = cAccent
	}
	st := lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(bc).Width(w - 2).Height(h - 2)
	t := lipgloss.NewStyle().Bold(true).Foreground(cAccent).Render(" " + title + " ")
	out := st.Render(clip(body, w-4, h-2))
	// Put the title into the top border.
	lines := strings.Split(out, "\n")
	if len(lines) > 0 && lipgloss.Width(t) < w-4 {
		first := []rune(lines[0])
		_ = first
		lines[0] = lipgloss.NewStyle().Foreground(bc).Render("╭") + t +
			lipgloss.NewStyle().Foreground(bc).Render(strings.Repeat("─", max(0, w-3-lipgloss.Width(t)))+"╮")
	}
	return strings.Join(lines, "\n")
}

// clip cuts text to w columns and h lines.
func clip(s string, w, h int) string {
	lines := strings.Split(s, "\n")
	if len(lines) > h {
		lines = lines[len(lines)-h:]
	}
	for i, l := range lines {
		if lipgloss.Width(l) > w {
			lines[i] = truncate(l, w)
		}
	}
	return strings.Join(lines, "\n")
}

func truncate(s string, w int) string {
	if w <= 1 {
		return ""
	}
	r := []rune(s)
	for len(r) > 0 && lipgloss.Width(string(r)) > w-1 {
		r = r[:len(r)-1]
	}
	return string(r) + "…"
}

func (m *Model) tabs() string {
	names := []string{"1 Setup", "2 Dashboard", "3 Help"}
	var parts []string
	for i, n := range names {
		st := lipgloss.NewStyle().Padding(0, 1).Foreground(cDim)
		if screen(i) == m.scr {
			st = st.Bold(true).Foreground(lipgloss.Color("0")).Background(cAccent)
		}
		parts = append(parts, st.Render(n))
	}
	title := lipgloss.NewStyle().Bold(true).Foreground(cAccent).Render("ThoughtBox setup")
	return title + "  " + strings.Join(parts, " ")
}

// View implements tea.Model.
func (m *Model) View() string {
	if m.w < MinWidth || m.h < MinHeight {
		msg := fmt.Sprintf("Make the window larger (at least %d x %d).\nIt is %d x %d now.", MinWidth, MinHeight, m.w, m.h)
		return lipgloss.Place(max(m.w, 1), max(m.h, 1), lipgloss.Center, lipgloss.Center, msg)
	}
	bodyH := m.h - 3
	var body string
	switch m.scr {
	case screenDash:
		body = m.dashView(m.w, bodyH)
	case screenHelp:
		body = panel("Help", m.w, bodyH, helpText, true)
	default:
		body = m.setupView(m.w, bodyH)
	}
	if m.modal != nil {
		body = lipgloss.Place(m.w, bodyH, lipgloss.Center, lipgloss.Center, m.modalView())
	}
	return m.tabs() + "\n" + body + "\n" + m.statusBar()
}

func statusGlyph(s stepStatus) (string, lipgloss.TerminalColor) {
	switch s {
	case stepRunning:
		return "▶", cAccent
	case stepDone:
		return "✔", cOK
	case stepFailed:
		return "✘", cBad
	case stepSkipped:
		return "–", cDim
	default:
		return "·", cDim
	}
}

func (m *Model) setupView(w, h int) string {
	leftW := 34
	var sb strings.Builder
	for _, s := range m.steps {
		g, c := statusGlyph(s.status)
		line := lipgloss.NewStyle().Foreground(c).Render(g) + " " + s.name
		if s.note != "" {
			line += lipgloss.NewStyle().Foreground(cDim).Render("  " + s.note)
		}
		sb.WriteString(line + "\n")
	}
	left := panel("Steps", leftW, h, sb.String(), m.phase != phaseRunning)

	var logBody string
	switch {
	case len(m.log) == 0 && m.phase == phaseIdle:
		logBody = lipgloss.NewStyle().Foreground(cDim).Render("Press Enter to start the setup.\nNothing is changed until you do.")
		if m.cfg.Dry {
			logBody += "\n\nDry run: nothing will be changed."
		}
	default:
		end := len(m.log) - m.scroll
		start := max(0, end-(h-2))
		var lines []string
		for _, l := range m.log[start:end] {
			lines = append(lines, colourLine(l))
		}
		logBody = strings.Join(lines, "\n")
	}
	title := "Live log"
	if m.code != "" {
		title += "  ·  code " + m.code
	}
	right := panel(title, w-leftW, h, logBody, m.phase == phaseRunning)
	return lipgloss.JoinHorizontal(lipgloss.Top, left, right)
}

// hardWrap splits a plain line into pieces that fit width columns, so a long
// link stays complete on screen instead of being cut off.
func hardWrap(s string, width int) []string {
	if width < 8 || lipgloss.Width(s) <= width {
		return []string{s}
	}
	var out []string
	cur := ""
	for _, r := range s {
		if lipgloss.Width(cur+string(r)) > width {
			out = append(out, cur)
			cur = ""
			width = max(8, width-2) // continuation lines are indented by two
		}
		cur += string(r)
	}
	return append(out, cur)
}

func colourLine(l string) string {
	switch {
	case strings.HasPrefix(l, "x ") || strings.HasPrefix(l, "! x"):
		return lipgloss.NewStyle().Foreground(cBad).Render(l)
	case strings.HasPrefix(l, "! "):
		return lipgloss.NewStyle().Foreground(cWarn).Render(l)
	case strings.HasPrefix(l, "==>"):
		return lipgloss.NewStyle().Bold(true).Render(l)
	}
	return l
}

func (m *Model) modalView() string {
	md := m.modal
	var b strings.Builder
	b.WriteString(lipgloss.NewStyle().Bold(true).Render(md.a.title) + "\n")
	if md.a.help != "" {
		b.WriteString(lipgloss.NewStyle().Foreground(cDim).Render(md.a.help) + "\n")
	}
	b.WriteString("\n")
	if md.a.kind == askChoice {
		for i, o := range md.a.options {
			if i == md.sel {
				b.WriteString(lipgloss.NewStyle().Foreground(cAccent).Bold(true).Render("> "+o) + "\n")
			} else {
				b.WriteString("  " + o + "\n")
			}
		}
		b.WriteString("\n" + lipgloss.NewStyle().Foreground(cDim).Render("↑/↓ move · Enter choose · Esc cancel"))
	} else {
		b.WriteString(md.input.View() + "\n\n")
		b.WriteString(lipgloss.NewStyle().Foreground(cDim).Render("Enter accept · Esc cancel"))
	}
	return lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cAccent).Padding(1, 3).Width(min(70, m.w-4)).Render(b.String())
}

func (m *Model) statusBar() string {
	var parts []string
	switch m.phase {
	case phaseRunning:
		parts = append(parts, "running")
	case phaseDone:
		if m.failed {
			parts = append(parts, lipgloss.NewStyle().Foreground(cBad).Render("stopped with a problem"))
		} else {
			parts = append(parts, lipgloss.NewStyle().Foreground(cOK).Render("finished"))
		}
	default:
		parts = append(parts, "ready")
	}
	if d := m.dash; d.loaded {
		if next := d.tokenSummary(m.cfg.Now()); next != "" {
			parts = append(parts, next)
		}
	}
	hint := "Tab switch · ↑/↓ scroll · q quit"
	if m.scr == screenSetup && m.phase == phaseIdle {
		hint = "Enter start · " + hint
	}
	left := strings.Join(parts, " · ")
	gap := m.w - lipgloss.Width(left) - lipgloss.Width(hint) - 2
	if gap < 1 {
		gap = 1
	}
	return lipgloss.NewStyle().Foreground(cDim).Render(" " + left + strings.Repeat(" ", gap) + hint)
}

const helpText = `ThoughtBox setup

  Enter          start the setup (on the Setup screen)
  Tab, 1 2 3     switch between Setup, Dashboard and Help
  Up/Down, j/k   scroll the log        PgUp/PgDn  scroll faster
  r              refresh the dashboard
  q, Ctrl+C      quit (a running step is stopped)

Tokens
  A classic token is not cancelled when you sign in on another computer, and lasts as
  long as you choose. It goes straight to Gita: it is never shown, logged or stored by
  this program. Only the expiry date is remembered, for the dashboard.

Set NO_COLOR=1 for plain output. Run with TB_NO_TUI=1 to use the plain script instead.`

// Env reads a variable, for main.
func Env(k string) string { return os.Getenv(k) }
