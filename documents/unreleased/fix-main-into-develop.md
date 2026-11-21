# fix/main-into-develop

## What changed and why

The company rules say a hotfix goes into `main` and then the same change goes into
`develop`. This branch was made to do that, but `develop` no longer exists on GitHub: it
was deleted on 2026-11-09 at 11:09 UTC together with the merged feature branches. Claude
may not push to `develop`, so a person recreates it from `main`; with that, every hotfix is
in `develop` and nothing needs merging. This branch then carries only the docs update.

It brings `documents/Lifecycle and process flows.md` up to date. It was written on
2026-11-11 and updated on 2026-11-21, after `main` was merged in again:

- PR #8 merged on 2026-11-10 11:22; claude-standards PR #7 merged at the same time.
- A second Windows run on a new local account (2026-11-10): the PATH fix worked; only the
  optional Figma step stopped because `winget` was missing.
- Gita PRs #31 (rerunning `gita onboard` repairs an old company repository copy) and #32
  (notice cancelled sign-ins) were released in Gita 1.2.0 on 2026-11-19, and dev-setup
  PR #9 pinned 1.2.0 (merged 2026-11-21 15:15). The header, Figure 2 and the timeline now
  say 1.2.0.
- The bump bot found 1.2.0 on 2026-11-20 and pushed `bot/gita-1.2.0`, but its run failed:
  "GitHub Actions is not permitted to create or approve pull requests". The repository
  setting is still off, so #9 was opened by hand. Section 14 and the to-do table say so.
- Figure 12 and its table show #8, #9 and the 1.2.0 release as done, and the repository
  setting as the next step. Section 14 records the `winget` workaround.
- `documents/README.md` also lists the change note of `chore/bump-gita-1.2.0` (#9), which
  that PR did not add to the index.

## Logic

No code changed. `install.ps1` and `install.sh` are byte for byte the same as on `main`.

## Tests and results

| ID | Check | Result |
|---|---|---|
| DOCS-001 | Figure 12 renders with mermaid-cli 11.4.2 | Pass |
| DOCS-002 | The lifecycle document has no control bytes; Windows paths keep their backslash | Pass |
| SYNC-001 | `git diff origin/main -- install.ps1 install.sh` is empty | Pass |
| SYNC-002 | `git ls-remote origin develop` | Empty: `develop` was deleted, see above |
| SYNC-003 | `main` (with #9) merged into this branch; `git diff origin/main -- install.ps1 install.sh` is empty | Pass (2026-11-21) |
| DOCS-003 | No "Gita 1.1.1 pinned" left outside the history rows | Pass (2026-11-21) |

## Bugs fixed

None in code. Found: `develop` is missing on GitHub.

## Notes for users

Nothing changes for developers; the one-line command still uses `main`.

## Suggestions

- The Figma step could register App Installer itself
  (`Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe`)
  when `winget` is missing, before failing.
- Now that 1.2.0 is pinned, the troubleshooting tree can point "sign in again" failures
  at `gita doctor`, which says whether a sign-in was cancelled.
- Turn on "Allow GitHub Actions to create and approve pull requests" so the bump bot can
  open pin PRs itself.
