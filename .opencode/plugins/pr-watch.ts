/**
 * pr-watch.ts — opencode delivery binding for the GENERIC, harness-independent PR watcher.
 *
 * The watcher itself is `marketplace/scripts/gh_watch.sh` (pure shell, no opencode
 * imports). This file is the HARNESS BINDING: it starts a DETACHED re-arm loop that
 * runs the watcher with `Bun.spawn` and, on each wake, delivers the alert with
 * opencode's OWN in-process primitives — never an `opencode run` subprocess (which
 * starts a separate headless run, can race the live session, and interrupts the
 * in-flight turn).
 *
 * DELIVERY — measured 2026-09-28 against the REAL v2.0.18 binary. The V2
 * `setup(ctx)` context does NOT carry `client` (only opencode 1.x's `server(input)`
 * does). The V2 "inject context without starting a turn" primitive is the Session
 * domain:
 *
 *     await ctx.session.synthetic({ sessionID, text: alert });
 *
 * `session.synthetic` enqueues a synthetic message; its default `delivery` is
 * "steer", which ADDS the alert to the running session rather than starting a new
 * turn — the same interruption-safe intent as 1.x's `client.session.prompt({
 * noReply: true })`. The session id is not known at setup time and `session.list`
 * does not exist on V2, so it is CAPTURED from the first tool call
 * (`ctx.tool.hook("execute.before", e => e.sessionID)`) or the first prompt
 * (`ctx.session.hook("prompt", e => e.sessionID)`) — by the time a watcher fires the
 * running session has done both. If no id is captured yet, the wake is a logged
 * warning (never a silent drop).
 *
 * The earlier revision called `client.tui.showToast` / `client.session.list` on the
 * V2 path; `client` is `undefined` there, so the V2 delivery silently no-opped and
 * the plugin warned "SDK client unavailable". That was a MEASURED defect (R1); the
 * V2 path now uses `ctx.session.synthetic`. The V1 `server(input)` path keeps the
 * documented 1.x SDK-client shape.
 *
 * Config: one item per line in `.opencode/pr-watch.items` (blank lines and `#`
 * comments ignored), e.g. `acme/widget#12`. Absent or comment-only → the plugin
 * watches nothing (inert). opencode loads plugins ONCE at startup — RESTART after
 * editing. `setup()` starts the loop detached and returns immediately.
 *
 * Defensive: if the `Bun` runtime, the session domain, or the watcher script is
 * unavailable, the plugin logs a warning and no-ops; opencode keeps running.
 */
import { wakeLine } from "../lib/wake-line.ts";
import { resolveScript } from "./coord.ts";

// The ONE shared "last non-empty stdout line" helper (R3) — the same module
// `coord.ts` imports. Re-exported under the historical name this plugin's own
// check asserts.
export const lastWakeLine = wakeLine;

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
  // opencode >= 2.0 definition form: the context carries `session` + `location`
  // (NOT a `client` — see the header).
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

// --- shared watcher loop ----------------------------------------------------

async function loop(dir: string, deliver: (line: string) => Promise<void>) {
  if (typeof Bun === "undefined") {
    warn("Bun runtime unavailable — watcher disabled");
    return;
  }

  let items: string[] = [];
  try {
    items = parseItems(await Bun.file(`${dir}/.opencode/pr-watch.items`).text());
  } catch {
    return; // no config → watch nothing (inert by default)
  }
  if (items.length === 0) return;

  // The watcher script is resolved exactly like coord.ts resolves its scripts
  // (env override → <dir>/marketplace/scripts → <dir>/../marketplace/scripts), so a
  // repo without a marketplace submodule still finds the sibling worktree's copy.
  const script = resolveScript(dir, process.env.GH_WATCH_SH, [
    "marketplace/scripts/gh_watch.sh",
    "../marketplace/scripts/gh_watch.sh",
  ]);
  if (!(await Bun.file(script).exists())) {
    warn(`watcher script missing at ${script} — sync the marketplace pin`);
    return;
  }

  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

  const once = async () => {
    const proc = Bun.spawn(["bash", script, "--events", "comment,merged,closed", ...items], {
      cwd: dir,
      stdout: "pipe",
      stderr: "ignore",
    });
    const out = (await new Response(proc.stdout).text()).trim();
    await proc.exited;
    return out;
  };

  // re-arm loop, detached so the plugin's setup/server returns at once
  void (async () => {
    for (;;) {
      try {
        const line = lastWakeLine(await once());
        if (line) await deliver(line);
      } catch {
        /* transient (gh/network) — skip this wake, keep watching */
      }
      await sleep(30000);
    }
  })();
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
