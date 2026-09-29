/**
 * pr-watch.ts — OpenCode-native delivery binding for the PR/issue watcher.
 *
 * HARNESS SPLIT (operator directive, 2026-09-29). The harness-INDEPENDENT watcher is
 * the SHELL family (`marketplace/scripts/gh_watch.sh` + `pr_watch_many.sh` +
 * `pr_state_watch.sh` + `_watch_common.sh`) — usable from any harness. This OpenCode
 * plugin is PURE TypeScript: it polls the GitHub API NATIVELY (via `../lib/watch.ts`,
 * the ONE shared engine) and NEVER spawns a `.sh`, so it depends on NO script and NO
 * `marketplace` pin. It shares the watcher CONTRACT with the shell family (event
 * vocabulary, wake-line format, item grammar), asserted by `scripts/check-opencode-coord.mjs`.
 *
 * DELIVERY — measured 2026-09-28 against the REAL v2.0.18 binary. The V2 `setup(ctx)`
 * context does NOT carry `client`; the V2 "inject context without starting a turn"
 * primitive is `ctx.session.synthetic({ sessionID, text })` (default `delivery: steer`,
 * so the alert is ADDED to the running session). The session id is CAPTURED from the
 * first tool call (`ctx.tool.hook("execute.before", …)`) or the first prompt
 * (`ctx.session.hook("prompt", …)`). The 1.x `server(input)` path keeps the documented
 * SDK-client shape (`client.tui.showToast` + `noReply: true`).
 *
 * Config: one item per line in `.opencode/pr-watch.items` (blank lines and `#`
 * comments ignored). Absent or comment-only → the plugin watches nothing (inert).
 * opencode loads plugins ONCE at startup — RESTART after editing.
 * `setup()` starts the loop detached and returns immediately.
 *
 * Defensive: if the session domain is unavailable or a poll fails transiently, the
 * plugin logs/skips and no-ops; opencode keeps running.
 */
import { wakeLine } from "../lib/wake-line.ts";
import {
  BACKOFF_FACTOR,
  DEFAULT_INTERVAL_S,
  DEFAULT_STALL_MIN,
  MAX_BACKOFF_S,
  RATE_FLOOR,
  RateLimitedError,
  parseEvents,
  parseItem,
  pollOnce,
  rateLimitMessage,
  seedAll,
  sleepAbortable,
  type Item,
  type Snap,
} from "../lib/watch.ts";

// The ONE shared "last non-empty stdout line" helper (R3) — the same module
// `coord.ts` imports. Re-exported under the historical name this plugin's own
// check asserts.
export const lastWakeLine = wakeLine;

/** The watcher event set delivered to the session (delta + terminal outcomes). */
export const WATCH_EVENTS = "comment,merged,closed";

export function parseItems(text: string): string[] {
  return text
    .split("\n")
    .map((s) => s.trim())
    .filter((s) => s.length > 0 && !s.startsWith("#"));
}

export function pickSessionID(sessions: any[], directory: string): string | undefined {
  const roots = sessions.filter(
    (s) => s && typeof s.id === "string" && !s.parentID && s.directory === directory,
  );
  roots.sort((a, b) => (b?.time?.updated ?? 0) - (a?.time?.updated ?? 0));
  return roots[0]?.id;
}

export default {
  id: "pr-watch",
  // opencode >= 2.0 definition form: the context carries `session` + `location`.
  async setup(ctx: any) {
    await watchV2(ctx, ctx?.location?.directory ?? ctx?.directory ?? process.cwd());
  },
  // opencode 1.x function form: the input carries the SDK `client` + `directory`.
  async server(input: any) {
    // The watcher runs as a detached side-effect; the 1.x hook surface has no
    // equivalent registration to return, so return an empty hook map.
    void watchV1(input?.client, input?.directory ?? process.cwd());
    return {};
  },
};

function warn(message: string) {
  console.warn(`pr-watch: ${message}`);
}

// --- shared native watcher loop ---------------------------------------------

