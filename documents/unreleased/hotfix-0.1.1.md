# hotfix/0.1.1 (was fix/setup-reinstall-and-errors, PR #2)

## What changed and why

Two people could not finish the setup:

- **Elsa (macOS):** `Killed: 9` right after Gita was installed. macOS kills a program whose
  file was overwritten in place while its old signature is cached.
- **Thomas (Windows):** cloning claude-standards failed. git used an old @thoughtbox.io
  sign-in saved on his PC instead of his @thoughtbox.one Gita profile.

Both installers (`install.sh`, `install.ps1`) now check every step before acting, repair
or reinstall what is broken, clean up old GitHub sign-ins, and explain failures clearly.

## Logic

- **Every step checks first:** Git, GitHub CLI, Claude Code and Gita are each "missing",
  "ok", "old" or "broken" (present but won't run). Missing and broken are (re)installed,
  old is updated, ok is kept.
- **Gita install:** old `bin` and `lib` are deleted before the new files are copied, so
  macOS never runs a file with a stale signature. On macOS the command inside `gita.app`
  must start too; if it doesn't, it is re-signed with the entitlement the Dart runtime
  needs (from PR #3, merged in). A running Gita is found and you are asked to close it.
- **Clean-up (new step):** finds saved github.com logins (Credential Manager, Keychain,
  `~/.git-credentials`), github.com `insteadOf` rules, sign-in headers, old credential
  helpers and gh logins. It lists them, asks (or uses `TB_CLEAN=1`), backs up
  `~/.gitconfig`, removes them and says how many were removed. Gita's sign-ins, other
  sites and SSH keys are not touched. `GH_TOKEN` for all users and SSH `Host github.com`
  entries are only reported.
- **Sign-in:** an existing profile sign-in is kept only after you confirm its GitHub
  login; both profiles on the same login means sign in again.
- **claude-standards:** clean copy → updated; local changes → kept; anything else → moved
  to a backup. A failed clone removes the partial folder, lists the causes and offers to
  sign in again and retry.
- **Errors:** "Setup stopped:" with the reason and what to do; a summary of every step
  at the end; a user-only log at `~/.thoughtbox-setup.log`. A failed run exits with 1
  (on Windows without closing the terminal).

## Tests and results

32 Alpha cases (`SETUP-001`…`SETUP-032`): **30 pass, 0 fail, 2 not run** — see
`documents/v0.1.0/alpha/v0.1.0 - Alpha Test Cases (Safe reinstall and clear errors).md`.
Tested on Windows 11 (PowerShell 5.1 and 7.4) and Linux (WSL) in throwaway homes with fake
old settings, including a home folder with spaces and non-English letters, a wrong
checksum, a failed download, a run killed halfway, and a claude-standards copy that has
moved on from GitHub.
**Not run:** macOS (CI now runs it on macOS), Windows prompts in a real terminal, a real Git
Credential Manager, the browser sign-in.

## Hotfix additions (2026-11-09)

Shipped to `main` as a hotfix so the team has a working setup now; the full move into
Gita (`feature/gita-onboarding`, PR #5) follows when Gita 1.1.0 is released.

- **Gita 1.0.3 pinned** (released 2026-11-09: `gita gh`, the macOS signing fix, `gita` on
  PATH, clearer clone sign-in errors). Checksums from GitHub's release digests and
  recomputed from the downloads (both match); the Linux build starts and reports 1.0.3.
- **Windows user PATH kept as stored:** the script now writes the user PATH through the
  registry as REG_EXPAND_SZ with `%VARIABLES%` unexpanded. The old code (also on `main`)
  rewrote it as REG_SZ with the variables expanded.
- **Downloads retry five times with longer waits:** a CI run of PR #2 failed on a GitHub
  504 while downloading Gita.
- **Tests:** `Add-UserPath` 7/7 on a throwaway registry key; Windows dry, real (real
  1.0.3 download) and re-run; Linux real run, re-run, killed and old Gita; shellcheck and
  PowerShell parser clean. The developer's real PATH value and type, `~/.gitconfig` and
  `~/.gita` files were checked unchanged after the runs.

## Bugs fixed

- macOS `Killed: 9` after installing or updating Gita.
- Windows: git used an old saved github.com sign-in instead of the Gita profile.
- Windows: the saved-login check failed when the console used UTF-8 (PowerShell added a
  byte-order mark to text sent to git).
- A failed run could report success (exit code 0). `powershell -File install.ps1` now
  exits 1; under `irm | iex` the window stays open and `$LASTEXITCODE` is 1.
- Credential Manager entries listed without the `LegacyGeneric:target=` prefix were missed;
  entries are now matched by name, so translated cmdkey labels don't matter.
- A temp folder was left behind when a run was killed; the next install clears old ones.
- A claude-standards copy that couldn't be updated printed a page of git hints.
- An SSH `git pull` of claude-standards could hang waiting for a password.

## Notes for users

- **If claude-standards can't be downloaded, the most common cause is that
  ThoughtBoxFinTechAI hasn't approved the Gita app.** Request it on github.com
  (Settings → Applications → Authorized OAuth Apps → Gita → Request) and an org owner
  approves it (Organization settings → Third-party access). This was the real cause of
  Thomas's failure; after approval the setup worked on Windows. The setup now lists this
  cause first.

- The setup can log you out of GitHub CLI. Run `gh auth login` afterwards with the right
  account.
- New options: `TB_CLEAN=1` (remove old sign-ins without asking), `TB_LOG` (log path).
- See "When something goes wrong" in the README.

## Suggestions

- Add a `.gitignore` with `.env*` (except `.env.example`), `*.pem`, `*.key`, `*.pfx`
  (company rule §7; the repo has none).
- Sign and notarise the macOS Gita build in the gita repo, so ad-hoc re-signing is not
  needed.
- Add the PowerShell parser and Windows PowerShell 5.1 to CI (`shellcheck` already runs there).
