/**
 * coord.ts — opencode binding for the GENERIC, harness-independent coordination
 * surface (`AGENTS.md` "Agent identity & comment coordination", extends rule 9).
 *
 * The grammar itself is NOT reimplemented here (R3): it lives ONCE in the pure
 * shell script `marketplace/scripts/coord.sh`, which owns the closed verb set
 * (`CLAIM` `OWNING` `HANDING OVER` `TAKING OVER` `BLOCKS` `UNBLOCKS` `STATUS`
 * `RESOLVED`), the canonical TWO-LINE footer (`Agent:` FIRST, `Assisted-by:`
 * LAST — the order the pr-validator accepts), and the GitHub API call. This file
 * is the HARNESS BINDING: it registers two custom tools and auto-fills the parts
 * a session can resolve for itself so the human-in-the-loop re-arm and footer
 * bookkeeping disappear.
 *
 * PLUGIN CONTRACT (measured 2026-09-28, opencode v2.0.18; see
 * `.opencode/instructions.md` "opencode plugin contract"):
 *   - opencode >= 2.0 loads `default export { id, setup(ctx) }`; tools are
 *     registered with `ctx.tool.transform(draft => draft.add({ name, description,
 *     input, execute }))`, the tool `input` is a JSON Schema, and `execute`
 *     returns `{ content }` (a bare string and `{ output }` both FAIL the runtime
 *     with `"output" in s`, so `{ content }` is required).
 *   - opencode 1.x loads `{ id, server(input) }` returning a hooks object. 1.x
 *     tool registration needs the zod-based `tool()` helper, so this binding
 *     loads there but registers no tools and returns `{}` (the SAME honest path
 *     `pr-watch.ts` takes) — the scripts stay directly callable.
 *
 * TOOLS
 *   coord_comment  post ONE verb-labelled coordination comment (or claim) with
 *                  the canonical footer. Backed by `scripts/coord.sh`; the
 *                  session id is filled from the tool context, the identity
 *                  defaults from `.opencode/coord.conf` + `COORD_*` env.
 *   coord_watch    wait for a GitHub event on one or more PRs/issues using the
 *                  generic watcher `marketplace/scripts/gh_watch.sh` (one-shot,
 *                  bounded). The BACKGROUND continuous watch is `pr-watch.ts`'s
 *                  job — this is the explicit, session-invoked wait, so the two
 *                  never duplicate a loop.
 *
 * CONFIG (all optional; last wins: TOOL ARG > `COORD_*` ENV > `.opencode/coord.conf`)
 *   `.opencode/coord.conf` — `key=value` lines, `#` comments:
 *       agent=<work slug>        harness=OpenCode        model=<provider model>
 *   The `session` is always the live session (`context.sessionID`).
 *
 * SCRIPT LOCATION — the coordination logic itself is NOT reimplemented here; the
 * scripts are resolved as:
 *   - `COORD_SH`    (env override, an absolute path), else
 *   - `<dir>/marketplace/scripts/coord.sh`, else
 *   - `<dir>/../marketplace/scripts/coord.sh`   (the session-worktree layout)
 * and likewise for `GH_WATCH_SH` / `gh_watch.sh`. A repo WITHOUT a marketplace
 * submodule (e.g. `opencharly/.github` at `.worktrees/<slug>/dotgithub`) therefore
 * finds the sibling `.worktrees/<slug>/marketplace/scripts/…` automatically, with
 * no forked copy (R3); set `COORD_SH`/`GH_WATCH_SH` when it lives elsewhere.
 *
 * EXECUTION — NON-BLOCKING + ABORTABLE (R1 fix, measured 2026-09-28). The
 * executors MUST NOT block opencode's server event loop and MUST honour the
 * Session abort signal. The prior revision used the SYNCHRONOUS spawn helper, which:
 *   - blocks the server for the child's WHOLE lifetime — `coord_watch` runs the
 *     LONG-LIVED `gh_watch.sh` watcher, so a single call froze the server for up
 *     to the whole watch window and the supervisor RESTARTED it (measured: a
 *     `timeout: 3` call ran the full 20s stub and ignored the deadline; the
 *     server log showed a reload); and
 *   - ignores `context.signal`, so stopping the Session did not stop the watch.
 * Both executors now use the SAME async, abortable primitive `pr-watch.ts` already
 * uses (`Bun.spawn`): the child is spawned with `signal: toolCtx.signal`, its
 * stdout/stderr are captured asynchronously, and abort KILLS it. `timeout` on
 * `coord_watch` is enforced from the TOOL (the watcher's own `--timeout` bounds it
 * internally; a tool-side deadline additionally aborts the child), so an
 * interrupted session terminates the watcher.
 *
 * Defensive: a missing `coord.sh`/`gh_watch.sh` (marketplace pin too old), a
 * missing `gh`, or a missing required identity returns a clear message to the
 * caller — the plugin never throws into opencode startup.
 */
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { wakeLine } from "../lib/wake-line.ts";
// Re-exported so consumers/tests can use the shared helper through this module.
export { wakeLine };

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