async function loop(dir: string, deliver: (line: string) => Promise<void>) {
  const file = `${dir}/.opencode/pr-watch.items`;
  let raw: string;
  try {
    raw = await readText(file);
  } catch {
    return; // no config → watch nothing (inert by default)
  }
  const items: Item[] = [];
  for (const line of parseItems(raw)) {
    const it = parseItem(line);
    if (!it) {
      warn(`ignoring malformed item '${line}' (want owner/repo#num)`);
      continue;
    }
    items.push(it);
  }
  if (items.length === 0) return;

  const events = parseEvents(WATCH_EVENTS, WATCH_EVENTS);
  const wf = "charly/pr-validator";
  const stallMin = DEFAULT_STALL_MIN;
  const intervalMs = DEFAULT_INTERVAL_S * 1000;
  const armEpoch = Math.floor(Date.now() / 1000);
  let seeds: Map<string, Snap>;
  try {
    seeds = await seedAll(items, { wf });
  } catch (err) {
    if (err instanceof RateLimitedError) {
      warn(rateLimitMessage(err));
      return; // fail hard: never spin on a rate limit
    }
    seeds = new Map();
  }

  void (async () => {
    for (;;) {
      try {
        const outcome = await pollOnce(items, seeds, { events, wf, armEpoch, stallMin });
        // `pollOnce` updates `seeds` in place AND skips fingerprint-unchanged items,
        // so the SAME comment/verdict is never delivered twice — no manual re-seed.
        if (outcome.fire) await deliver(outcome.fire.line);
        // A near-exhausted quota (FREE header read) → back off VISIBLY.
        if (outcome.rateRemaining !== null && outcome.rateRemaining < RATE_FLOOR) {
          warn(`core quota remaining=${outcome.rateRemaining} < ${RATE_FLOOR} — backing off`);
          await sleepAbortable(Math.min((intervalMs / 1000) * BACKOFF_FACTOR, MAX_BACKOFF_S) * 1000);
          continue;
        }
      } catch (err) {
        if (err instanceof RateLimitedError) {
          // FAIL HARD: surface the rate limit and STOP this watch — never spin.
          warn(rateLimitMessage(err));
          return;
        }
        /* transient (network) — skip this poll, keep watching */
      }
      await sleepAbortable(intervalMs);
    }
  })();
}

/** Read a file as text under both runtimes (Bun's `Bun.file`, else `node:fs`). */
async function readText(path: string): Promise<string> {
  const bun = (globalThis as { Bun?: any }).Bun;
  if (bun?.file) return bun.file(path).text();
  const { readFileSync } = await import("node:fs");
  return readFileSync(path, "utf8");
}

// --- V2 binding (measured opencode >= 2.0) ----------------------------------

async function watchV2(ctx: any, dir: string) {
  if (!ctx?.session?.synthetic) {
    warn("ctx.session.synthetic unavailable — watcher disabled");
    return;
  }

  let sessionID = "";
  try {
    if (ctx.tool?.hook) {
      await ctx.tool.hook("execute.before", (e: any) => {
        if (e?.sessionID) sessionID = e.sessionID;
      });
    }
    if (ctx.session?.hook) {
      await ctx.session.hook("prompt", (e: any) => {
        if (e?.sessionID) sessionID = e.sessionID;
      });
    }
  } catch {
    /* hook registration unavailable — delivery will warn if it wakes first */
  }

  const deliver = async (line: string) => {
    if (!sessionID) {
      warn(`wake with no session id captured yet: ${line}`);
      return;
    }
    try {
      await ctx.session.synthetic({ sessionID, text: `PR-watch: ${line}` });
    } catch {
      /* delivery unavailable — the loop keeps watching */
    }
  };

  await loop(dir, deliver);
}

// --- V1 binding (opencode 1.x SDK client) -----------------------------------

async function watchV1(client: any, dir: string) {
  if (!client?.tui?.showToast) {
    warn("1.x SDK client unavailable — watcher disabled");
    return;
  }
  const deliver = async (line: string) => {
    await client.tui
      .showToast({ body: { message: `PR-watch: ${line}`, variant: "info" } })
      .catch(() => {});
    try {
      const res = await client.session.list();
      const sessions = res?.data ?? res ?? [];
      const id = pickSessionID(sessions, dir);
      if (!id) return;
      await client.session
        .prompt({ path: { id }, body: { noReply: true, parts: [{ type: "text", text: line }] } })
        .catch(() => {});
    } catch {
      /* session list/prompt unavailable — the toast already fired */
    }
  };
  await loop(dir, deliver);
}
