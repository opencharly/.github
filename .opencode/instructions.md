# opencode harness instructions — opencharly/.github

This is the org **dotgithub** repo: GitHub's org-level source of default
community-health files, the org-wide pr-validator, the ruleset owner, and the landing
automation. Its changes land through the SAME PR-only, `charly/pr-validator`-gated
flow every OpenCharly repo uses (see the umbrella `AGENTS.md`, and
`/charly-internals:git-workflow`).

## Coordination tools

`.opencode/plugins/coord.ts` registers the opencode V2 custom tools
**`coord_comment`** and **`coord_watch`**. Use them for the `AGENTS.md` "Agent
identity & comment coordination" grammar:

- `coord_comment` posts ONE verb-labelled comment (`CLAIM` / `OWNING` /
  `HANDING OVER` / `TAKING OVER` / `BLOCKS` / `UNBLOCKS` / `STATUS` / `RESOLVED`)
  carrying the canonical two-line footer (`Agent:` FIRST, `Assisted-by:` LAST).
  Identity defaults come from `.opencode/coord.conf` (copy
  `.opencode/coord.conf.example`); `COORD_*` env overrides win. The session is
  always the live session — it cannot be mislabelled.
- `coord_watch` waits (bounded) for a GitHub event on one or more PRs/issues.

## Pure TypeScript — no shell delegation, no submodule pin

Both plugins are implemented NATIVELY in TypeScript (operator directive, 2026-09-29).
They build the comment/footer and poll the GitHub API themselves and NEVER spawn a
`.sh` — so this repo needs NO `marketplace` submodule (which it does not have) and NO
`COORD_SH`/`GH_WATCH_SH` wiring. `coord_comment` POSTs via the GitHub REST API; auth
is `GITHUB_TOKEN` / `GH_TOKEN`, else the `gh` CLI's stored token (`gh auth token`).
`coord_watch` polls natively (async, `context.signal`-aware).

The harness-INDEPENDENT implementation stays in the marketplace repo's SHELL family
(`marketplace/scripts/coord.sh`, `gh_watch.sh`, `pr_watch_many.sh`,
`pr_state_watch.sh`) for bash / Claude Code / Codex / CI use. The shell family and
these TypeScript plugins share ONE contract — the closed verb set, the canonical
footer order, the event vocabulary + wake-line format, the item grammar — asserted by
`scripts/check-opencode-coord.mjs` so the two cannot drift. They are deliberately TWO
harness-native implementations, not a forked copy (R3).

## PR-event watcher

`.opencode/plugins/pr-watch.ts` is included for a continuous background watch: it
polls `.opencode/pr-watch.items` (one `owner/repo#num` per line) NATIVELY (the shared
engine `.opencode/lib/watch.ts`) and delivers each wake IN-PROCESS. It is INERT until
`.opencode/pr-watch.items` carries an item. For an explicit, bounded wait from a
session, prefer the `coord_watch` tool.

## Verification

`scripts/check-opencode-coord.mjs` is the static + unit + live gate for the plugin.
Run it from this repo:

    node scripts/check-opencode-coord.mjs              # static + unit (A/B/B2)
    LIVE_OPENCODE=1 node scripts/check-opencode-coord.mjs   # + C (real binary)

It asserts statically that `coord.ts`/`pr-watch.ts` contain NO `.sh` reference, NO
`spawnSync`, and NO `Bun.spawn`; the unit layer drives both tools against a mock
GitHub API; and the C layer drives the REAL opencode binary end to end against a LOCAL
capture server (`GITHUB_API_URL`), so the real TypeScript POST path runs without a
real GitHub write. It SKIPS the C layer visibly when `LIVE_OPENCODE` is unset
(live-or-skip; never a fake).
