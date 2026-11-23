# Change note: feature/setup-tui

**Change Request:** CR-0.3.0-01 (Full-screen setup TUI) · **Status:** in progress

## What changed
- New Go program `tui/` (`tb-setup`): a full-screen, btop-style terminal app with a
  step list, a live log, a form for the classic token (with a duration menu, 1 year
  recommended) and a status dashboard (sign-ins, token expiry, Gita's check, daily update).
- CI: `tui.yml` (vet, test, build on Linux, macOS and Windows; vulnerability scan) and
  `release-tui.yml` (tag `tui-vX.Y.Z` builds five binaries and `SHA256SUMS`).

## How it works
`tb-setup` drives the installed `gita` (version, profiles, `onboard`, `sign-in`, `doctor`).
Tokens go to Gita through stdin only; they are never shown, logged or stored. Only the
expiry date is remembered, in `~/.thoughtbox/tokens.json`. It needs a real terminal
(exit 3 otherwise) so the installers can fall back to the plain scripts.
Try it without changing anything: `TB_TUI_DEMO=1 tb-setup thoughtbox-onboarding.json`.

## Tests
`go vet`, `go test ./...` and `govulncheck ./...` all clean (unit tests for tokens, state,
onboarding file, pipeline with a fake Gita, and the screens). The demo was run in a
pseudo-terminal through the whole setup.

## Not done yet
- Installer integration (download, pinned SHA-256, fall back to scripts): needs a first
  release to pin.
- Not tested against the real Gita, real GitHub, or on Windows.
- Open CR questions O1 (Gita progress events), O2 (binary signing), O4 (`tb-setup status`).

## Notes for users
Nothing changes for users until the installers start using the binary.
