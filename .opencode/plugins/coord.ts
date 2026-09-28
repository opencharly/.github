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
 * harness-specific implementations, not a forked copy (the operator's chosen clean
 * split): each is native to its harness. They share ONE *contract* — the closed verb
 * set, the canonical two-line footer order, the event vocabulary + wake-line format,
 * and the item grammar — asserted by `scripts/check-opencode-coord.mjs` so the two
 * cannot drift. Do NOT re-unify them through a shell-out.
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
  rateRemaining,
  seedAll,
  sleepAbortable,
  watchEvent,
  formatWake,
  type Fire,
  type Item,
  type Snap,
} from "../lib/watch.ts";

// Re-exported so consumers/tests can assert the SHARED CONTRACT (the item grammar,
// the event semantics, and the wake-line format) through this module's own surface.
export { parseItem, parseEvents, watchEvent, formatWake };
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

/** The default watcher event set — terminal outcomes plus the silence alarm. */
export const DEFAULT_EVENTS = "merged,closed,stall";

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
): Promise<{ fire: Fire | null; timedOut: boolean }> {
  const events = parseEvents(opts.events, DEFAULT_EVENTS);
  const armEpoch = Math.floor(Date.now() / 1000);
  const seeds = await seedAll(items, { wf: opts.workflow, signal: opts.signal });
  const start = Date.now();

  for (;;) {
    if (opts.signal?.aborted) return { fire: null, timedOut: false };
    if (opts.timeoutSec > 0 && Date.now() - start >= opts.timeoutSec * 1000) {
      return { fire: null, timedOut: true };
    }
    // Rate-limit discipline: the watchers share the account's core quota, so back off
    // (never hammer) when it is nearly exhausted. A failed read is UNKNOWN → no backoff.
    const rem = await rateRemaining(opts.signal);
    if (rem !== null && rem < 200) {
      await sleepAbortable(Math.min(opts.intervalSec * 4, 600) * 1000, opts.signal);
      continue;
    }
    try {
      const fire = await pollOnce(items, seeds, {
        events,
        wf: opts.workflow,
        armEpoch,
        stallMin: opts.stallMin,
        signal: opts.signal,
      });
      if (fire) return { fire, timedOut: false };
    } catch (err) {
      // A transient API failure skips this poll, never kills the watch.
      if (opts.signal?.aborted) return { fire: null, timedOut: false };
    }
    await sleepAbortable(opts.intervalSec * 1000, opts.signal);
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
            interval: { type: "number", description: "poll cadence, seconds (default 30)" },
            stallmin: { type: "number", description: "stall window, minutes (default 60)" },
            workflow: { type: "string", description: "validator run name (default charly/pr-validator)" },
            timeout: { type: "number", description: "overall deadline, seconds (0 = none)" },
            autoRearm: {
              type: "boolean",
              description: "durable intent: accept but ignore the timeout (wait until an event or abort)",
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
          const timeoutSec = input.autoRearm
            ? 0
            : typeof input.timeout === "number" && input.timeout > 0
              ? input.timeout
              : 0;
          const { fire, timedOut } = await runWatch(items, {
            events: String(input.events ?? DEFAULT_EVENTS),
            intervalSec: typeof input.interval === "number" && input.interval >= 1 ? input.interval : 30,
            stallMin: typeof input.stallmin === "number" && input.stallmin >= 0 ? input.stallmin : 60,
            workflow: String(input.workflow ?? "charly/pr-validator"),
            timeoutSec,
            signal: toolCtx?.signal,
          });
          if (toolCtx?.signal?.aborted) return { content: "coord_watch: aborted (session interrupted)" };
          if (fire) return { content: fire.line };
          if (timedOut) return { content: `TIMEOUT: no event within ${input.timeout}s` };
          return { content: "coord_watch: watch ended with no event" };
        },
      });
    });
  },
  // opencode 1.x function form: loads, but tool registration needs zod → no-op.
  async server(_input: any) {
    return {};
  },
};
