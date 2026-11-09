---
type: feature            # feature | fix | improvement | breaking | security | docs | internal
area: figma              # short, lowercase, e.g. login; test IDs use it: LOGIN-001
title: Optional Figma setup for frontend developers (Figma MCP Bridge)
authors: [naseebnaushad46]
branch: feature/figma-bridge
cr: CR-0.1.0-02
after_the_fact: false    # true when written later from the diff (by /promote catch-up)
---

## What changed and why
The setup now asks **"Set up Figma for frontend work (Figma MCP Bridge)? [y/N]"**. On
"yes" (or `TB_FIGMA=1`) it gets a Windows or macOS machine ready to use Claude Code with
the team's shared Figma files through the Figma MCP Bridge, which avoids the low request
limits of Figma's own API and MCP on free accounts. It installs Node.js 20+ and the Figma
desktop app if missing, installs a pinned, checksum-checked bridge server and plugin into
`~/.thoughtbox/figma-mcp-bridge`, adds `figma-bridge` to Claude Code for the user, and
prints the one manual step (importing the plugin in Figma).

The default is "no", and without a terminal the step is skipped, so nothing changes for
developers who don't opt in, or for CI. Linux prints that the step isn't available (there's
no Figma desktop app).

## How it works (logic)
- Pinned values at the top of each script: version, SHA-512 of the npm tarball, SHA-256
  of the release zip ([install.ps1:30](../../install.ps1#L30), [install.sh:30](../../install.sh#L30)).
- Asking: `Want-Figma` / `want_figma` ([install.ps1:133](../../install.ps1#L133),
  [install.sh:429](../../install.sh#L429)). `TB_FIGMA=1|0` answers; any other value
  warns and skips; no terminal means no.
- Install: `Install-FigmaBridge` / `install_figma_bridge` + `install_figma_files`
  ([install.ps1:165](../../install.ps1#L165), [install.sh:458](../../install.sh#L458),
  [install.sh:523](../../install.sh#L523)):
  1. Node.js ≥ 20, else install (winget `OpenJS.NodeJS.LTS` / Homebrew `node`).
  2. Figma desktop app, else install (winget `Figma.Figma` / Homebrew cask); a failure
     here only warns.
  3. `npm pack` the pinned version, check SHA-512; download the plugin zip, check
     SHA-256; build the new copy in a temp folder (`npm install --ignore-scripts
     --omit=dev`), then swap it in. A `version` file lets a re-run skip it. If the bridge
     is running from that folder, it stops and says to close Claude Code first.
  4. `claude mcp add figma-bridge --scope user --env FIGMA_BRIDGE_ENABLE_RUN_SCRIPT=1 --
     <absolute node> <entry>`; skipped when the same entry is already there.
- Optional means optional: any failure becomes a warning and the setup carries on
  (step 6 in [install.ps1:426](../../install.ps1#L426) and
  [install.sh:146](../../install.sh#L146)); bash runs it in a subshell so its `fail`
  only ends this step.
- Windows PowerShell 5.1 turns any stderr line from a native command into a terminating
  error under `Stop`, even with `2>$null`; `Invoke-Native`
  ([install.ps1:145](../../install.ps1#L145)) runs `npm`/`claude` with `Continue`. `npm.cmd`
  is used because `npm.ps1` can be blocked by the execution policy.
- GitHub release downloads (Gita and the plugin) now go through `Get-Download` / `download`,
  which try three times (10 s, then 20 s apart). The first CI run failed twice on GitHub
  504s, once for Gita and once for the plugin.
- CI: new jobs `figma-macos` and `figma-windows`, plus checks in the `unix` job that the
  step is skipped without a terminal and explains itself on Linux.

## Tests added and results
Details: [Alpha Test Cases](../v0.1.0/alpha/v0.1.0%20-%20Alpha%20Test%20Cases%20(Optional%20Figma%20MCP%20Bridge%20setup).md).

| ID | Case | Result |
|---|---|---|
| FIGMA-001 | No `TB_FIGMA`, no terminal → skipped (Windows) | ✅ |
| FIGMA-002 | `TB_FIGMA` with a wrong value → warning, skipped (Windows, Git Bash) | ✅ |
| FIGMA-003 | `TB_FIGMA=1/0/unset` answers (Git Bash) | ✅ |
| FIGMA-004 | Dry run creates nothing (Windows, Git Bash) | ✅ |
| FIGMA-005 | Fresh install on Windows: files, checksums, Claude Code entry "Connected" | ✅ |
| FIGMA-006 | Re-run on Windows skips install and Claude Code entry | ✅ |
| FIGMA-007 | bash file install (macOS logic, run in Git Bash) | ✅ |
| FIGMA-008 | Plugin checksum mismatch → stops, old copy kept | ✅ |
| FIGMA-009 | Plugin download fails → clear message, nothing installed | ✅ |
| FIGMA-010 | CI jobs on macOS, Windows, Linux | ⏳ not run yet (runs on the PR) |
| FIGMA-011 | Manual: import plugin, open shared file, Claude lists it | ⏳ not run |
| FIGMA-012 | GitHub download fails → retried 3 times (10 s, 20 s), then a clear error (bash and Windows) | ✅ |

## Bugs fixed
None (new feature). Two bugs in the new code were found by the tests and fixed before
commit: an empty process list broke `.Count` under strict mode, and `claude mcp get`'s
"not found" on stderr stopped the step in Windows PowerShell.

## Notes for users / upgrade steps
- Frontend developers: run the setup again and answer **yes**, or run it with `TB_FIGMA=1`.
  Then once: Figma desktop app → **Plugins → Development → Import plugin from manifest…**
  → `~/.thoughtbox/figma-mcp-bridge/plugin/manifest.json`.
- `run_script` is on: Claude can run any Plugin API code in the open file with your edit
  rights. README says how to turn it off.
- Anyone who set up the bridge by hand under another name can keep it; this adds a
  separate `figma-bridge` entry. Only one AI tool can run the bridge at a time (port 1994).

## Technical notes
- New variable: `TB_FIGMA` (`1` / `0`).
- Installed on opt-in only (nothing added to this repo): `@gethopp/figma-mcp-bridge` 0.0.25
  (MIT) and its plugin (MIT), Node.js LTS (MIT), Figma desktop app.
- Risk: `npm audit` reports high-severity GHSA-mrhx-c7xc-m3w5 in `zod` 3.25.76 (memory
  use on very large inputs), with no fixed release. Input comes only from the local agent
  and plugin, so the worst case is a local crash. Recorded in the CR and README.
- Risk: the bridge's sub-dependencies follow its semver ranges; only the package itself is
  pinned by checksum.
- The Claude Code entry uses the absolute `node` path found at setup; after a Node.js
  update that moves it, run the setup again with `TB_FIGMA=1`.
- Merge: open PR #2 rewrites both scripts and the README; whichever merges second needs a
  manual merge. The Figma code is in self-contained blocks.

## Suggestions
- Ship an npm lockfile for the bridge so its sub-dependencies are pinned too.
- Move to a bridge release that uses a fixed `zod` when one exists.
- Offer the same setup for Claude Desktop and Cursor users.
