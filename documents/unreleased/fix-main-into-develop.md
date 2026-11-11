# fix/main-into-develop

## What changed and why

The company rules say a hotfix goes into `main` and then the same change goes into
`develop`. This branch was made to do that, but `develop` no longer exists on GitHub: it
was deleted on 2026-11-09 at 11:09 UTC together with the merged feature branches. Claude
may not push to `develop`, so a person recreates it from `main`; with that, every hotfix is
in `develop` and nothing needs merging. This branch then carries only the docs update.

It brings `documents/Lifecycle and process flows.md` up to date after a look at the
latest claude-standards and Gita changes:

- PR #8 merged on 2026-11-10 11:22; claude-standards PR #7 merged at the same time.
- A second Windows run on a new local account (2026-11-10): the PATH fix worked; only the
  optional Figma step stopped because `winget` was missing.
- Gita PR #31 (rerunning `gita onboard` repairs an old company repository copy) is merged
  but not released; Gita PR #32 (notice cancelled sign-ins) is open. Neither needs a change
  here: dev-setup only calls `gita onboard`, and the bump bot will open the pin PR when Gita
  publishes the next release.
- Figure 12 and its table show #8 and this merge as done and the next Gita release as the
  next step. Section 14 records the `winget` workaround.

## Logic

No code changed. `install.ps1` and `install.sh` are byte for byte the same as on `main`.

## Tests and results

| ID | Check | Result |
|---|---|---|
| DOCS-001 | Figure 12 renders with mermaid-cli 11.4.2 | Pass |
| DOCS-002 | The lifecycle document has no control bytes; Windows paths keep their backslash | Pass |
| SYNC-001 | `git diff origin/main -- install.ps1 install.sh` is empty | Pass |
| SYNC-002 | `git ls-remote origin develop` | Empty: `develop` was deleted, see above |

## Bugs fixed

None in code. Found: `develop` is missing on GitHub.

## Notes for users

Nothing changes for developers; the one-line command still uses `main`.

## Suggestions

- The Figma step could register App Installer itself
  (`Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe`)
  when `winget` is missing, before failing.
- When Gita releases 1.2.0 (PR #32), the troubleshooting tree can point "sign in again"
  failures at `gita doctor`, which will then say whether a sign-in was cancelled.
