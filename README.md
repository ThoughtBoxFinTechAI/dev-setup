# dev-setup

One command to set up a ThoughtBox developer machine.

**Windows** (PowerShell):
```powershell
irm https://raw.githubusercontent.com/ThoughtBoxFinTechAI/dev-setup/main/install.ps1 | iex
```

**macOS / Linux:**
```bash
curl -fsSL https://raw.githubusercontent.com/ThoughtBoxFinTechAI/dev-setup/main/install.sh | bash
```

You'll be asked for your name, your **@thoughtbox.io** email and your **@thoughtbox.one**
email, and you'll sign in to GitHub twice: once per account. The rest is automatic. Run
it again any time: every step checks what is already there, keeps what works, and
repairs or reinstalls what is broken.

## What it does

| Step | Details |
|---|---|
| Prerequisites | Git, GitHub CLI. Windows: winget. macOS: Xcode tools + Homebrew. Linux: apt, dnf or pacman (also `secret-tool`, where Gita keeps tokens). |
| Claude Code | The official installer from claude.ai, if `claude` is missing or doesn't run. |
| Gita | A pinned release of [Gita](https://github.com/naseebnaushad/gita), checked against a SHA-256 in the script before anything is installed. The app goes to `%LOCALAPPDATA%\Programs\Gita`, `~/Applications/gita.app` or `~/.local/share/gita`; the `gita` command to `~/.gita/bin` (added to PATH). An old version is updated and a copy that doesn't run (for example macOS `Killed: 9`) is reinstalled; profiles are kept. |
| Clean-up | Finds old GitHub sign-ins that make git or gh use the wrong account: saved github.com logins (Windows Credential Manager, macOS Keychain, `~/.git-credentials`), `url.*.insteadOf` rules and sign-in headers for github.com, old github.com credential helpers, and GitHub CLI logins. Lists them, asks, backs up `~/.gitconfig`, then removes them. Gita's sign-ins, other sites and SSH keys are not touched. |
| Accounts | Gita profiles `ThoughtBox` (@thoughtbox.io) and `ThoughtBox AI` (@thoughtbox.one), each signed in to GitHub. Existing profiles with those emails are reused. An existing sign-in is kept only after you confirm the GitHub login; if both profiles use the same login, the profile is signed in again. |
| claude-standards | Cloned to `~/claude-standards` with the AI account (an existing clean copy is updated, one with local changes is kept, anything else is moved to `~/claude-standards.backup-<date>`), its Gita company files imported (`thoughtboxhub` → .io, `ThoughtBoxFinTechAI` → .one), then its setup run (rules, deny rules, company plugin). |
| Finish | Gita is connected to Claude Code (`gita mcp add-to-claude`) and `gita doctor` checks everything. |

After it finishes you see a summary of every step. Then open a new terminal, run `claude`
and sign in with your company seat.

## Options

Set these environment variables before running:

| Variable | Effect |
|---|---|
| `TB_NAME`, `TB_EMAIL_IO`, `TB_EMAIL_ONE` | Answer the questions up front. |
| `TB_DRY_RUN=1` | Print what would change; change nothing. |
| `TB_CLEAN=1` | Remove the old GitHub sign-ins found by the clean-up without asking. Without a terminal and without this, nothing is removed. |
| `TB_LOG` | Where to write the log (default `~/.thoughtbox-setup.log`). |
| `TB_SKIP_SIGNIN=1`, `TB_SKIP_STANDARDS=1` | Skip GitHub sign-in, or claude-standards and the Claude Code setup (for testing). |
| `TB_GITA_ZIP` (Windows), `TB_GITA_ARCHIVE` (macOS/Linux) | Install Gita from a local file instead of the release. No checksum check; for testing builds only. |

Windows example: `$env:TB_DRY_RUN='1'; irm .../install.ps1 | iex`.
macOS/Linux: `curl -fsSL .../install.sh | TB_DRY_RUN=1 bash`.

## When something goes wrong

- Setup stops with **"Setup stopped:"**, the reason and what to do. Fix that and run the
  same command again; finished steps are skipped.
- Every run writes a log to `~/.thoughtbox-setup.log`. Only you can read it, and no token is
  written to it. Send it when asking for help.
- **"claude-standards couldn't be downloaded"**: check these in order.
  1. **ThoughtBoxFinTechAI must approve the Gita app** (the most common cause). Signed in to
     github.com as your @thoughtbox.one account, open **Settings → Applications → Authorized
     OAuth Apps → Gita** and click **Request** next to ThoughtBoxFinTechAI. An org owner
     approves it under **Organization settings → Third-party access**. Then run the setup
     again.
  2. The `ThoughtBox AI` profile must be signed in as your @thoughtbox.one GitHub account.
     GitHub signs in whoever is logged in to github.com in your browser, so sign out there
     first (or use a private window), then run `gita sign-in --profile "ThoughtBox AI"` and
     the setup again.
  3. That account must be a member of ThoughtBoxFinTechAI. Ask an admin.
- **macOS `Killed: 9`**: run the setup again; it reinstalls Gita.
- If the clean-up signed out GitHub CLI, run `gh auth login` with the right account.
- Not changed automatically; check them yourself if git still uses the wrong account:
  `GH_TOKEN` / `GITHUB_TOKEN` set in your shell profile (or, on Windows, for all users),
  a `Host github.com` entry in your SSH settings (matters only for `git@github.com:`
  addresses), and other apps signed in to GitHub (your IDE, GitHub Desktop).

## For admins: releasing a new Gita version

The installers only install the exact Gita version and checksums pinned at the top of
each script. To move to a new release:

1. Tag the release in `naseebnaushad/gita` (`vX.Y.Z`); CI builds the three downloads into a
   draft release. Check it and publish it.
2. Get the checksums:
   ```bash
   gh release download vX.Y.Z --repo naseebnaushad/gita --dir /tmp/gita-vX.Y.Z
   sha256sum /tmp/gita-vX.Y.Z/*
   ```
3. Update `$GitaVersion` and `$GitaSha256` in `install.ps1`, and `GITA_VERSION`,
   `GITA_SHA256_MACOS`, `GITA_SHA256_LINUX` in `install.sh`. Open a pull request.

This repo is public so the one-line command works without signing in. It must never
hold secrets, tokens or webhook URLs; those come from claude.ai managed settings.
