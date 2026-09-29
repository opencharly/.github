# opencode harness instructions

This file binds the harness-neutral `AGENTS.md` rulebook to this harness's
mechanics. It is opencode-specific by construction and lives in the opencode
config layer (`.opencode/`), never in `AGENTS.md`.

## Skill addressing

`AGENTS.md` addresses every skill by its canonical, harness-neutral reference
`/charly-<family>:<skill>` (e.g. `/charly-internals:git-workflow`). These
references are also the marketplace-wide cross-reference syntax the docs build
resolves, so they are kept verbatim.

opencode's `skill` tool does **not** accept the namespaced form: skill names must
match `^[a-z0-9]+(-[a-z0-9]+)*$`, which forbids `:` and `/`. opencode loads every
skill under a configured `skills.paths` entry (here: `marketplace`) and exposes it
by its **bare frontmatter `name`**, which is globally unique across the corpus.

**Resolve a dispatcher reference as follows:**

| Canonical reference | opencode `skill` tool call |
|---|---|
| `/charly-<family>:<skill>` | `skill({ name: "<skill>" })` |

Examples:

- `/charly-internals:git-workflow` → `skill({ name: "git-workflow" })`
- `/charly-check:check` → `skill({ name: "check" })`
- `/charly-core:charly-config` → `skill({ name: "charly-config" })`

If a skill is not exposed as a tool entry, read its procedure directly at
`marketplace/<family>/skills/<skill>/SKILL.md` (the same fallback every harness
uses). Never proceed without loading the procedure — R0 is mandatory.

## Gate hooks

`.opencode/plugins/umbrella-gates.ts` runs the root gate scripts
(`.claude/hooks/pre-commit-gate.sh`, `pre-push-gate.sh`) before `git commit` /
`git push` shell calls and denies the call when a gate blocks.

### opencode plugin contract

opencode has TWO plugin shapes, and the loader picks by the default export:
- **opencode ≥ 2.0** — `{ id, setup(ctx) }`, registering hooks via
  `ctx.tool.hook("execute.before", …)`; the shell tool is named `shell`.
- **opencode 1.x** — `{ id, server(input) }`, returning a hooks object keyed by
  `"tool.execute.before"`; the shell tool is named `bash`. A definition WITHOUT
  `server` is REJECTED at startup: `must default export an object with server()`.
  The bare function form (`async (input) => ({...})`) does not load on ≥ 2.0.

A plugin MUST export **both** `setup` and `server` (sharing ONE implementation) so
it loads and enforces under EITHER generation. Measured (2026-09-28, R1): a
`setup`-only plugin was REJECTED by the then-installed **1.18.33** with
`failed to load plugin … must default export an object with server()` on every
startup, and the gates blocked nothing — the regression this rule prevents. The
host has since been upgraded to **v2.0.18** (which loads `setup`), so the dual
export is the portable form, not a host workaround. `scripts/check-opencode-plugin.mjs`
requires BOTH entry points and, with `LIVE_OPENCODE=1`, drives the real binary end
to end.

### V2 custom tools (measured against v2.0.18)

A V2 `setup(ctx)` registers a custom tool through `ctx.tool.transform`:

    await ctx.tool.transform((draft) => {
      draft.add({
        name: "my_tool",
        description: "…",
        input: { type: "object", properties: { … }, required: ["…"] }, // JSON Schema
        execute: async (args, toolCtx) => ({ content: "…" }),           // { content } REQUIRED
      });
    });

