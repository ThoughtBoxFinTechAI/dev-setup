---
type: internal
area: ci
title: CI uses actions/checkout v7.0.1 (Node.js 24)
authors: [naseebnaushad]
branch: fix/checkout-v7
cr: none
after_the_fact: false
---

## What changed and why
- **Before:** every CI job used `actions/checkout` v4: `@v4` in `test-install.yml`, and
  v4.2.2 pinned by commit in `gita-bump.yml`. v4 runs on Node.js 20, which GitHub has
  deprecated. Each run warned: "Node.js 20 is deprecated … being forced to run on Node.js 24".
- **Now:** all seven uses are pinned to v7.0.1 by its commit
  (`3d3c42e5aac5ba805825da76410c181273ba90b1`), which runs on Node.js 24. `test-install.yml`
  now pins by commit too, like `gita-bump.yml` already did, so a moved tag can't change
  what runs.

## Logic
- Only the `uses:` lines changed; no inputs were added or removed.
- What changed in checkout between v4 and v7, and why it doesn't affect us:
  - v5: Node.js 24; needs runner 2.327.1 or newer (GitHub-hosted runners are newer).
  - v6: the saved git credentials live in a separate file. `gita-bump.yml` still pushes
    `bot/gita-X.Y.Z` with them through plain `git push`.
  - v7: refuses to check out a fork's pull request in `pull_request_target` and
    `workflow_run` workflows. Neither workflow uses those triggers.
- Licence: MIT (allowed).

## Tests and results
| ID | Check | Result |
|---|---|---|
| CI-001 | All 7 jobs of "Test installers" pass on this branch's pull request, without the Node.js 20 warning | See the PR |
| CI-002 | The commit `3d3c42e…` is the `v7.0.1` tag of `actions/checkout`, and its `action.yml` says `using: node24` | Pass (GitHub API, 2026-11-21) |
| CI-003 | No `actions/checkout@v4` left in `.github/` | Pass |

Not tested: the bump bot's push with v7. It only runs on a schedule or by hand on `main`,
and pushes only when a newer Gita exists. The next Gita release will exercise it.

## Bugs fixed
None. Removes a deprecation warning before GitHub drops Node.js 20.

## Notes for users
Nothing changes for developers.

## Suggestions
- Turn on Dependabot for GitHub Actions so pinned actions are kept current.
