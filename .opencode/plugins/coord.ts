/**
 * coord.ts — the OpenCode-native coordination surface (`AGENTS.md` "Agent identity
 * & comment coordination", extends rule 9), implemented in PURE TypeScript.
 *
 * HARNESS SPLIT (operator directive, 2026-09-29; supersedes the earlier
 * "co-locate the .sh" brief). Harness-INDEPENDENT tooling is SHELL — the coordination
 * CLI `coord.sh` and the watcher family (`gh_watch.sh`, `pr_watch_many.sh`,
 * `pr_state_watch.sh`, `_watch_common.sh`) stay shell, usable from bash / Claude Code
 * / Codex / git hooks / CI. The OpenCode plugins are PURE TypeScript: they implement
 * the grammar and the watcher NATIVELY and NEVER delegate to a `.sh` — no
 * `Bun.spawn`/`spawnSync` of a script, and no dependency on any script file, hence NO
 * `marketplace` submodule pin. `coord.ts` therefore loads and works from the SAME ref
 * as the plugin, even when the `marketplace` gitlink lags.
 *
 * R3 — the shell CLI and this native implementation are deliberately TWO
 * harness-specific implementations, not a forked copy (the operator's SIGNED-OFF clean
 * split — a maintainer-account R3 divergence): each is native to its harness. The
 * shared CONTRACT is defined ONCE in the shell family's docs — the closed verb set, the
 * canonical two-line footer order, the event vocabulary + wake-line format, and the
 * item grammar — and `scripts/check-opencode-coord.mjs` pins THIS (TypeScript) side of
 * it. Drift in the SHELL side alone is not compared by the gate (the shell is not a
 * dependency — no `.sh`, no pin), so the contract is stated as a SPECIFICATION the TS
 * implements and the gate pins, never as a claim the two "cannot drift". Do NOT
 * re-unify them through a shell-out.
 *
 * PLUGIN CONTRACT (measured 2026-09-28, opencode v2.0.18 — see `.opencode/instructions.md`):
 *   - opencode >= 2.0 loads `default export { id, setup(ctx) }`; tools are registered
 *     with `ctx.tool.transform(draft => draft.add({ name, description, input, execute }))`,
 *     the tool `input` is a JSON Schema, and `execute` returns `{ content }` (a bare
 *     string and `{ output }` both FAIL the runtime with `"output" in s`).
 *   - opencode 1.x loads `{ id, server(input) }` returning a hooks object. 1.x tool
 *     registration needs the zod-based `tool()` helper, so this binding loads there
 *     but registers no tools and returns `{}` — the scripts stay directly callable.
 *
 * TOOLS
 *   coord_comment  build ONE verb-labelled coordination comment (or claim) with the
 *                  canonical footer and POST it directly through the GitHub REST API
 *                  in-process. The session id is filled from the tool context; the
 *                  identity defaults from `.opencode/coord.conf` + `COORD_*` env.
 *   coord_watch    poll the GitHub API NATIVELY (async, `context.signal`-aware) for one
 *                  event on one or more PRs/issues and return the wake line. The
 *                  BACKGROUND continuous watch is `pr-watch.ts`'s job — this is the
 *                  explicit, session-invoked, bounded wait, so the two never duplicate.
 *
 * CONFIG (all optional; last wins: TOOL ARG > `COORD_*` ENV > `.opencode/coord.conf`)
 *   `.opencode/coord.conf` — `key=value` lines, `#` comments:
 *       agent=<work slug>   harness=OpenCode   model=<provider model>   confidence=<tier>
 *   The `session` is always the live session (`context.sessionID`).
 *
 * AUTH — `GITHUB_TOKEN` / `GH_TOKEN`, else the `gh` CLI's stored token
 * (`gh auth token` — one async `execFile`; the `gh` binary is a tool, NOT a `.sh`).
 * `GITHUB_API_URL` overrides the API base (GitHub Enterprise / tests).
 *
 * Defensive: a missing token or a GitHub error returns a clear message to the caller —
 * the plugin never throws into opencode startup.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  ghJson,
  parseEvents,
  parseItem,
  pollOnce,
  seedAll,
  sleepAbortable,
  watchEvent,
  formatWake,
  armReport,
  armReportEnabled,
  armNotable,
  armStateFire,
  parseReviewVerdict,
  runState,
  clampInterval,
  rateLimitMessage,
  RateLimitedError,
  POLL_FLOOR,
  DEFAULT_INTERVAL_S,
  DEFAULT_STALL_MIN,
  RATE_FLOOR,
  BACKOFF_FACTOR,
  MAX_BACKOFF_S,
  type Fire,
  type Item,
  type Snap,
  type ArmReport,
} from "../lib/watch.ts";

// Re-exported so consumers/tests can assert the CONTRACT (the item grammar, the
// event semantics, the wake-line format, and the named rate-limit policy) through
// this module's own surface.
export {
  parseItem,
  parseEvents,
  watchEvent,
  formatWake,
  armReport,
  armReportEnabled,
  armNotable,
  armStateFire,
  parseReviewVerdict,
  runState,
  clampInterval,
  rateLimitMessage,
  RateLimitedError,
  POLL_FLOOR,
  DEFAULT_INTERVAL_S,
  DEFAULT_STALL_MIN,
  RATE_FLOOR,
  BACKOFF_FACTOR,
  MAX_BACKOFF_S,
};
export type { Fire, Item, Snap };

export const TIERS = [
  "fully tested and validated",
  "analysed on a live system",
  "documentation reviewed",
  "syntax check only",
  "theoretical suggestion",
];

export const VERBS = [
  "CLAIM",
  "OWNING",
  "HANDING OVER",
  "TAKING OVER",
  "BLOCKS",
  "UNBLOCKS",
  "STATUS",
  "RESOLVED",
];

/**
 * The default watcher event set. It MUST include the two DELTA events a validator
 * verdict arrives as — `comment` (the BLOCK/PASS review comment) and `verdict` (the
 * `charly/pr-validator` run reaching a status) — beside the terminal outcomes and the
 * silence alarm. Omitting them is the defect this set exists to prevent: a BLOCK
 * arrives as a COMMENT and a completed run as a VERDICT, so a `merged,closed,stall`
 * default would never wake on either.
 */