Measured (2026-09-28, live against v2.0.18): `tool.transform(cb)` invokes `cb` with a
draft exposing `list/get/namespace/add/update/remove`; the tool `input` is a plain
JSON Schema; the `execute` result MUST be `{ content: string }` — a bare string and
`{ output }` both FAIL at runtime (`s is not an Object. (evaluating '"output" in s')`).
The `setup(ctx)` context is FAR richer than the published `@opencode-ai/plugin/v2`
types: besides `tool`, `options`, `location`, `agent`, `command`, `event`, `skill`,
`reference`, `aisdk`, `integration` it also carries `session`, `shell`, `vcs`,
`worktree`, `permission`, `provider`, `model`, `mcp`, `storage`, `rpc`, `websearch`,
`generate`, `app`, `experimental`. `ctx.location.directory` is the project root;
`ctx.session.prompt({…})` is the canonical prompt call. Type-only imports
(`import type { Plugin } from "@opencode-ai/plugin/v2/promise"`) are erased at
runtime, so a local plugin needs NO `node_modules` to load; the declared
`@opencode-ai/plugin` version must nonetheless be one that ships the `./v2/promise`
export. **Both 1.18.32 and 1.18.33 ship it** (verified against their published
packages); the pin tracks **1.18.33**, the newest release on the `latest` tag.

### Coordination tools (`.opencode/plugins/coord.ts`)

`coord.ts` registers two V2 custom tools implemented NATIVELY in TypeScript, so a
session posts the canonical coordination comment and waits on GitHub without
hand-writing the footer:

- **`coord_comment`** — builds the verb-labelled comment
  (`CLAIM`/`OWNING`/`HANDING OVER`/`TAKING OVER`/`BLOCKS`/`UNBLOCKS`/`STATUS`/`RESOLVED`)
  carrying the canonical TWO-LINE footer (`Agent:` FIRST, `Assisted-by:` LAST) and
  POSTs it directly through the GitHub REST API; it can `assign` the posting account
  (a CLAIM).
- **`coord_watch`** — a bounded, session-invoked one-shot wait
  (`events`/`timeout`/`stallmin`) that polls the GitHub API NATIVELY and returns the
  wake line. The BACKGROUND continuous watch stays `pr-watch.ts`'s job.

Identity (`agent`/`harness`/`model`/`confidence`) defaults from
`.opencode/coord.conf` (git-ignored; copy `.opencode/coord.conf.example`) then
`COORD_*` env; the `session` is always the live `toolCtx.sessionID`, so a stale
config can never mislabel who is speaking.

**PURE TYPESCRIPT — no shell delegation, no submodule pin (operator directive,
2026-09-29).** Harness-INDEPENDENT tooling is SHELL — the coordination CLI
`coord.sh` and the watcher family (`gh_watch.sh`, `pr_watch_many.sh`,
`pr_state_watch.sh`, `_watch_common.sh`) stay shell, usable from bash / Claude Code /
Codex / git hooks / CI. The OpenCode plugins are PURE TypeScript and NEVER spawn
those scripts (no `Bun.spawn`/`spawnSync` of a `.sh`, no reference to any script
file), so they load and work from the SAME ref as the plugin — with NO `marketplace`
submodule pin to lag. This is deliberately TWO harness-native implementations of ONE
shared CONTRACT (the closed verb set, the canonical footer order, the event
vocabulary + wake-line format, the item grammar) — a maintainer-account R3 divergence,
not a forked copy. `scripts/check-opencode-coord.mjs` pins the CONTRACT on the
TypeScript side (unit layer) AND, **where the shell family is present**, RUNS
`coord.sh` and diffs its output against the TypeScript output (Layer B3); it SKIPS
that comparison visibly where the shell is absent, so the gate never depends on the
pin.

**API EFFICIENCY + RATE LIMITS (operator requirement, 2026-09-29).**
- **ONE request per poll for N items** — a single batched GraphQL query with one alias
  per item; calls-per-poll is **1** regardless of item count (asserted by the gate).
- **Skip unchanged items** — a per-item fingerprint (`state|merged|updatedAt|comments|
  verdict|commit`) means an idle watch costs exactly one batched call per interval;
  delta events (comment/verdict) are only evaluated on a change (state events are
  always evaluated — they are arm-baseline driven).
- **Rate limits FAIL HARD** — a REST 403/429 or a GraphQL `RATE_LIMITED` throws
  `RateLimitedError`; the tool returns a distinct `RATE-LIMITED …` message and the
  watch STOPS (never spins, never reports it as "no event"). The remaining quota is
  read FREE from the batched response's `x-ratelimit-remaining` header, so a
  near-exhausted quota backs off VISIBLY without an extra call.
