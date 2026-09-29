/**
 * agent-progress.ts — the OpenCode-native AGENT PROGRESS monitor, implemented in
 * PURE TypeScript.
 *
 * WHY. An orchestrator monitors subagents badly: turn counts, "idle", vibes. The REAL
 * signal is the TRANSCRIPT — what the agent is actually doing. A "message" count is an
 * ASSISTANT-TURN count (`session_message` rows with `type='assistant'`), NOT progress;
 * counting turns penalises an agent for WORKING. The monitoring model is the one the
 * umbrella `AGENTS.md` already mandates:
 *
 *   - artifact — a CHANGED commit/PR/merge/tag/measured output → progress;
 *   - cadence  — steady tool calls (`shell`/`read`/`write`/`edit`) → working, give room;
 *   - loop     — the same failing action repeated, no artifact change → the pathology;
 *   - idle     — no turns past the window AND no artifact.
 *
 * Rotate/take over ONLY on: >2 orchestrator re-briefs of the same task; idle-past-window
 * with no artifact; or a loop. Never on turn count.
 *
 * DATA SOURCE (VERIFIED 2026-09-29, opencode v2.0.18). The opencode store is a SQLite
 * database at `$XDG_DATA_HOME/opencode/opencode.db` (`~/.local/share/opencode/opencode.db`
 * when `XDG_DATA_HOME` is unset; `OPENCODE_DB` overrides, for tests). There is NO
 * `session` table — the live schema is `session_v2` (session rows) + `session_message`
 * (transcript rows, `type` ∈ assistant/user/system/synthetic/idle/…). An assistant row's
 * `data` is JSON: `{ time, agent, model, finish, tokens, …, content: [ {type:"reasoning"|
 * "text"|"tool", …} ] }`. It is read READ-ONLY through `bun:sqlite`
 * (`new Database(path, { readonly: true })`) under the shipped opencode binary, falling
 * back to `node:sqlite` (`new DatabaseSync(path, { readOnly: true })`) under plain node —
 * never a write, never a mock.
 *
 * PURE TYPESCRIPT — no shell delegation, no `marketplace` submodule pin (the same
 * operator directive the coord/pr-watch plugins follow; see opencharly/opencharly#302).
 * The plugin loads its code AND its data path from the SAME ref, even when the
 * `marketplace` gitlink lags.
 *
 * TOOLS
 *   agent_progress  report, per session, the turns/span/age, the tool mix, the LAST
 *                   action (text/reasoning snippet + last tool + its input), the
 *                   artifact hints, and a WORKING / IDLE / LOOP / DONE verdict. Async,
 *                   `context.signal`-aware, never blocking, and it fails CLEARLY (it
 *                   never fabricates a verdict it cannot ground in the transcript).
 *   agent_control   the CONTROL half (the new part): `list` (enumerate sessions with the
 *                   monitor's verdict), `interrupt` (stop a RUNNING session without
 *                   deleting it — `ctx.session.interrupt({sessionID, continue:false})`),
 *                   `delete` (`opencode session delete <id>` — the session AND its child
 *                   sessions), `wait` (bounded block until idle — `ctx.session.wait`), and
 *                   `confirm_stopped` (re-read the transcript and ASSERT no new turns —
 *                   the "CONFIRM it stopped" rule in AGENTS.md). SAFETY: `interrupt` /
 *                   `delete` require an EXPLICIT `session` id (never a wildcard) and the
 *                   tool returns what it stopped, so a session another slug owns is never
 *                   silently killed.
 *
 * PLUGIN CONTRACT (measured, opencode v2.0.18; see `.opencode/instructions.md`):
 *   - opencode >= 2.0 loads `default export { id, setup(ctx) }`; tools register via
 *     `ctx.tool.transform(draft => draft.add({ name, description, input, execute }))`,
 *     `input` is a JSON Schema, and `execute` returns `{ content }`.
 *   - opencode 1.x loads `{ id, server(input) }` returning a hooks object. This binding
 *     therefore exports BOTH entry points (sharing one implementation) so it loads under
 *     either generation; 1.x tool registration needs the zod helper, so `server` returns
 *     `{}` — the tool is simply not registered there.
 */

import { execFile } from "node:child_process";
import { join } from "node:path";

/** The plugin id (must be a non-empty string; the gate asserts both entry points). */
export const PLUGIN_ID = "agent-progress";

/** Default idle window (minutes): no assistant turn within it ⇒ the stall candidate. */
export const DEFAULT_WINDOW_MIN = 15;

/** Default cap on sessions listed by `all`. */
export const DEFAULT_LIMIT = 10;

/** Default look-back (minutes) for `all` — sessions with no activity since are omitted. */
export const DEFAULT_SINCE_MIN = 240;

/** Default cap on transcript rows fetched per session (the tail is what matters). */
export const MAX_MSGS_PER_SESSION = 600;

/** The closed `agent_control` action set. */
export const CONTROL_ACTIONS = ["list", "interrupt", "delete", "wait", "confirm_stopped"];

/** `wait` deadline (seconds) — a bounded block; 0 would be an unbounded wait (refused). */
export const DEFAULT_WAIT_TIMEOUT_S = 600;

/** A loop is `LOOP_REPEATS` identical (tool+input) calls within the last `LOOP_TAIL`. */
export const LOOP_REPEATS = 4;
export const LOOP_TAIL = 6;

/** How many trailing assistant turns count as "the session tail" for artifact/loop. */
export const ARTIFACT_TAIL = 4;

/** The closed verdict set. */
export const VERDICTS = ["WORKING", "IDLE", "LOOP", "DONE"];

/** The tool names whose input is a single "what am I doing" key (the tool mix). */
export const KNOWN_TOOLS = [
  "shell",
  "bash",
  "read",
  "write",
  "edit",
  "grep",
  "glob",
  "skill",
  "execute",
  "subagent",
  "question",
  "webfetch",
  "websearch",
];

/**
 * Wire KNOWN_TOOLS into the monitor's report: surface any tool call OUTSIDE the known set,
 * so a new/unknown tool is visible rather than silently folded into the mix. (This is the
 * one live use of the constant — the mix itself is built from the transcript's real names.)
 */
export function unknownTools(mix: Record<string, number>): string[] {
  return Object.keys(mix).filter((name) => !KNOWN_TOOLS.includes(name));
}