export const DEFAULT_EVENTS = "merged,closed,comment,verdict,stall";

/** The default `coord_watch` deadline (seconds) — a bounded, session-invoked wait. */
export const DEFAULT_WATCH_TIMEOUT_S = 3600;

/** Parse `.opencode/coord.conf` (key=value, `#` comments, blanks ignored). */
export function parseConf(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (line === "" || line.startsWith("#")) continue;
    const i = line.indexOf("=");
    if (i === -1) continue;
    const key = line.slice(0, i).trim();
    const value = line.slice(i + 1).trim();
    if (key) out[key] = value;
  }
  return out;
}

export function isTier(value: unknown): value is string {
  return typeof value === "string" && TIERS.includes(value);
}

/**
 * Canonicalise a verb exactly like `coord.sh`: upper-case, `-`/`_` → space, collapse
 * runs of spaces, trim. Returns the canonical label, or `""` when it is not one of the
 * closed set — the contract both implementations share.
 */
export function canonicalVerb(verb: unknown): string {
  const canon = String(verb ?? "")
    .toUpperCase()
    .replace(/[_-]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return VERBS.includes(canon) ? canon : "";
}

/**
 * Build the comment body: the canonical verb label on the FIRST line, the optional
 * body, then the TWO identity lines in the canonical order — `Agent:` FIRST,
 * `Assisted-by:` LAST (the order the pr-validator requires). Byte-compatible with
 * `coord.sh`'s output for the same inputs.
 */
export function buildComment(
  verb: string,
  body: string | undefined,
  id: { agent: string; session: string; harness: string; model: string; confidence: string },
): string {
  const footerAgent = `*Agent: \`${id.agent}\` · session \`${id.session}\`*`;
  const footerAssisted = `*Assisted-by: ${id.harness} ${id.model} (${id.confidence})*`;
  if (body) return `${verb}\n\n${body}\n\n${footerAgent}\n${footerAssisted}`;
  return `${verb}\n\n${footerAgent}\n${footerAssisted}`;
}

/**
 * Resolve the footer identity. Precedence, highest first:
 *   args (the tool call) > env (`COORD_*`) > conf (`.opencode/coord.conf`).
 * `session` is special: the live session always wins when provided, so a stale
 * env/conf can never mislabel who is speaking.
 */
export function resolveIdentity(
  args: Record<string, any>,
  conf: Record<string, string>,
  env: Record<string, string | undefined>,
  sessionID: string | undefined,
): { agent: string; session: string; harness: string; model: string; confidence: string } {
  const pick = (...vals: Array<string | undefined>) =>
    vals.find((v) => typeof v === "string" && v !== "") ?? "";
  const session = pick(sessionID, args.session, env.COORD_SESSION, conf.session);
  return {
    agent: pick(args.agent, env.COORD_AGENT, conf.agent),
    session,
    harness: pick(args.harness, env.COORD_HARNESS, conf.harness),
    model: pick(args.model, env.COORD_MODEL, conf.model),
    confidence: pick(args.confidence, env.COORD_CONFIDENCE, conf.confidence),
  };
}

/**
 * Post a comment body to an item via the GitHub REST API and return the comment URL.
 * Native HTTP — no script, no `gh` CLI for the write path.
 */
export async function postComment(
  item: Item,
  body: string,
  opts: { assign?: boolean; signal?: AbortSignal } = {},
): Promise<string> {
  const res = await ghJson<{ html_url?: string }>(
    `/repos/${item.owner}/${item.repo}/issues/${item.num}/comments`,
    { method: "POST", body: { body }, signal: opts.signal },
  );
  if (opts.assign) {
    const me = await ghJson<{ login?: string }>("/user", { signal: opts.signal });
    if (me?.login) {
      await ghJson(`/repos/${item.owner}/${item.repo}/issues/${item.num}/assignees`, {
        method: "POST",
        body: { assignees: [me.login] },
        signal: opts.signal,
      });
    }
  }
  return String(res?.html_url ?? "");
}

/**
 * Run a bounded native watch over `items` until the first event or the timeout.
 * Async + `signal`-aware (the poll sleep and every `fetch` take the signal), so it
 * never blocks opencode's event loop and stopping the Session terminates it.
 *
 * API EFFICIENCY: ONE batched GraphQL request per poll regardless of item count; an
 * idle poll costs one call per interval. RATE LIMITS FAIL HARD — a `RateLimitedError`
 * is RETURNED distinctly (never retried as "no event", never a spin). A near-exhausted
 * quota (read FREE from the batched response's rate header) backs off VISIBLY. The
 * `intervalSec` is clamped to `POLL_FLOOR`.
 *
 * AT ARM: a STATE event already in force (an already-merged/closed item, `watchEvent`
 * with seed===cur) WINS — it is a genuine wake and never loops. Otherwise, when the arm
 * baseline is notable (a pre-existing BLOCK verdict or an in-flight run), the watch
 * returns its ARM report IMMEDIATELY (`armFired`) rather than waiting for a comment that
 * may never come.
 */
export async function runWatch(
  items: Item[],
  opts: {
    events: string;
    intervalSec: number;
    stallMin: number;
    workflow: string;
    timeoutSec: number;
    signal?: AbortSignal;
  },
): Promise<{
  fire: Fire | null;
  /** The ARM baseline reports (one per item), delivered as the FIRST emission. */
  reports: ArmReport[];
  /** True when the ARM baseline alone was notable enough to wake (no wait needed). */
  armFired: boolean;
  timedOut: boolean;
  rateLimited?: RateLimitedError;
}> {
  const events = parseEvents(opts.events, DEFAULT_EVENTS);
  const intervalSec = clampInterval(opts.intervalSec);
  const armEpoch = Math.floor(Date.now() / 1000);
  const none = { fire: null, reports: [] as Fire[], armFired: false, timedOut: false };
  let seeds: Map<string, Snap>;
  let reports: ArmReport[] = [];
  try {
    const seeded = await seedAll(items, { wf: opts.workflow, signal: opts.signal, events });
    seeds = seeded.seeds;
    reports = seeded.reports;
  } catch (err) {
    if (err instanceof RateLimitedError) return { ...none, rateLimited: err };
    if (opts.signal?.aborted) return none;
    seeds = new Map(); // a transient seed failure: proceed; no seed → no delta fire
  }
  // A STATE event already in force at arm (merged/closed/stall) is a genuine wake and
  // MUST resolve BEFORE the arm report — otherwise an already-merged item with a
  // pre-existing BLOCK would re-emit its ARM baseline forever and never report MERGED.
  // The ARM report still travels WITH it, so the baseline is always the first line.
  const armFire = armStateFire(items, seeds, events, {
    armEpoch,
    nowEpoch: Math.floor(Date.now() / 1000),
    stallMin: opts.stallMin,
    wf: opts.workflow,
  });
  if (armFire) return { fire: armFire, reports, armFired: false, timedOut: false };
  // A pre-existing BLOCK/verdict or an IN-FLIGHT run at arm is the missed-verdict case:
  // wake IMMEDIATELY with the baseline rather than waiting for a new comment.
  if (reports.some((r) => armNotable(r.snap))) {
    return { fire: null, reports, armFired: true, timedOut: false };
  }
  const start = Date.now();

  for (;;) {
    if (opts.signal?.aborted) return { ...none, reports };
    if (opts.timeoutSec > 0 && Date.now() - start >= opts.timeoutSec * 1000) {
      return { fire: null, reports, armFired: false, timedOut: true };
    }
    let outcome;
    try {
      outcome = await pollOnce(items, seeds, {
        events,
        wf: opts.workflow,
        armEpoch,
        stallMin: opts.stallMin,
        signal: opts.signal,
      });
    } catch (err) {
      if (err instanceof RateLimitedError) {
        // FAIL HARD: surface the rate limit distinctly; never retry as "no event".
        return { ...none, reports, rateLimited: err };
      }
      if (opts.signal?.aborted) return { ...none, reports };
      // A transient (non-rate-limit) API failure skips this poll, never kills the watch.
      await sleepAbortable(intervalSec * 1000, opts.signal);
      continue;
    }
    if (outcome.fire) return { fire: outcome.fire, reports, armFired: false, timedOut: false };
    // A near-exhausted quota (FREE header read) → back off VISIBLY, never hammer.
    if (outcome.rateRemaining !== null && outcome.rateRemaining < RATE_FLOOR) {
      await sleepAbortable(Math.min(intervalSec * BACKOFF_FACTOR, MAX_BACKOFF_S) * 1000, opts.signal);
      continue;
    }
    await sleepAbortable(intervalSec * 1000, opts.signal);
  }
}

export default {
  id: "coord",
  // opencode >= 2.0 definition form: register the coordination tools.
  async setup(ctx: any) {
    const dir = ctx?.location?.directory ?? process.cwd();
    const confPath = join(dir, ".opencode", "coord.conf");
    let conf: Record<string, string> = {};
    try {
      conf = parseConf(readFileSync(confPath, "utf8"));
    } catch {
      /* no config → env/args only */
    }

    await ctx.tool.transform((draft: any) => {
      draft.add({
        name: "coord_comment",
        description:
          "Post ONE verb-labelled coordination comment (or claim) on a GitHub " +
          "issue/PR, with the canonical agent footer (`Agent:` first, " +
          "`Assisted-by:` last). Use it for CLAIM / OWNING / HANDING OVER / " +
          "TAKING OVER / BLOCKS / UNBLOCKS / STATUS / RESOLVED per AGENTS.md. " +
          "Implemented natively in TypeScript.",
        input: {
          type: "object",
          properties: {
            verb: { type: "string", description: `one of: ${VERBS.join(", ")}` },
            item: {
              type: "string",
              description: "owner/repo#num (or owner/repo/pull/num, or a full URL)",
            },
            body: { type: "string", description: "GitHub-Markdown body (optional)" },
            agent: { type: "string", description: "work slug for the `Agent:` line" },
            session: { type: "string", description: "session id (auto-filled if omitted)" },
            harness: { type: "string", description: "e.g. OpenCode" },
            model: { type: "string", description: "provider model name" },
            confidence: { type: "string", description: `one of: ${TIERS.join(" | ")}` },
            assign: { type: "boolean", description: "also assign the posting account (a CLAIM)" },
            dryRun: { type: "boolean", description: "return the comment; do NOT post it" },
          },
          // `confidence` is intentionally optional: it is resolved from
          // .opencode/coord.conf / COORD_* env when the caller omits it.
          required: ["verb", "item"],
        },
        execute: async (input: Record<string, any>, toolCtx: any) => {
          const verb = canonicalVerb(input.verb);
          if (!verb) {
            return { content: `coord_comment: invalid verb '${input.verb}' — one of: ${VERBS.join(" | ")}` };
          }
          const item = parseItem(input.item);
          if (!item) {
            return {
              content: `coord_comment: unrecognised target '${input.item}' — want owner/repo#num or owner/repo/pull/num`,
            };
          }
          const id = resolveIdentity(input, conf, process.env, toolCtx?.sessionID);
          const missing = (["agent", "session", "harness", "model", "confidence"] as const).filter(
            (k) => !id[k],
          );
          if (missing.length) {
            return {
              content:
                `coord_comment: missing ${missing.map((m) => "--" + m).join(", ")} — ` +
                `pass them as tool args, set COORD_* env, or fill .opencode/coord.conf`,
            };
          }
          if (!isTier(id.confidence)) {
            return { content: `coord_comment: invalid confidence '${id.confidence}' — one of: ${TIERS.join(" | ")}` };
          }
          const comment = buildComment(verb, input.body ? String(input.body) : undefined, id);
          if (input.dryRun) return { content: comment };
          try {
            const url = await postComment(item, comment, {
              assign: !!input.assign,
              signal: toolCtx?.signal,
            });
            return { content: url || `coord_comment: posted (no html_url returned)` };
          } catch (err: any) {
            return { content: `coord_comment: GitHub API error — ${err?.message ?? String(err)}` };
          }
        },
      });

      draft.add({
        name: "coord_watch",
        description:
          "Wait (one-shot, bounded) natively in TypeScript for a GitHub event on one " +
          "or more PRs/issues: merged / closed / comment / verdict / stall. Returns " +
          "the wake line, or a TIMEOUT notice. For a continuous background watch use " +
          "the pr-watch plugin instead.",
        input: {
          type: "object",
          properties: {
            items: {
              type: "array",
              items: { type: "string" },
              description: "owner/repo#num items to watch",
            },
            events: { type: "string", description: `comma list (default: ${DEFAULT_EVENTS})` },
            interval: {
              type: "number",
              description: `poll cadence, seconds (floor ${POLL_FLOOR}, default ${DEFAULT_INTERVAL_S}); sub-floor values are refused/clamped`,
            },
            stallmin: { type: "number", description: `stall window, minutes (default ${DEFAULT_STALL_MIN})` },
            workflow: { type: "string", description: "validator run name (default charly/pr-validator)" },
            timeout: {
              type: "number",
              description: `overall deadline, seconds (default ${DEFAULT_WATCH_TIMEOUT_S} = 1h; 0 = unbounded, only with autoRearm)`,
            },
            autoRearm: {
              type: "boolean",
              description: "durable intent: lift the default deadline (wait until an event, a provided timeout, or abort)",
            },
          },
          required: ["items"],
        },
        execute: async (input: Record<string, any>, toolCtx: any) => {
          if (!Array.isArray(input.items) || input.items.length === 0) {
            return { content: "coord_watch: pass at least one item (owner/repo#num)" };
          }
          const items: Item[] = [];
          for (const raw of input.items) {
            const it = parseItem(raw);
            if (!it) return { content: `coord_watch: malformed item '${raw}' — want owner/repo#num` };
            items.push(it);
          }
          // BOUNDED BY DEFAULT (R4): a session-invoked wait always carries a wall-clock
          // deadline. An explicit `timeout` wins; otherwise the named default applies.
          // `autoRearm` (durable intent) lifts it to unbounded; a `timeout` still wins.
          const explicit = typeof input.timeout === "number" && input.timeout >= 0 ? input.timeout : undefined;
          const timeoutSec =
            explicit !== undefined ? explicit : input.autoRearm ? 0 : DEFAULT_WATCH_TIMEOUT_S;
          if (typeof input.interval === "number" && input.interval < POLL_FLOOR) {
            return {
              content: `coord_watch: interval ${input.interval}s is below the ${POLL_FLOOR}s floor — refusing (never hammer the API)`,
            };
          }
          const intervalSec = clampInterval(input.interval);
          const { fire, reports, armFired, timedOut, rateLimited } = await runWatch(items, {
            events: String(input.events ?? DEFAULT_EVENTS),
            intervalSec,
            stallMin: typeof input.stallmin === "number" && input.stallmin >= 0 ? input.stallmin : DEFAULT_STALL_MIN,
            workflow: String(input.workflow ?? "charly/pr-validator"),
            timeoutSec,
            signal: toolCtx?.signal,
          });
          if (toolCtx?.signal?.aborted) return { content: "coord_watch: aborted (session interrupted)" };
          if (rateLimited) return { content: `coord_watch: ${rateLimitMessage(rateLimited)}` };
          // The ARM report fires FIRST: the baseline the watch armed on — a pre-existing
          // BLOCK/verdict or an in-flight run is surfaced IMMEDIATELY (the missed-verdict
          // case), never withheld for a comment that may never come.
          const baseline = reports.map((r) => r.line).join("\n");
          if (fire) return { content: baseline ? `${baseline}\n${fire.line}` : fire.line };
          if (armFired) return { content: baseline || "coord_watch: armed" };
          if (timedOut) {
            return { content: baseline ? `${baseline}\nTIMEOUT: no event within ${timeoutSec}s` : `TIMEOUT: no event within ${timeoutSec}s` };
          }
          return { content: baseline || "coord_watch: watch ended with no event" };
        },
      });
    });
  },
  // opencode 1.x function form: loads, but tool registration needs zod → no-op.
  async server(_input: any) {
    return {};
  },
};
