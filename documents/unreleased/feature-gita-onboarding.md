# feature/gita-onboarding

## What changed and why

The setup scripts did everything themselves in about 900 lines each, in two shells, and
kept breaking in different ways on each system. Most of what they set up belongs to Gita
anyway. Now the scripts only install Gita and hand over to its new `gita onboard`
command, with ThoughtBox's steps in [`thoughtbox-onboarding.json`](../../thoughtbox-onboarding.json).
Gita is open source and not affiliated with ThoughtBox, so everything added to it is
generic. See the Change Request in `documents/v0.2.0/alpha/`.

## Logic

- **`install.sh` / `install.ps1`:**
  1. Check the platform.
  2. Install the pinned Gita after checking its SHA-256: never downgrade, update an older
     one, reinstall a broken one.
  3. Download `thoughtbox-onboarding.json` and check its pinned SHA-256.
  4. Run `gita onboard` with the `TB_*` answers.

  The scripts also tidy leftovers of older versions: one `Added by ThoughtBox dev-setup`
  PATH block at the end of each shell file, `~/.gita/bin` first in the Windows user PATH
  (keeping `%VARIABLES%` and the registry type), a warning for any other `gita` on PATH,
  and old temp folders.
- **`gita onboard` (in Gita):** runs these steps in order:
  - tools (git, gh, Claude Code);
  - clean-up of old GitHub sign-ins;
  - old backups;
  - accounts;
  - sign-in;
  - claude-standards (clone, update, keep or move aside);
  - company files;
  - the setup script;
  - Claude Code;
  - doctor;
  - summary.
- **`gita gh`:** runs the GitHub CLI as the right account per project.
- **Bump bot:** `.github/workflows/gita-bump.yml` (calls `scripts/gita-bump.sh`) opens a PR
  when Gita has a newer published release, with checksums checked against the release's
  `SHA256SUMS`, and starts the installer tests on it.

## Tests and results

See `documents/v0.2.0/alpha/v0.2.0 - Alpha Test Cases (Move setup into Gita).md`:
29 pass, 0 fail, 5 not run. Gita (rebuilt on PRs #23 and #21): 331 unit tests pass, 17 skip on Windows by design, and the smoke test passes. Bump
bot: 6/6. Guard: 24/24.

**Not run:**
- Real downloads: Gita 1.1.0 isn't published yet, so the CI install jobs fail until the bot pins it.
- A real Mac.
- The interactive terminal path.
- The bot's first real run.

## Bugs fixed

- **Windows PATH:** the old script rewrote the Windows user PATH with expanded values and the
  plain registry type, so `%VARIABLE%` entries stopped expanding. The new script keeps both.
- **macOS `Killed: 9`:** fixed at the source in Gita's build (entitlement on the bundled command).
- **Wrong-account gh:** the company guard didn't see `gita gh` (claude-standards
  `feature/gita-gh`).
- **Gita's smoke test** wasn't isolated on Windows and could change a real setup. It now
  refuses to run unless isolated.

## Notes for users

- Same one-line commands as before.
- Use `gita gh <command>` for the GitHub CLI.
- If claude-standards can't be downloaded, the organization probably hasn't approved the
  Gita app yet (see the README).
- The setup now offers to delete old `.gitconfig` backups. Those can still hold old tokens.

## Suggestions

- **Release Gita 1.1.0:** release `feat/onboard`, which also publishes `SHA256SUMS`, then let
  the bot pin it.
- **Repo setting:** turn on "Allow GitHub Actions to create and approve pull requests" for
  this repo.
- **CI:** run the installer CI on Windows PowerShell 5.1 too (it uses PowerShell 7 today).
