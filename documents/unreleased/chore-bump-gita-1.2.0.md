---
type: improvement
area: gita
title: The installers now pin Gita 1.2.0
authors: [Naseeb Naushad]
branch: chore/bump-gita-1.2.0
cr: none
after_the_fact: false
---

## What changed and why
`install.sh` and `install.ps1` pinned Gita 1.1.1. Gita 1.2.0 (2026-11-19) is the first release with:
- a folder rule that wins over organization rules, so a second account can be used for one
  organization's projects (`gita rule add --over-org`), and verified access tokens;
- the `gita onboard` repair of an old or incomplete company repository (it was not in 1.1.1);
- the sign-in health check (cancelled or wrong-account sign-ins are found and repaired).

## How it works
Only the pinned version and the three checksums changed (same lines `gita-bump` edits). An older
or broken Gita is replaced when the installer runs again; a newer one is kept; profiles and
settings in `~/.gita` stay.

## Tests added and results
- macOS, Linux and Windows downloads checked against the release's `SHA256SUMS`: all match.
- macOS build starts and reports `gita 1.2.0`.
- `TB_DRY_RUN=1 bash install.sh` on macOS (sign-in and claude-standards skipped): finished,
  nothing changed.
- Linux build start and `install.ps1`: not run locally; left to the `Test installers` CI.

## Notes for users / upgrade steps
Run the dev-setup command again. Existing installs update to Gita 1.2.0 and are repaired by
`gita onboard`.