- **`POLL_FLOOR = 60`** — a sub-60s interval is refused; `clampInterval` enforces it.

**Execution is ASYNC + ABORTABLE (R1 fix, measured 2026-09-28; preserved by the
native rewrite).** `coord_watch` runs a LONG-LIVED poll loop, so a blocking spawn
froze opencode's server event loop and the supervisor restarted it. The native loop
is fully async and wires the tool executor's `context.signal` into every `fetch` and
the poll sleep, so stopping the Session terminates the watch promptly. Auth is
`GITHUB_TOKEN`/`GH_TOKEN`, else the `gh` CLI's stored token (`gh auth token` — one
async `execFile`; the `gh` binary is a tool, not a `.sh`); `GITHUB_API_URL` overrides
the API base (GitHub Enterprise / tests). `scripts/check-opencode-coord.mjs` asserts
statically that `coord.ts`/`pr-watch.ts` contain NO `.sh`, NO `spawnSync`, and NO
`Bun.spawn`; runs the shell family vs the TypeScript output where the shell is present
(Layer B3); drives the tools against a REAL local HTTP server (calls-per-poll, rate-limit
fail-hard, poll-floor); and — live — drives the REAL binary against a local capture
server (`GITHUB_API_URL`). The A/B/B2/B3 layers run in-process under plain `node`; only
the LIVE C layer drives the REAL opencode binary (it SKIPS visibly when `LIVE_OPENCODE`
is unset; the model's tool-invocation is stochastic, so the C layer's tool-call
assertions are live-or-skip, while the plugin-load + no-reload assertions are
deterministic).

### Watching for PR events (opencode)

The watcher is the harness-independent `marketplace/scripts/gh_watch.sh` family
(`pr_watch_many.sh`, `pr_state_watch.sh`) — run one, never hand-roll a `sleep` poll. It
emits one line per event and exits; re-arm after each wake.

The PR-event binding is `.opencode/plugins/pr-watch.ts`. It is PURE TypeScript: it
polls the GitHub API NATIVELY (via the shared engine `../lib/watch.ts` — the same one
`coord.ts` uses) and NEVER spawns `gh_watch.sh`, so it depends on no `.sh` and no
`marketplace` pin; delivery is IN-PROCESS — never an `opencode run` subprocess (that
starts a separate headless run, can race the live session, and interrupts the
in-flight turn). It shares the event vocabulary + wake-line format with the shell
family (asserted by the gate).

**V2 delivery (opencode ≥ 2.0, MEASURED against v2.0.18).** The `setup(ctx)` context
carries NO `client` (only 1.x's `server(input)` does). The V2 "inject context without
starting a turn" primitive is the Session domain:

    await ctx.session.synthetic({ sessionID, text: alert });

`session.synthetic` enqueues a synthetic message whose default `delivery` is `steer`,
so the alert is ADDED to the running session rather than starting a new turn (the same
interruption-safe intent as 1.x's `noReply: true`). The session id is unknown at setup
and `session.list` does not exist on V2, so it is CAPTURED from the first tool call
(`ctx.tool.hook("execute.before", e => e.sessionID)`) or the first prompt
(`ctx.session.hook("prompt", e => e.sessionID)`); if no id is captured before a wake,
the wake is a logged warning, never a silent drop.

**V1 delivery (opencode 1.x).** The documented SDK-client shape —
`client.tui.showToast(...)` plus `client.session.prompt({ path: { id }, body: { noReply:
true, parts: […] } })`, the target resolved from `client.session.list()` (the most
recently updated root session in this directory).

Config: one item per line in `.opencode/pr-watch.items` (`acme/widget#12`; blank lines
and `#` comments ignored). The shipped file contains only comments, so the plugin is
**inert until you add an item**. It polls GitHub natively (no `gh_watch.sh`, no
`marketplace` pin). Plugins load once at startup — **restart** to activate.
`scripts/check-pr-watch.mjs` asserts the delivery primitives are present as CODE
(comments stripped), so a commented-out or absent call fails the gate.