/**
 * Resolve the opencode database path. `OPENCODE_DB` wins (an explicit override);
 * otherwise the XDG data dir (`$XDG_DATA_HOME` or `~/.local/share`), then `/opencode/opencode.db`.
 */
export function databasePath(env: Record<string, string | undefined> = process.env): string {
  if (env.OPENCODE_DB && env.OPENCODE_DB.trim() !== "") return env.OPENCODE_DB;
  const xdg = env.XDG_DATA_HOME;
  const base =
    xdg && xdg.trim() !== "" ? xdg : join(env.HOME || env.USERPROFILE || ".", ".local", "share");
  return join(base, "opencode", "opencode.db");
}

/** Render a millisecond duration compactly (`45s`, `12m`, `2h 5m`, `3d`). */
export function formatDuration(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) return "?";
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 48) return `${h}h ${m % 60}m`;
  return `${Math.floor(h / 24)}d ${h % 24}h`;
}

/**
 * Canonical "what am I doing" key for a tool call input — the thing a LOOP repeats.
 * A `shell` command collapses whitespace (so a re-run of the same command matches); a
 * path tool keys on its path; anything else is a bounded JSON render.
 */
export function normalizeInput(name: string, input: unknown): string {
  const o = (input && typeof input === "object" ? input : {}) as Record<string, unknown>;
  const str = (k: string): string | undefined => (typeof o[k] === "string" ? (o[k] as string) : undefined);
  switch (name) {
    case "shell":
    case "bash":
      return (str("command") ?? "").replace(/\s+/g, " ").trim().slice(0, 300);
    case "read":
    case "write":
    case "edit":
      return str("path") ?? str("filePath") ?? str("file") ?? "";
    case "grep":
    case "glob":
      return [str("pattern") ?? str("query"), str("path") ?? str("include")].filter(Boolean).join(" ");
    case "webfetch":
      return str("url") ?? "";
    case "websearch":
      return str("query") ?? "";
    case "skill":
      return str("name") ?? str("id") ?? "";
    case "subagent":
    case "task":
      return str("description") ?? str("prompt") ?? "";
    default:
      try {
        return JSON.stringify(o).slice(0, 300);
      } catch {
        return "";
      }
  }
}

