# opencode harness instructions — opencharly/.github

This is the org **dotgithub** repo: GitHub's org-level source of default
community-health files, the org-wide pr-validator, the ruleset owner, and the landing
automation. Its changes land through the SAME PR-only, `charly/pr-validator`-gated
flow every OpenCharly repo uses (see the umbrella `AGENTS.md`, and
`/charly-internals:git-workflow`).

## Coordination tools

`.opencode/plugins/coord.ts` registers the opencode V2 custom tools
**`coord_comment`** and **`coord_watch`** (byte-identical to the umbrella's copy).
Use them for the `AGENTS.md` "Agent identity & comment coordination" grammar:

- `coord_comment` posts ONE verb-labelled comment (`CLAIM` / `OWNING` /
  `HANDING OVER` / `TAKING OVER` / `BLOCKS` / `UNBLOCKS` / `STATUS` / `RESOLVED`)
  carrying the canonical two-line footer (`Agent:` FIRST, `Assisted-by:` LAST).
  Identity defaults come from `.opencode/coord.conf` (copy
  `.opencode/coord.conf.example`); `COORD_*` env overrides win. The session is
  always the live session — it cannot be mislabelled.
- `coord_watch` waits (bounded) for a GitHub event on one or more PRs/issues.

## Where the scripts live

The coordination grammar is implemented ONCE, in the marketplace repo
(`marketplace/scripts/coord.sh`, `gh_watch.sh`) — this repo carries NO forked copy
(R3). Because dotgithub has no `marketplace` submodule, the plugin resolves them as:

1. `COORD_SH` / `GH_WATCH_SH` (env override — an absolute path), else
2. `<this-repo>/marketplace/scripts/…`, else
3. `<this-repo>/../marketplace/scripts/…`

In the umbrella's session-worktree layout the repo sits at
`<umbrella>/.worktrees/<slug>/dotgithub`, so candidate (3) resolves the sibling
`<umbrella>/.worktrees/<slug>/marketplace/scripts/coord.sh` with no configuration.
Outside it, set `COORD_SH`/`GH_WATCH_SH` to the marketplace scripts' absolute path.

## Verification

`scripts/check-opencode-coord.mjs` (byte-identical to the umbrella's copy) is the
A/B/C gate for the plugin. Run it from this repo:

    node scripts/check-opencode-coord.mjs                                   # A/B
    LIVE_OPENCODE=1 node scripts/check-opencode-coord.mjs --coord-sh <path> # + C (real binary)

It SKIPS the C layer visibly when `LIVE_OPENCODE` is unset (live-or-skip; never a
fake).
