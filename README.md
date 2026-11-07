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
it again any time; finished steps are skipped.

## What it does

| Step | Details |
|---|---|
| Prerequisites | Git, GitHub CLI. Windows: winget. macOS: Xcode tools + Homebrew. Linux: apt, dnf or pacman (also `secret-tool`, where Gita keeps tokens). |
| Claude Code | The official installer from claude.ai, if `claude` isn't installed. |
| Gita | A pinned release of [Gita](https://github.com/tbaiadmin/gita), checked against a SHA-256 in the script before anything is installed. The app goes to `%LOCALAPPDATA%\Programs\Gita`, `~/Applications/gita.app` or `~/.local/share/gita`; the `gita` command to `~/.gita/bin` (added to PATH). |
| Accounts | Gita profiles `ThoughtBox` (@thoughtbox.io) and `ThoughtBox AI` (@thoughtbox.one), each signed in to GitHub. Existing profiles with those emails are reused. |
| claude-standards | Cloned to `~/claude-standards` with the AI account, its Gita company files imported (`thoughtboxhub` → .io, `ThoughtBoxFinTechAI` → .one), then its setup run (rules, deny rules, company plugin). |
| Finish | Gita is connected to Claude Code (`gita mcp add-to-claude`) and `gita doctor` checks everything. |

After it finishes: open a new terminal, run `claude` and sign in with your company seat.

## Options

Set these environment variables before running:

| Variable | Effect |
|---|---|
| `TB_NAME`, `TB_EMAIL_IO`, `TB_EMAIL_ONE` | Answer the questions up front. |
| `TB_DRY_RUN=1` | Print what would change; change nothing. |
| `TB_SKIP_SIGNIN=1`, `TB_SKIP_STANDARDS=1` | Skip GitHub sign-in, or claude-standards and the Claude Code setup (for testing). |
| `TB_GITA_ZIP` (Windows), `TB_GITA_ARCHIVE` (macOS/Linux) | Install Gita from a local file instead of the release. No checksum check; for testing builds only. |

Windows example: `$env:TB_DRY_RUN='1'; irm .../install.ps1 | iex`.
macOS/Linux: `curl -fsSL .../install.sh | TB_DRY_RUN=1 bash`.

## For admins: releasing a new Gita version

The installers only install the exact Gita version and checksums pinned at the top of
each script. To move to a new release:

1. Tag the release in `tbaiadmin/gita` (`vX.Y.Z`); CI builds the three downloads into a
   draft release. Check it and publish it.
2. Get the checksums:
   ```bash
   gh release download vX.Y.Z --repo tbaiadmin/gita --dir /tmp/gita-vX.Y.Z
   sha256sum /tmp/gita-vX.Y.Z/*
   ```
3. Update `$GitaVersion` and `$GitaSha256` in `install.ps1`, and `GITA_VERSION`,
   `GITA_SHA256_MACOS`, `GITA_SHA256_LINUX` in `install.sh`. Open a pull request.

This repo is public so the one-line command works without signing in. It must never
hold secrets, tokens or webhook URLs; those come from claude.ai managed settings.