/** One artifact pattern: a kind label and the regex that finds it. */
export const ARTIFACT_PATTERNS: Array<[string, RegExp]> = [
  ["pr", /\b([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)#(\d+)\b/g],
  ["pr-url", /github\.com\/([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)\/(?:pull|issues)\/(\d+)/g],
  ["pr-merge", /\bgh\s+pr\s+merge\b/g],
  ["merged", /\bmerged\b/gi],
  ["tag", /\bv?(\d{4})\.(\d{3})\.(\d{4})\b/g],
  ["tag-sdk", /\bv0\.(\d{7})\.(\d+)\b/g],
  ["pushed", /\bpushed\b/gi],
];

/**
 * Surface artifact HINTS (a landed commit/PR/merge/tag/push) by grepping text. This is a
 * HINT — a mention ("merged: none") also matches — so it is surfaced for the orchestrator
 * to read, never asserted as proof on its own. Deduped, ordered, capped.
 */
export function extractArtifacts(text: string, cap = 12): string[] {
  if (!text) return [];
  const found: Array<{ at: number; label: string }> = [];
  for (const [kind, re] of ARTIFACT_PATTERNS) {
    re.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = re.exec(text)) !== null) {
      let label: string;
      if (kind === "pr") label = `${m[1]}#${m[2]}`;
      else if (kind === "pr-url") label = `${m[1]}#${m[2]}`;
      else if (kind === "tag") label = `v${m[1]}.${m[2]}.${m[3]}`;
      else if (kind === "tag-sdk") label = `v0.${m[1]}.${m[2]}`;
      else if (kind === "pr-merge") label = "gh pr merge";
      else label = kind;
      found.push({ at: m.index, label });
      if (m.index === re.lastIndex) re.lastIndex += 1; // zero-length guard
    }
  }
  // Dedupe by label, keep first-seen order.
  const seen = new Set<string>();
  const out: string[] = [];
  for (const f of found.sort((a, b) => a.at - b.at)) {
    if (seen.has(f.label)) continue;
    seen.add(f.label);
    out.push(f.label);
    if (out.length >= cap) break;
  }
  return out;
}

/** A tool call as the monitor sees it. */
export interface ToolCall {
  name: string;
  key: string;
  status: string;
  turn: number;
  time: number;
}

/**
 * Detect a LOOP: at least `repeats` IDENTICAL (tool + normalized input) calls inside the
 * trailing `tail` window. A loop is the SAME action repeated with no artifact — so the
 * caller folds in the artifact signal; this function is the pure repetition detector.
 */
export function detectLoop(
  toolCalls: ToolCall[],
  opts: { repeats?: number; tail?: number } = {},
): { isLoop: boolean; count: number; tool: string; key: string; errors: number } {
  const repeats = opts.repeats ?? LOOP_REPEATS;
  const tail = opts.tail ?? LOOP_TAIL;
  const none = { isLoop: false, count: 0, tool: "", key: "", errors: 0 };
  if (toolCalls.length < repeats) return none;
  const recent = toolCalls.slice(-tail);
  const counts = new Map<string, number>();
  for (const t of recent) {
    const k = `${t.name}\u0000${t.key}`;
    counts.set(k, (counts.get(k) ?? 0) + 1);
  }
  let best: { k: string; c: number } | null = null;
  for (const [k, c] of counts) if (!best || c > best.c) best = { k, c };
  if (!best || best.c < repeats) return none;
  const [tool, key] = best.k.split("\u0000");
  const errors = recent.filter(
    (t) => `${t.name}\u0000${t.key}` === best!.k && t.status === "error",
  ).length;
  return { isLoop: true, count: best.c, tool, key, errors };
}

/** Parse a `session_message.data` payload (tolerating a malformed row). */
export function parseData(data: unknown): Record<string, any> {
  if (data && typeof data === "object") return data as Record<string, any>;
  if (typeof data !== "string") return {};
  try {
    const parsed = JSON.parse(data);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

/**
 * Render a `session_v2.model` value (`{"id":"…","providerID":"…","variant":"…"}` JSON, or
 * a plain string) as `provider/model`. Unknown shapes degrade to the raw string, never a throw.
 */
export function parseModel(model: unknown): string {
  if (typeof model !== "string" || model.trim() === "") return "";
  if (!model.trim().startsWith("{")) return model;
  try {
    const o = JSON.parse(model);
    const id = typeof o?.id === "string" ? o.id : "";
    const provider = typeof o?.providerID === "string" ? o.providerID : "";
    const rendered = [provider, id].filter(Boolean).join("/");
    return rendered || model;
  } catch {
    return model;
  }
}

/** The features the classifier keys on — everything the report shows, already derived. */
export interface Analysis {
  sessionID: string;
  slug: string;
  title: string;
  parentID: string | null;
  agent: string;
  model: string;
  idleOutcome: string;
  turns: number;
  userTurns: number;
  repeatBriefs: string[];
  spanMs: number | null;
  lastTurnAgeMs: number | null;
  lastEventAgeMs: number | null;
  toolMix: Record<string, number>;
  toolCalls: number;
  lastText: { kind: string; text: string } | null;
  lastTool: { name: string; key: string; status: string } | null;
  artifacts: string[];
  recentArtifacts: string[];
  loop: { isLoop: boolean; count: number; tool: string; key: string; errors: number };
  pending: boolean;
  finalReport: boolean;
  truncated: boolean;
  empty: boolean;
  verdict: string;
  reasons: string[];
}

/** The compact per-session view of a `session_v2` row. */
export interface SessionRow {
  id: string;
  slug?: string | null;
  title?: string | null;
  parent_id?: string | null;
  agent?: string | null;
  model?: string | null;
  idle_outcome?: string | null;
  time_updated?: number | null;
}

/**
 * Analyze ONE session from its parsed transcript. Pure and deterministic (`now` is passed
 * in), so the classifier is unit-testable without opencode or a database.
 */
export function analyzeSession(
  session: SessionRow,
  messages: Array<{ seq?: number; type?: string; time_created: number; data: unknown }>,
  opts: { now: number; windowMin?: number } = { now: Date.now() },
): Analysis {
  const windowMin = opts.windowMin ?? DEFAULT_WINDOW_MIN;
  const texts: string[] = [];
  const toolCalls: ToolCall[] = [];
  const toolMix: Record<string, number> = {};
  const userTexts: string[] = [];
  let lastTurnAt: number | null = null;
  let firstTurnAt: number | null = null;
  let lastText: { kind: string; text: string } | null = null;
  let lastTool: { name: string; key: string; status: string } | null = null;
  let pending = false;
  let finalReport = false;
  let truncated = false;

  // Only assistant rows carry turns/tool calls; every row contributes to the last-event.
  const assistant = messages.filter((m) => m.type === "assistant");
  let lastEventAt: number | null = null;
  for (const m of messages) {
    if (lastEventAt === null || m.time_created > lastEventAt) lastEventAt = m.time_created;
  }

  const perTurnTexts: string[][] = [];
  let lastFinish = "";
  let anyRunning = false;
  assistant.forEach((m: any, i: number) => {
    const d = parseData(m.data);
    if (lastTurnAt === null || m.time_created > lastTurnAt) lastTurnAt = m.time_created;
    if (firstTurnAt === null || m.time_created < firstTurnAt) firstTurnAt = m.time_created;
    const content = Array.isArray(d.content) ? d.content : [];
    const turnTexts: string[] = [];
    let turnRunning = false;
    for (const part of content) {
      if (!part || typeof part !== "object") continue;
      if (part.type === "text" || part.type === "reasoning") {
        const t = typeof part.text === "string" ? part.text : "";
        if (t.trim() !== "") {
          texts.push(t);
          turnTexts.push(t);
          lastText = { kind: part.type, text: t };
        }
      } else if (part.type === "tool") {
        const name = typeof part.name === "string" ? part.name : "unknown";
        const status = typeof part.state?.status === "string" ? part.state.status : "unknown";
        const key = normalizeInput(name, part.state?.input);
        toolMix[name] = (toolMix[name] ?? 0) + 1;
        toolCalls.push({ name, key, status, turn: i, time: m.time_created });
        lastTool = { name, key, status };
        if (status === "running") turnRunning = true;
        // A shell tool's INPUT (e.g. `gh pr merge …`) is an artifact surface too.
        turnTexts.push(`${name} ${key}`);
      }
    }
    perTurnTexts[i] = turnTexts;
    lastFinish = typeof d.finish === "string" ? d.finish : "";
    if (turnRunning) anyRunning = true;
    // `pending` is a property of the LAST turn ONLY: an older turn's `tool-calls`
    // continued into the next turn, so it does not mean the session is mid-action now.
    // A tool part STUCK in `running` anywhere is still an action in flight.
    pending = lastFinish === "tool-calls" || anyRunning;
    if (lastFinish === "stop" && turnTexts.length > 0) {
      finalReport = i === assistant.length - 1;
    }
  });

  if (messages.length >= MAX_MSGS_PER_SESSION) truncated = true;

  // User turns + re-briefs (>2 orchestrator re-briefs of the SAME task is a rotate trigger).
  for (const m of messages) {
    if (m.type !== "user") continue;
    const d = parseData(m.data);
    if (typeof d.text === "string" && d.text.trim() !== "") userTexts.push(d.text);
  }
  const briefCounts = new Map<string, number>();
  for (const t of userTexts) {
    const k = t.replace(/\s+/g, " ").trim().slice(0, 120);
    briefCounts.set(k, (briefCounts.get(k) ?? 0) + 1);
  }
  const repeatBriefs = [...briefCounts.entries()].filter(([, c]) => c > 1).map(([k, c]) => `${c}× ${k.slice(0, 60)}`);

  const allText = texts.join("\n");
  const tailFrom = Math.max(0, assistant.length - ARTIFACT_TAIL);
  const tailText = assistant
    .slice(tailFrom)
    .flatMap((_: any, i: number) => perTurnTexts[tailFrom + i] ?? [])
    .join("\n");
  const recentArtifacts = extractArtifacts(tailText);
  // Surface the RECENT artifacts (the tail is what says "landed just now"); fall back to
  // the whole-transcript list for a short session so a landed artifact is never hidden.
  const artifacts = recentArtifacts.length ? recentArtifacts : extractArtifacts(allText);

  const loop = detectLoop(toolCalls);

  const now = opts.now;
  const analysis: Analysis = {
    sessionID: session.id,
    slug: session.slug ?? "",
    title: session.title ?? "",
    parentID: session.parent_id ?? null,
    agent: session.agent ?? "",
    model: parseModel(session.model),
    idleOutcome: session.idle_outcome ?? "",
    turns: assistant.length,
    userTurns: userTexts.length,
    repeatBriefs,
    spanMs: firstTurnAt !== null && lastTurnAt !== null ? lastTurnAt - firstTurnAt : null,
    lastTurnAgeMs: lastTurnAt === null ? null : Math.max(0, now - lastTurnAt),
    lastEventAgeMs: lastEventAt === null ? null : Math.max(0, now - lastEventAt),
    toolMix,
    toolCalls: toolCalls.length,
    lastText,
    lastTool,
    artifacts,
    recentArtifacts,
    loop,
    pending,
    finalReport,
    truncated,
    empty: assistant.length === 0,
    verdict: "WORKING",
    reasons: [],
  };
  const { verdict, reasons } = classify(analysis, windowMin);
  analysis.verdict = verdict;
  analysis.reasons = reasons;
  return analysis;
}

/**
 * The STABLE terminal state of a STALE session (no turn and no input past the window):
 * `DONE` when the last turn was a final report (`finish=stop`) with no action in flight,
 * `IDLE` otherwise. Returns `null` while a turn is recent OR input is fresh — the caller
 * then reports the session as working. Used by BOTH the classifier and the report, so
 * the VERDICT line can never disagree with the LAST line it summarizes.
 */
export function reportStatus(a: Analysis, windowMin = DEFAULT_WINDOW_MIN): "DONE" | "IDLE" | null {
  const windowMs = windowMin * 60_000;
  const turnFresh = a.lastTurnAgeMs !== null && a.lastTurnAgeMs <= windowMs;
  const inputFresh = a.lastEventAgeMs !== null && a.lastEventAgeMs <= windowMs;
  if (turnFresh || inputFresh) return null; // working / just dispatched
  if (a.empty) return "IDLE";
  if (a.finalReport && !a.pending) return "DONE";
  return "IDLE";
}

/**
 * The classifier. `WORKING` (recent turns + tool cadence) / `IDLE` (no turns past the
 * window and no artifact) / `LOOP` (the same tool+input repeated, no artifact) / `DONE`
 * (a final report, no pending action). A turn-count-heavy-but-recent transcript is
 * WORKING — never stalled — because a turn is NOT a progress signal.
 */
export function classify(a: Analysis, windowMin = DEFAULT_WINDOW_MIN): { verdict: string; reasons: string[] } {
  const reasons: string[] = [];
  const windowMs = windowMin * 60_000;
  const turnAge = a.lastTurnAgeMs;
  const eventAge = a.lastEventAgeMs;
  const fresh = (age: number | null) => age !== null && age <= windowMs;
  const cadence = a.toolCalls >= 2;
  const recentArtifact = a.recentArtifacts.length > 0;
  const loop = a.loop.isLoop && !recentArtifact;

  // Empty session: no assistant turn yet. Fresh input ⇒ just dispatched (WORKING);
  // nothing recent ⇒ IDLE.
  if (a.empty) {
    if (fresh(eventAge)) {
      reasons.push(`no assistant turn yet; last event ${formatDuration(eventAge!)} ago`);
      return { verdict: "WORKING", reasons };
    }
    reasons.push("no assistant turns");
    return { verdict: "IDLE", reasons };
  }

  // Recent activity: the agent is working unless it is visibly looping.
  const turnFresh = fresh(turnAge);
  const hasNewInput = !fresh(turnAge) && fresh(eventAge); // a fresh user/system message, no turn yet
  if (turnFresh || hasNewInput) {
    if (loop) {
      reasons.push(
        `loop: ${a.loop.count}× \`${a.loop.tool}\` ${a.loop.key.slice(0, 60)} with no artifact in the tail`,
      );
      return { verdict: "LOOP", reasons };
    }
    reasons.push(
      turnFresh
        ? `recent turns (${formatDuration(turnAge!)} < ${windowMin}m)`
        : `fresh input ${formatDuration(eventAge!)} ago, no turn yet`,
    );
    if (cadence) reasons.push(`tool cadence (${a.toolCalls} calls: ${topTools(a.toolMix)})`);
    return { verdict: "WORKING", reasons };
  }

  // Stale: quiet past the window (no assistant turn AND no fresh input).
  const staleFor = turnAge!;
  const status = reportStatus(a, windowMin) ?? "IDLE";
  if (status === "DONE") {
    reasons.push(`final report (finish=stop, no pending action), quiet ${formatDuration(staleFor)}`);
    return { verdict: "DONE", reasons };
  }
  if (loop) {
    reasons.push(`stale loop: ${a.loop.count}× \`${a.loop.tool}\` ${a.loop.key.slice(0, 60)}`);
    return { verdict: "LOOP", reasons };
  }
  reasons.push(`no turns for ${formatDuration(staleFor)} > ${windowMin}m and no artifact`);
  if (a.idleOutcome) reasons.push(`idle_outcome=${a.idleOutcome}`);
  if (a.repeatBriefs.length > 0) reasons.push(`re-briefs: ${a.repeatBriefs.join("; ")}`);
  return { verdict: "IDLE", reasons };
}

/** `shell×73 read×12` — the top tools in the mix, bounded. */
export function topTools(mix: Record<string, number>, n = 4): string {
  return Object.entries(mix)
    .sort((a, b) => b[1] - a[1])
    .slice(0, n)
    .map(([k, v]) => `${k}×${v}`)
    .join(" ");
}

/** Clip a snippet to one readable line. */
export function snippet(text: string, max = 160): string {
  const one = text.replace(/\s+/g, " ").trim();
  return one.length > max ? `${one.slice(0, max - 1)}…` : one;
}

/** Render one session's compact report block. */
export function formatAnalysis(a: Analysis): string {
  const lines: string[] = [];
  const child = a.parentID ? "⤷subagent " : "";
  const title = a.title ? `"${snippet(a.title, 60)}"` : a.slug ? `"${a.slug}"` : "";
  lines.push(`${a.sessionID}  ${child}${title}`.trimEnd());
  const meta = [
    a.agent ? `agent ${a.agent}` : "",
    a.model ? `model ${a.model}` : "",
    a.idleOutcome ? `idle_outcome=${a.idleOutcome}` : "",
  ].filter(Boolean);
  if (meta.length) lines.push(`  ${meta.join(" · ")}`);
  const timing = [
    `turns ${a.turns}`,
    `span ${a.spanMs === null ? "—" : formatDuration(a.spanMs)}`,
    `last-turn ${a.lastTurnAgeMs === null ? "—" : formatDuration(a.lastTurnAgeMs)} ago`,
    `last-event ${a.lastEventAgeMs === null ? "—" : formatDuration(a.lastEventAgeMs)} ago`,
    a.truncated ? "(tail only)" : "",
  ].filter(Boolean);
  lines.push(`  ${timing.join(" · ")}`);
  if (a.toolCalls > 0) lines.push(`  tools  ${topTools(a.toolMix, 6)}`);
  {
    const unknown = unknownTools(a.toolMix);
    if (unknown.length) lines.push(`  tools+ ${unknown.join(" ")}`);
  }
  if (a.loop.isLoop) {
    lines.push(`  loop   ${a.loop.count}× \`${a.loop.tool}\` ${snippet(a.loop.key, 80)}${a.loop.errors ? ` (${a.loop.errors} errored)` : ""}`);
  }
  const last: string[] = [];
  if (a.lastText) last.push(`${a.lastText.kind}: "${snippet(a.lastText.text)}"`);
  if (a.lastTool) last.push(`\`${a.lastTool.name}\`(${a.lastTool.status}): ${snippet(a.lastTool.key, 100)}`);
  if (last.length) lines.push(`  last   ${last.join("  |  ")}`);
  if (a.artifacts.length) lines.push(`  artifact  ${a.artifacts.slice(0, 8).join(" · ")}${a.artifacts.length > 8 ? ` (+${a.artifacts.length - 8})` : ""}`);
  if (a.repeatBriefs.length) lines.push(`  re-briefs  ${a.repeatBriefs.join("; ")}`);
  lines.push(`  VERDICT  ${a.verdict} — ${a.reasons.join("; ")}`);
  return lines.join("\n");
}

/** Render the whole report (header + one block per session). */
export function formatReport(analyses: Analysis[], meta: { db: string; driver: string; windowMin: number; note?: string }): string {
  const head = `agent_progress  window ${meta.windowMin}m  db ${meta.db}  driver ${meta.driver}`;
  if (analyses.length === 0) {
    return `${head}\n(no sessions to report${meta.note ? ` — ${meta.note}` : ""})`;
  }
  return [head, "─".repeat(70), ...analyses.map(formatAnalysis), ""].join("\n");
}

/**
 * A minimal read-only SQLite adapter. `bun:sqlite` first (the shipped opencode runtime),
 * `node:sqlite` second (plain node / the gate). Read-only is enforced by the OPEN FLAG,
 * never by trusting the SQL — a write through this handle fails at the driver.
 */
export interface SqliteHandle {
  driver: string;
  all(sql: string, ...params: unknown[]): any[];
  close(): void;
}

export async function openReadonly(dbPath: string): Promise<SqliteHandle> {
  // Resolve a DRIVER before opening, so a failed open reports the open error, not a
  // misleading "no driver".
  let bun: any = null;
  try {
    bun = await import(/* @vite-ignore */ "bun:sqlite");
  } catch {
    bun = null;
  }
  if (bun && typeof bun.Database === "function") {
    const db = new bun.Database(dbPath, { readonly: true });
    return {
      driver: "bun:sqlite",
      all: (sql, ...params) => db.query(sql).all(...params),
      close: () => db.close(),
    };
  }
  const node: any = await import(/* @vite-ignore */ "node:sqlite");
  const db = new node.DatabaseSync(dbPath, { readOnly: true });
  return {
    driver: "node:sqlite",
    all: (sql, ...params) => db.prepare(sql).all(...params),
    close: () => db.close(),
  };
}

/** SQL constants (named, so the read-only contract is auditable). */
export const SQL = {
  oneSession:
    "SELECT id, slug, title, parent_id, agent, model, idle_outcome, time_updated FROM session_v2 WHERE id = ?",
  recentSessions:
    "SELECT id, slug, title, parent_id, agent, model, idle_outcome, time_updated FROM session_v2 WHERE time_updated >= ? ORDER BY time_updated DESC LIMIT ?",
  counts:
    "SELECT COUNT(*) AS turns, MIN(time_created) AS first, MAX(time_created) AS last FROM session_message WHERE session_id = ? AND type = 'assistant'",
  tail:
    "SELECT seq, type, time_created, data FROM session_message WHERE session_id = ? ORDER BY seq DESC LIMIT ?",
};

/** SQL for the CONTROL half (`list`/`confirm_stopped`) — read-only, like `SQL`. */
export const CONTROL_SQL = {
  exists: "SELECT 1 AS present FROM session_v2 WHERE id = ? LIMIT 1",
  children: "SELECT id FROM session_v2 WHERE parent_id = ?",
};

/** Fetch + analyze ONE session. Throws a clear error when the session does not exist. */
export async function analyzeOne(
  db: SqliteHandle,
  sessionID: string,
  opts: { now: number; windowMin: number },
): Promise<Analysis> {
  const row = db.all(SQL.oneSession, sessionID)[0] as SessionRow | undefined;
  if (!row) throw new Error(`no session ${sessionID} in the opencode store`);
  const counts = db.all(SQL.counts, sessionID)[0] as { turns: number; first: number | null; last: number | null };
  const tail = db.all(SQL.tail, sessionID, MAX_MSGS_PER_SESSION) as any[];
  tail.reverse(); // oldest → newest
  const messages = tail.map((r) => ({
    seq: r.seq,
    type: r.type,
    time_created: r.time_created,
    data: r.data,
  }));
  // The counts query is authoritative for turns/span even when the tail is truncated.
  const a = analyzeSession(row, messages, { now: opts.now, windowMin: opts.windowMin });
  a.turns = Number(counts?.turns ?? a.turns);
  a.spanMs =
    counts?.first != null && counts?.last != null ? Number(counts.last) - Number(counts.first) : a.spanMs;
  return a;
}

/**
 * Resolve the default target set for `all`: sessions with activity inside `sinceMin`,
 * newest first, capped at `limit`. Subagent (child) sessions are included and marked.
 */
export async function listSessions(
  db: SqliteHandle,
  opts: { now: number; sinceMin: number; limit: number },
): Promise<SessionRow[]> {
  const since = opts.now - opts.sinceMin * 60_000;
  return db.all(SQL.recentSessions, since, opts.limit) as SessionRow[];
}

/** Clamp `limit`/`sinceMin` from a request (`DEFAULT_LIMIT`/`DEFAULT_SINCE_MIN` fallbacks). */
export function resolveLimit(input: Record<string, any>): number {
  return typeof input.limit === "number" && input.limit > 0 ? Math.min(input.limit, 50) : DEFAULT_LIMIT;
}
export function resolveSinceMin(input: Record<string, any>): number {
  return typeof input.sinceMin === "number" && input.sinceMin > 0 ? input.sinceMin : DEFAULT_SINCE_MIN;
}

/**
 * Resolve the request's target. `all` is HONOURED (the schema advertises it): `all:true`
 * forces the whole set (ignoring `session`); `all:false` REQUIRES a `session`; absent, the
 * presence of a non-`all` `session` picks one, else the whole set. Returns a bare error
 * (callers prefix it with the tool name).
 */
export function resolveTarget(
  input: Record<string, any>,
): { mode: "all" } | { mode: "one"; sessionID: string } | { error: string } {
  if (input.all === true) return { mode: "all" };
  const s = input.session;
  const isSession = typeof s === "string" && s !== "" && s !== "all";
  if (input.all === false) {
    if (!isSession) return { error: "`all:false` requires an explicit `session` id" };
  }
  if (!isSession) return { mode: "all" };
  const id = String(s);
  if (!/^ses_/.test(id)) return { error: `'${id}' is not a session id (want ses_…)` };
  return { mode: "one", sessionID: id };
}

/** Loudest first: LOOP/IDLE (needs attention), then WORKING, then DONE. */
export const VERDICT_RANK: Record<string, number> = { LOOP: 0, IDLE: 1, WORKING: 2, DONE: 3 };
export function sortByVerdict(analyses: Analysis[]): Analysis[] {
  return analyses.sort((x, y) => (VERDICT_RANK[x.verdict] ?? 9) - (VERDICT_RANK[y.verdict] ?? 9));
}

/**
 * The ONE "list sessions in the look-back and analyze each" loop, shared by `agent_progress`
 * (all) and `agent_control` (list). `signal`-aware; stops promptly on abort.
 */
export async function collectAnalyses(
  db: SqliteHandle,
  opts: { now: number; windowMin: number; sinceMin: number; limit: number; signal?: AbortSignal },
): Promise<Analysis[]> {
  const rows = await listSessions(db, { now: opts.now, sinceMin: opts.sinceMin, limit: opts.limit });
  const out: Analysis[] = [];
  for (const row of rows) {
    if (opts.signal?.aborted) break;
    out.push(await analyzeOne(db, row.id, { now: opts.now, windowMin: opts.windowMin }));
  }
  return out;
}

/**
 * The whole operation: resolve the DB, pick the sessions, analyze each, and render the
 * report. Async and `signal`-aware (an abort between sessions stops promptly). Any
 * failure returns a CLEAR message — the monitor never fabricates a verdict.
 */
export async function runProgress(
  input: Record<string, any> = {},
  ctx: { signal?: AbortSignal } = {},
): Promise<{ content: string }> {
  const now = Date.now();
  const windowMin =
    typeof input.windowMin === "number" && input.windowMin >= 0 ? input.windowMin : DEFAULT_WINDOW_MIN;
  const dbPath = typeof input.db === "string" && input.db !== "" ? input.db : databasePath();
  let db: SqliteHandle | null = null;
  try {
    if (ctx.signal?.aborted) return { content: "agent_progress: aborted (session interrupted)" };
    try {
      db = await openReadonly(dbPath);
    } catch (err: any) {
      return {
        content:
          `agent_progress: cannot open the opencode store read-only at ${dbPath} — ${err?.message ?? String(err)}\n` +
          `Set OPENCODE_DB to override the path (default: $XDG_DATA_HOME/opencode/opencode.db).`,
      };
    }
    const target = resolveTarget(input);
    if ("error" in target) return { content: `agent_progress: ${target.error}` };

    let analyses: Analysis[];
    if (target.mode === "one") {
      try {
        analyses = [await analyzeOne(db, target.sessionID, { now, windowMin })];
      } catch (err: any) {
        return { content: `agent_progress: ${err?.message ?? String(err)}` };
      }
    } else {
      analyses = await collectAnalyses(db, {
        now,
        windowMin,
        sinceMin: resolveSinceMin(input),
        limit: resolveLimit(input),
        signal: ctx.signal,
      });
      if (ctx.signal?.aborted) return { content: "agent_progress: aborted (session interrupted)" };
    }
    sortByVerdict(analyses);

    const note = target.mode === "all" ? `all sessions active in the last ${resolveSinceMin(input)}m` : undefined;
    return { content: formatReport(analyses, { db: dbPath, driver: db.driver, windowMin, note }) };
  } catch (err: any) {
    return { content: `agent_progress: unexpected error — ${err?.message ?? String(err)}` };
  } finally {
    try {
      db?.close();
    } catch {
      /* a close failure must never mask the report */
    }
  }
}

/**
 * Require an EXPLICIT session id for a mutating action. `interrupt`/`delete` never accept a
 * wildcard (`all`) — naming the session is the whole safety rail (never silently kill a
 * session another slug owns). Returns the id, or a clear refusal message.
 */
export function requireExplicitSession(input: Record<string, any>): { sessionID: string } | { error: string } {
  const s = input?.session;
  if (typeof s !== "string" || s.trim() === "" || s === "all") {
    return { error: "agent_control: this action requires an EXPLICIT session id (never `all`) — name the session to stop" };
  }
  if (!/^ses_/.test(s)) return { error: `agent_control: '${s}' is not a session id (want ses_…)` };
  return { sessionID: s };
}

/** The turn baseline of a session: count + last-turn time. The evidence `confirm_stopped` checks. */
export function turnStats(db: SqliteHandle, sessionID: string): { turns: number; lastTurn: number | null } {
  // Reuse the monitor's authoritative counts query (ONE counts query — R3).
  const row = db.all(SQL.counts, sessionID)[0] as { turns: number; first: number | null; last: number | null } | undefined;
  return { turns: Number(row?.turns ?? 0), lastTurn: row?.last == null ? null : Number(row.last) };
}

/** The live opencode CLI binary (override with OPENCODE_BIN for a non-PATH install / tests). */
export function opencodeBin(env: Record<string, string | undefined> = process.env): string {
  return env.OPENCODE_BIN && env.OPENCODE_BIN.trim() !== "" ? env.OPENCODE_BIN : "opencode";
}

/**
 * `delete` — run the opencode CLI, which deletes the session AND its child sessions.
 * One async `execFile` (the CLI is a tool, NOT a `.sh`); returns exit/stdout/stderr so the
 * caller never believes a delete that did not happen.
 */
export function runDelete(
  sessionID: string,
  opts: { bin?: string; signal?: AbortSignal } = {},
): Promise<{ ok: boolean; exit: number; stdout: string; stderr: string }> {
  const bin = opts.bin ?? opencodeBin();
  return new Promise((resolve) => {
    execFile(bin, ["session", "delete", sessionID], { signal: opts.signal }, (err: any, stdout, stderr) => {
      const exit = err ? (typeof err.code === "number" ? err.code : 1) : 0;
      resolve({
        ok: exit === 0,
        exit,
        stdout: String(stdout ?? ""),
        stderr: String(stderr ?? err?.message ?? ""),
      });
    });
  });
}

/** Render the compact `list` view: id, title/slug, agent, last-activity age, verdict. */
export function formatControlList(analyses: Analysis[]): string {
  if (analyses.length === 0) return "agent_control list: no sessions active in the look-back";
  const lines = ["id                          age        verdict  agent      title"];
  for (const a of analyses) {
    const age = a.lastEventAgeMs === null ? "—" : formatDuration(a.lastEventAgeMs);
    const title = snippet(a.title || a.slug || "", 40);
    lines.push(`${a.sessionID.padEnd(27)} ${age.padEnd(10)} ${a.verdict.padEnd(8)} ${a.agent.padEnd(10)} ${title}`);
  }
  return lines.join("\n");
}

/**
 * `confirm_stopped` — re-read the transcript and ASSERT no new turns. This is the "CONFIRM
 * it stopped" rule: an `interrupt` returns `{interrupted:true}` but that only proves the
 * request was accepted; the EVIDENCE is that the turn count and last-turn time are unchanged
 * (plus a quiet window from the live monitor). Optional `baselineTurns`/`baselineLastTurn`
 * come from the preceding `interrupt`/`delete` result; without them the report still states
 * the current turn count and the last-turn age.
 */
export function confirmStopped(
  a: Analysis,
  stats: { turns: number; lastTurn: number | null },
  baseline: { turns?: number; lastTurn?: number | null },
): { stopped: boolean; evidence: string } {
  const parts = [`turns ${stats.turns}`, `last-turn ${a.lastTurnAgeMs === null ? "—" : formatDuration(a.lastTurnAgeMs) + " ago"}`];
  if (typeof baseline.turns === "number") {
    const grew = stats.turns > baseline.turns;
    const moved = baseline.lastTurn != null && stats.lastTurn != null && stats.lastTurn > baseline.lastTurn;
    parts.push(`baseline turns ${baseline.turns}`);
    if (grew || moved) {
      return { stopped: false, evidence: `STILL RUNNING — new turns since the stop (${parts.join(", ")})` };
    }
    return { stopped: true, evidence: `stopped (no new turns) — ${parts.join(", ")}` };
  }
  // No baseline: report the live state; a quiet window is the corroboration.
  return { stopped: false, evidence: `no baseline given — current state: ${parts.join(", ")}; re-run with the interrupt's baseline to ASSERT stopped` };
}

/**
 * The whole `agent_control` operation. Async, `signal`-aware. `list` reads the store; the
 * mutating actions go through the live session context (`interrupt`/`wait`) or the opencode
 * CLI (`delete`); `confirm_stopped` re-reads the store. Every failure returns a CLEAR
 * message — the control tool never fabricates a result.
 */
export async function runControl(
  input: Record<string, any> = {},
  ctx: any = {},
): Promise<{ content: string }> {
  const action = String(input.action ?? "").trim();
  if (!CONTROL_ACTIONS.includes(action)) {
    return { content: `agent_control: unknown action '${input.action}' — one of: ${CONTROL_ACTIONS.join(" | ")}` };
  }
  const dbPath = typeof input.db === "string" && input.db !== "" ? input.db : databasePath();
  const now = Date.now();
  const windowMin = typeof input.windowMin === "number" && input.windowMin >= 0 ? input.windowMin : DEFAULT_WINDOW_MIN;
  let db: SqliteHandle | null = null;
  try {
    if (ctx?.signal?.aborted) return { content: "agent_control: aborted (session interrupted)" };
    try {
      db = await openReadonly(dbPath);
    } catch (err: any) {
      return { content: `agent_control: cannot open the opencode store read-only at ${dbPath} — ${err?.message ?? String(err)}` };
    }

    if (action === "list") {
      // ONE shared loop with agent_progress's `all` branch (R3).
      const analyses = await collectAnalyses(db, {
        now,
        windowMin,
        sinceMin: resolveSinceMin(input),
        limit: resolveLimit(input),
        signal: ctx?.signal,
      });
      if (ctx?.signal?.aborted) return { content: "agent_control: aborted (session interrupted)" };
      sortByVerdict(analyses);
      return { content: formatControlList(analyses) };
    }

    const target = requireExplicitSession(input);
    if ("error" in target) return { content: target.error };
    const sessionID = target.sessionID;

    // The session must EXIST before a control action names it.
    const exists = db.all(CONTROL_SQL.exists, sessionID)[0];
    if (!exists) return { content: `agent_control: no session ${sessionID} in the opencode store` };
    const before = turnStats(db, sessionID);

    if (action === "interrupt") {
      if (typeof ctx?.session?.interrupt !== "function") {
        return { content: "agent_control: ctx.session.interrupt is unavailable in this harness — cannot interrupt" };
      }
      await ctx.session.interrupt({ sessionID, continue: false });
      const after = turnStats(db, sessionID);
      return {
        content:
          `agent_control: interrupted ${sessionID} — ${JSON.stringify({ interrupted: true })}\n` +
          `before { turns: ${before.turns}, lastTurn: ${before.lastTurn ?? "null"} } → after { turns: ${after.turns}, lastTurn: ${after.lastTurn ?? "null"} }\n` +
          `Re-run with action=confirm_stopped and baselineTurns=${before.turns} to ASSERT no new turns.`,
      };
    }

    if (action === "delete") {
      // `opencode session delete <id>` deletes the session AND its child sessions.
      const children = db.all(CONTROL_SQL.children, sessionID) as Array<{ id: string }>;
      const res = await runDelete(sessionID, { signal: ctx?.signal });
      if (!res.ok) {
        return { content: `agent_control: delete ${sessionID} FAILED (exit ${res.exit}) — ${snippet(res.stderr || res.stdout, 300)}` };
      }
      return {
        content:
          `agent_control: deleted ${sessionID} and its ${children.length} child session(s)` +
          (children.length ? ` (${children.map((c) => c.id).join(", ")})` : "") +
          `\n${snippet(res.stdout, 300)}`,
      };
    }

    if (action === "wait") {
      if (typeof ctx?.session?.wait !== "function") {
        return { content: "agent_control: ctx.session.wait is unavailable in this harness — cannot wait" };
      }
      const timeoutS =
        typeof input.timeoutSec === "number" && input.timeoutSec > 0
          ? Math.min(input.timeoutSec, DEFAULT_WAIT_TIMEOUT_S * 10)
          : DEFAULT_WAIT_TIMEOUT_S;
      let timer: any;
      const timed = await Promise.race([
        ctx.session.wait({ sessionID }).then(() => false),
        new Promise<boolean>((resolve) => {
          timer = setTimeout(() => resolve(true), timeoutS * 1000);
        }),
      ]);
      clearTimeout(timer);
      const after = turnStats(db, sessionID);
      return {
        content: timed
          ? `agent_control: wait timed out after ${timeoutS}s — ${sessionID} still active (turns ${after.turns})`
          : `agent_control: ${sessionID} is idle (turns ${after.turns}, last-turn ${after.lastTurn ?? "null"})`,
      };
    }

    // action === "confirm_stopped"
    const a = await analyzeOne(db, sessionID, { now, windowMin });
    const stats = turnStats(db, sessionID);
    const { stopped, evidence } = confirmStopped(
      a,
      stats,
      { turns: input.baselineTurns, lastTurn: input.baselineLastTurn ?? null },
    );
    return { content: `agent_control: confirm_stopped ${sessionID} — ${stopped ? "STOPPED" : "NOT CONFIRMED"}\n  ${evidence}\n  VERDICT ${a.verdict}` };
  } catch (err: any) {
    return { content: `agent_control: unexpected error — ${err?.message ?? String(err)}` };
  } finally {
    try {
      db?.close();
    } catch {
      /* a close failure must never mask the result */
    }
  }
}

export default {
  id: PLUGIN_ID,
  // opencode >= 2.0 definition form: register the agent_progress tool.
  async setup(ctx: any) {
    await ctx.tool.transform((draft: any) => {
      draft.add({
        name: "agent_progress",
        description:
          "Monitor agent (subagent/session) PROGRESS from the opencode transcript — the " +
          "REAL signal, not a turn count. For each session it reports turns, span, " +
          "last-activity age, the tool mix, the LAST action (text/reasoning snippet + " +
          "last tool + its input), artifact hints (PR/merge/tag/push), and a verdict: " +
          "WORKING (recent turns + tool cadence) / IDLE (no turns past the window and no " +
          "artifact) / LOOP (the same tool+input repeated, no artifact) / DONE (a final " +
          "report, no pending action). Rotate/take over ONLY on: >2 orchestrator " +
          "re-briefs, idle-past-window with no artifact, or a loop — NEVER on turn count. " +
          "Reads the opencode store read-only; implemented natively in TypeScript.",
        input: {
          type: "object",
          properties: {
            session: {
              type: "string",
              description: "a ses_… session id; omit (or `all`) to monitor the active set",
            },
            all: { type: "boolean", description: "monitor every session active in the look-back (default)" },
            windowMin: {
              type: "number",
              description: `idle window in minutes (default ${DEFAULT_WINDOW_MIN}); no turn within it, with no artifact, is the stall candidate`,
            },
            limit: { type: "number", description: `max sessions for \`all\` (default ${DEFAULT_LIMIT})` },
            sinceMin: {
              type: "number",
              description: `look-back for \`all\` in minutes (default ${DEFAULT_SINCE_MIN})`,
            },
            db: { type: "string", description: "override the opencode store path (default: XDG data dir)" },
          },
        },
        execute: async (input: Record<string, any>, toolCtx: any) => {
          return runProgress(input ?? {}, { signal: toolCtx?.signal });
        },
      });

      draft.add({
        name: "agent_control",
        description:
          "CONTROL an opencode session/subagent from the orchestrator. Actions: " +
          "`list` (enumerate sessions — id, title, agent, last-activity age, verdict); " +
          "`interrupt` (STOP a running session WITHOUT deleting it — ctx.session.interrupt); " +
          "`delete` (`opencode session delete` — the session AND its child sessions); " +
          "`wait` (bounded block until the session goes idle); " +
          "`confirm_stopped` (re-read the transcript and ASSERT no new turns — the " +
          "CONFIRM-it-stopped rule). SAFETY: interrupt/delete require an EXPLICIT session " +
          "id (never `all`) and the result reports what was stopped, so a session another " +
          "slug owns is never silently killed. Implemented natively in TypeScript.",
        input: {
          type: "object",
          properties: {
            action: { type: "string", description: `one of: ${CONTROL_ACTIONS.join(" | ")}` },
            session: {
              type: "string",
              description: "a ses_… session id — REQUIRED for interrupt/delete/wait/confirm_stopped (never `all`)",
            },
            baselineTurns: {
              type: "number",
              description: "confirm_stopped: the turn count from the interrupt result (any new turn ⇒ NOT stopped)",
            },
            baselineLastTurn: {
              type: "number",
              description: "confirm_stopped: the last-turn time (ms) from the interrupt result",
            },
            windowMin: { type: "number", description: `verdict window in minutes (default ${DEFAULT_WINDOW_MIN})` },
            limit: { type: "number", description: `list: max sessions (default ${DEFAULT_LIMIT})` },
            sinceMin: { type: "number", description: `list: look-back in minutes (default ${DEFAULT_SINCE_MIN})` },
            timeoutSec: { type: "number", description: `wait: bounded deadline in seconds (default ${DEFAULT_WAIT_TIMEOUT_S})` },
            db: { type: "string", description: "override the opencode store path (default: XDG data dir)" },
          },
          required: ["action"],
        },
        execute: async (input: Record<string, any>, toolCtx: any) => {
          return runControl(input ?? {}, toolCtx ?? {});
        },
      });
    });
  },
  // opencode 1.x function form: loads, but tool registration needs the zod helper → no-op.
  async server(_input: any) {
    return {};
  },
};
