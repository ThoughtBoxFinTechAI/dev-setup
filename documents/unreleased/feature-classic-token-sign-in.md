---
type: feature
area: signin
title: Sign in with a classic GitHub token, with a choice of how long it lasts
authors: [Naseeb Naushad]
branch: feature/classic-token-sign-in
cr: none
after_the_fact: false
---

## What changed and why
GitHub keeps only the 10 newest browser (device-code) sign-ins per account for one OAuth app,
so signing in on another computer can cancel an older sign-in. On 2026-11-21 both of one
developer's sign-ins had been cancelled and the setup asked for the browser code twice.

The setup now offers a **classic token** instead: it never hits that limit, and the developer
chooses how long it lasts (30, 90, 180 days, 1 year preselected, or no expiry) with an
arrow-key menu.

## How it works
- `install.sh` / `install.ps1`, only with a terminal (or `TB_TOKEN_SIGNIN=1`; `0` turns it off;
  never in a dry run or with `TB_SKIP_SIGNIN=1`):
  1. Run `gita onboard ... --skip-sign-in --skip-repos` once, so the profiles exist.
  2. Per account: ask, show the menu (`TB_TOKEN_DAYS` skips it), print GitHub's
     "new classic token" link with Gita's scopes ticked and the exact expiry date to pick.
  3. Read the token with echo off (also before the prompt, so a fast paste is never shown)
     and pipe it to `gita sign-in --profile <label> --with-token --force` on stdin. Up to 3
     tries; an empty answer falls back to the browser code.
  4. Ask GitHub when the token expires (`github-authentication-token-expiration` header; on
     macOS/Linux the token goes to curl in a config on stdin, never on its command line) and
     warn if that is more than 3 days sooner than chosen, or if it never expires.
  5. The normal `gita onboard` run follows; it keeps a sign-in that works and uses the browser
     code only for accounts without one.
- GitHub's docs only describe pre-filling the token page for fine-grained tokens, so the expiry
  of a classic token cannot be set by link. The script shows the date to pick and checks the
  result afterwards.
- Tokens are never read from the environment or an argument, and are not in the log.

## Tests added and results
`install.sh`, on macOS, with a fake `gita` and `curl`, a temporary `HOME` and a pseudo-terminal:
- Menu: arrow keys move the choice, Enter accepts, no stray key echo. Pass.
- Not a token (`bad`) is refused and asked again; a `ghp_` token is passed to `gita sign-in
  --with-token --force` on stdin with the right profile label. Pass.
- Token never appears in the output or the log. Pass.
- Expiry matching the choice: "expires on ... renew then". Sooner than chosen: warning. Pass.
- Second account answered "no": browser code used; the full `gita onboard` still runs. Pass.

Not run: `install.ps1` (no PowerShell on the machine used; the Windows CI jobs parse and run it
with sign-in skipped, so the token path itself is untested), Linux, and a real GitHub token.

## Notes for users / upgrade steps
Nothing changes unless you answer yes. Run the dev-setup command again to use it.

## Suggestions
- Add a CI test that drives the token path with a fake `gita` on all three systems.
- Teach `gita onboard` the same option, so it works without the pre-pass.
