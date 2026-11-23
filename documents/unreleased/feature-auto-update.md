---
type: feature
area: update
title: A quiet --update mode and a daily scheduled update
authors: [Naseeb Naushad]
branch: feature/auto-update
cr: none
after_the_fact: false
---

## What changed and why
Developers only got a new Gita, or a repaired claude-standards plugin, when they ran the setup
by hand. Two days after a setup, both GitHub sign-ins on one machine had already been cancelled
and nobody knew. The installers now have an unattended **update mode** and can run it every day.

## How it works
- `--update` (`TB_UPDATE=1`; on Windows only the variable, since `irm | iex` takes no arguments):
  no questions, no terminal, never a browser sign-in (`gita onboard --skip-sign-in`), no token
  prompt, no shell-startup or PATH changes. Updates Gita when the pinned version is newer, re-runs
  `gita onboard` (tools, claude-standards and its setup), refreshes Figma only if it is already
  installed. Skips the Gita update while the Gita app is running. Stops quietly if the computer
  was never set up, or if another update holds the lock (`~/.thoughtbox/update.lock`, stale after
  3 hours). Its log is `~/.thoughtbox-update.log`.
- Afterwards `gita doctor` runs; a non-zero result (usually a cancelled or expired sign-in) gives
  a desktop notification and a line in the log. A failed update also notifies.
- `--schedule` / `TB_SCHEDULE=1`, `--unschedule` / `TB_UNSCHEDULE=1`, and a question at the end of a
  normal run (`TB_AUTO_UPDATE=1|0` answers it). A wrapper in `~/.thoughtbox/` downloads the
  current script from `main` and runs it in update mode. macOS: launchd agent; Linux: systemd
  user timer (Persistent), else cron; Windows: Task Scheduler task (StartWhenAvailable). The
  minute is random (5-54) to spread the load.

## Tests added and results
`install.sh` on macOS in a temporary `HOME` with a fake `gita`, `launchctl` and `osascript`:
- `--update` on a machine that isn't set up: stops with a message. Pass.
- `--update` on a set-up machine: installs the Gita version, runs `onboard --skip-sign-in`, then
  `doctor`; no questions. Pass.
- `doctor` failing: warning, notification, summary line. Pass.
- `--schedule`: plist and wrapper written, `launchctl bootstrap` called; `--unschedule` removes
  both. Pass. Lock held: second update stops. Pass.

Not run: `install.ps1` (no PowerShell on the machine used; the Windows CI jobs will at least parse
it), the Linux systemd and cron paths, a real launchd registration, and an update with a real
GitHub sign-in.

## Notes for users / upgrade steps
Run the install command again: it asks once whether to turn the daily update on.

## Technical notes
The daily update trusts the `main` branch of this repository. `main` is protected by team rules,
not by GitHub. See the README security note.

## Suggestions
- Sign the update script (for example with `ssh-keygen -Y sign`, key pinned in the installer) so a
  compromised `main` cannot run on every machine.
- CI jobs that run `--update` and `--schedule` against a fake `gita` on all three systems.
- Let `gita onboard` take over the token and update logic, so there is one implementation.