/**
 * Resolve a script this plugin binds. Order: an explicit env override, then each
 * repo-relative candidate that EXISTS, else the first candidate (the caller then
 * reports it missing). The `../marketplace/...` candidate covers the session
 * worktree layout (`<umbrella>/.worktrees/<slug>/<repo>` — a repo without its own
 * marketplace submodule, e.g. dotgithub, still finds the sibling marketplace
 * worktree) with NO forked copy (R3).
 */
export function resolveScript(
  dir: string,
  envVal: string | undefined,
  rels: string[],
): string {
  if (envVal) return envVal;
  for (const rel of rels) {
    const p = join(dir, rel);
    if (existsSync(p)) return p;
  }
  return join(dir, rels[0]);
}

export function isTier(value: unknown): value is string {
  return typeof value === "string" && TIERS.includes(value);
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
 * Argv for a one-shot `gh_watch.sh` wait (no baked-in org/repo/session). The
 * returned array is the SCRIPT PLUS its arguments — the caller passes it to the
 * async spawn helper as `bash <argv>`. It does NOT include `"bash"` itself;
 * itself; including it produced `bash bash <script>` (a measured no-op).
 */
export function watchArgv(
  script: string,
  input: Record<string, any>,
): string[] {
  const argv = [script];
  if (input.events) argv.push("--events", String(input.events));
  if (input.interval !== undefined) argv.push("--interval", String(input.interval));
  if (input.stallmin !== undefined) argv.push("--stallmin", String(input.stallmin));
  if (input.workflow) argv.push("--workflow", String(input.workflow));
  if (input.timeout !== undefined) argv.push("--timeout", String(input.timeout));
  if (input.autoRearm) argv.push("--auto-rearm");
  for (const item of input.items ?? []) argv.push(String(item));
  return argv;
}

export interface SpawnResult {
  stdout: string;
  stderr: string;
  exitCode: number | null;
  timedOut: boolean;
  aborted: boolean;
}

/**
 * Run `bash <argv>` ASYNCHRONOUSLY and capture its output. NEVER a synchronous
 * spawn helper: the
 * caller may run a LONG-LIVED process (the watcher) and must not block opencode's
 * server event loop. `opts.signal` aborts (kills) the child — this is the tool
 * executor's `context.signal`, so stopping the Session terminates the operation.
 * `opts.deadlineMs` kills the child at a tool-side bound (the `coord_watch`
 * `timeout` backstop). Prefers the Bun runtime (opencode's own, the same primitive
 * `pr-watch.ts` uses) and falls back to Node's async `child_process` so the same
 * executor stays unit-testable under plain `node`.
 */
export async function spawnCapture(
  argv: string[],
  opts: { signal?: AbortSignal; deadlineMs?: number } = {},
): Promise<SpawnResult> {
  const bun = (globalThis as { Bun?: any }).Bun;
  let kill: () => void;
  let exited: Promise<number | null>;
  let stdoutP: Promise<string>;
  let stderrP: Promise<string>;
  let exitCodeOf: () => number | null;

  if (typeof bun?.spawn === "function") {
    let p: any;
    try {
      p = bun.spawn(["bash", ...argv], {
        stdout: "pipe",
        stderr: "pipe",
        signal: opts.signal,
      });
    } catch {
      // An already-aborted signal can make spawn throw synchronously.
      return { stdout: "", stderr: "", exitCode: null, timedOut: false, aborted: true };
    }
    stdoutP = new Response(p.stdout).text().catch(() => "");
    stderrP = new Response(p.stderr).text().catch(() => "");
    exited = p.exited.then((c: number | null) => (typeof c === "number" ? c : p.exitCode)).catch(() => p.exitCode);
    kill = () => {
      try {
        p.kill();
      } catch {
        /* already exited */
      }
    };
    exitCodeOf = () => p.exitCode;
  } else {
    const { spawn } = await import("node:child_process");
    // `detached` makes the child a process-group LEADER so we can signal the whole
    // group: `bash script.sh` may be waiting on a grandchild (e.g. `sleep`), and a
    // plain `child.kill()` signals only bash — the grandchild keeps the pipe open
    // and the close event waits for it. (Measured: without this, killing a `bash
    // script` that runs `sleep 30` returned after the full 30s.)
    let p: ReturnType<typeof spawn>;
    try {
      p = spawn("bash", argv, {
        stdio: ["ignore", "pipe", "pipe"],
        signal: opts.signal,
        detached: true,
      });
    } catch {
      return { stdout: "", stderr: "", exitCode: null, timedOut: false, aborted: true };
    }
    // An aborted signal makes spawn emit `error` (ABORT_ERR); without a listener that
    // is an unhandled 'error' event and crashes the process.
    p.on("error", () => {});
    const collect = (s: any) =>
      new Promise<string>((res) => {
        let b = "";
        s.on("data", (d: any) => (b += d.toString()));
        s.on("end", () => res(b));
        s.on("error", () => res(b));
      });
    stdoutP = collect(p.stdout);
    stderrP = collect(p.stderr);
    // Resolve on close OR error (an aborted spawn may never emit close).
    exited = new Promise<number | null>((res) => {
      p.on("close", (c) => res(c));
      p.on("error", () => res(p.exitCode ?? null));
    });
    kill = () => {
      const pid = p.pid;
      if (pid) {
        try {
          process.kill(-pid, "SIGTERM"); // the whole group
        } catch {
          /* group already gone */
        }
      }
      try {
        p.kill();
      } catch {
        /* already exited */
      }
    };
    exitCodeOf = () => p.exitCode;
  }

  let timedOut = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  if (opts.deadlineMs && opts.deadlineMs > 0) {
    timer = setTimeout(() => {
      timedOut = true;
      kill();
    }, opts.deadlineMs);
  }

  let exitCode: number | null = null;
  try {
    exitCode = await exited;
  } catch {
    exitCode = exitCodeOf();
  } finally {
    if (timer) clearTimeout(timer);
  }
  const [stdout, stderr] = await Promise.all([stdoutP, stderrP]);
  return {
    stdout,
    stderr,
    exitCode,
    timedOut,
    // `aborted` is true if the caller's signal was already aborted, or if the
    // runtime rejected the spawn because the signal aborted mid-flight.
    aborted: opts.signal ? opts.signal.aborted : false,
  };
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
    const commentScript = resolveScript(dir, process.env.COORD_SH, [
      "marketplace/scripts/coord.sh",
      "../marketplace/scripts/coord.sh",
    ]);
    const watchScript = resolveScript(dir, process.env.GH_WATCH_SH, [
      "marketplace/scripts/gh_watch.sh",
      "../marketplace/scripts/gh_watch.sh",
    ]);

    await ctx.tool.transform((draft: any) => {
      draft.add({
        name: "coord_comment",
        description:
          "Post ONE verb-labelled coordination comment (or claim) on a GitHub " +
          "issue/PR, with the canonical agent footer (`Agent:` first, " +
          "`Assisted-by:` last). Use it for CLAIM / OWNING / HANDING OVER / " +
          "TAKING OVER / BLOCKS / UNBLOCKS / STATUS / RESOLVED per AGENTS.md.",
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
            dryRun: { type: "boolean", description: "print the comment; do NOT post it" },
          },
          // `confidence` is intentionally optional: it is resolved from
          // .opencode/coord.conf / COORD_* env when the caller omits it.
          required: ["verb", "item"],
        },
        execute: async (input: Record<string, any>, toolCtx: any) => {
          if (!existsSync(commentScript)) {
            return {
              content: `coord_comment: coord.sh not found at ${commentScript} — sync the marketplace pin`,
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
          const argv = [commentScript, String(input.verb), String(input.item)];
          if (input.body) argv.push("--body", String(input.body));
          argv.push(
            "--agent", id.agent,
            "--session", id.session,
            "--harness", id.harness,
            "--model", id.model,
            "--confidence", id.confidence,
          );
          if (input.assign) argv.push("--assign");
          if (input.dryRun) argv.push("--dry-run");
          const r = await spawnCapture(argv, { signal: toolCtx?.signal });
          const out = `${r.stdout}${r.stderr}`.trim();
          return { content: out || `coord_comment: exit ${r.exitCode}` };
        },
      });

      draft.add({
        name: "coord_watch",
        description:
          "Wait (one-shot, bounded) for a GitHub event on one or more PRs/issues " +
          "using the generic watcher. Returns the wake line, or a TIMEOUT notice. " +
          "For a continuous background watch use the pr-watch plugin instead.",
        input: {
          type: "object",
          properties: {
            items: {
              type: "array",
              items: { type: "string" },
              description: "owner/repo#num items to watch",
            },
            events: { type: "string", description: "comma list (default: merged,closed,stall)" },
            interval: { type: "number", description: "poll cadence, seconds" },
            stallmin: { type: "number", description: "stall window, minutes" },
            workflow: { type: "string", description: "validator run name" },
            timeout: { type: "number", description: "overall deadline, seconds (0 = none)" },
            autoRearm: { type: "boolean", description: "keep the watch alive across fires" },
          },
          required: ["items"],
        },
        execute: async (input: Record<string, any>, toolCtx: any) => {
          if (!existsSync(watchScript)) {
            return {
              content: `coord_watch: gh_watch.sh not found at ${watchScript} — sync the marketplace pin`,
            };
          }
          if (!Array.isArray(input.items) || input.items.length === 0) {
            return { content: "coord_watch: pass at least one item (owner/repo#num)" };
          }
          // The tool-side deadline (seconds → ms). The watcher also bounds itself
          // with `--timeout`; this is the backstop that kills the child if it
          // overruns. 0/undefined = no tool-side deadline (rely on the watcher).
          const deadlineMs =
            typeof input.timeout === "number" && input.timeout > 0 ? input.timeout * 1000 : undefined;
          const r = await spawnCapture(watchArgv(watchScript, input), {
            signal: toolCtx?.signal,
            deadlineMs,
          });
          if (r.aborted) return { content: "coord_watch: aborted (session interrupted)" };
          const line = wakeLine(r.stdout);
          if (line) return { content: line };
          // No event: distinguish a timeout from a real watcher error.
          const err = r.stderr.trim();
          if (r.timedOut || r.exitCode === 4 || /^TIMEOUT/m.test(r.stdout)) {
            return { content: `TIMEOUT: no event within ${input.timeout}s` };
          }
          return { content: err || `coord_watch: watcher exited ${r.exitCode} with no event` };
        },
      });
    });
  },
  // opencode 1.x function form: loads, but tool registration needs zod → no-op.
  async server(_input: any) {
    return {};
  },
};
