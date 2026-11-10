# hotfix/0.2.1

## What changed and why

Jalaal's Windows run (2026-11-09) had two problems:

- **`'claude' not found` from the claude-standards setup.** Claude Code's Windows installer
  puts `claude.exe` in `~\.local\bin` but doesn't add that folder to PATH. Gita installed
  Claude Code, then ran `setup.ps1`, which couldn't find it. Running the command again
  didn't help.
- **`The property 'Path' cannot be found on this object`** at the very end of the second
  run. He had run Claude Code's own installer (`irm https://claude.ai/install.ps1 | iex`) in
  the same window, which leaves PowerShell's strict mode on. Under `irm | iex` the last line
  of `install.ps1` read `$MyInvocation.MyCommand.Path`, which doesn't exist there, so strict
  mode turned it into an error. It only showed when the setup had already failed.

## How it works

- `install.ps1` puts `~\.local\bin` in its own PATH before `gita onboard`, so Gita and the
  setup script it runs find `claude`. After onboarding, if `claude.exe` is there, the folder
  is added to the end of the user PATH (once), so new terminals find it too. The summary
  says so.
- The last line reads the script path through `PSObject.Properties`, which is safe under
  any strict mode.
- claude-standards' `setup.ps1` also looks in `~\.local\bin` (its own PR).

## Tests added and results

The Windows CI job now also checks that `~\.local\bin` is on the user PATH when
`claude.exe` is there. It also runs a failing setup under `irm | iex` style
(`Get-Content | Invoke-Expression`) in Windows PowerShell 5.1 with
`Set-StrictMode -Version Latest`, and expects exit code 1 and no error. Results: see the
PR's CI.

## Notes for users

Run the same one-line command again in a new PowerShell window.

## Documents updated

`documents/Lifecycle and process flows.md` now shows `main` as it is after PRs #6, #5 and
#4: the `gita onboard` flow with Gita 1.1.1 and the two hotfix steps (Figure 3),
`~/.local/bin/claude` in "what goes where" (Figure 6), two new troubleshooting branches
(Figure 11), the timeline up to PR #8, and what is left (Figure 12, including bringing
`main` into `develop`, which is 22 commits behind). All 12 diagrams render with
mermaid-cli 11.4.2.

The PR moved from `fix/windows-claude-path` (#7, closed) to `hotfix/0.2.1` (#8), because
only a release or a hotfix goes into `main`.
