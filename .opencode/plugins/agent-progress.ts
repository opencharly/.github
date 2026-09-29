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
 * TOOL
 *   agent_progress  report, per session, the turns/span/age, the tool mix, the LAST
 *                   action (text/reasoning snippet + last tool + its input), the
 *                   artifact hints, and a WORKING / IDLE / LOOP / DONE verdict. Async,
 *                   `context.signal`-aware, never blocking, and it fails CLEARLY (it
 *                   never fabricates a verdict it cannot ground in the transcript).
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
  const stale = (age: number | null) => age === null || age > windowMs;
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
  lastEvent: "SELECT MAX(time_created) AS last FROM session_message WHERE session_id = ?",
  tail:
    "SELECT seq, type, time_created, data FROM session_message WHERE session_id = ? ORDER BY seq DESC LIMIT ?",
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
    const onlyAll = input.session === undefined || input.session === null || input.session === "all";
    if (!onlyAll && typeof input.session !== "string") {
      return { content: "agent_progress: `session` must be a ses_… id (or `all`)" };
    }

    const analyses: Analysis[] = [];
    if (!onlyAll) {
      if (!/^ses_/.test(String(input.session))) {
        return { content: `agent_progress: '${input.session}' is not a session id (want ses_…)` };
      }
      try {
        analyses.push(await analyzeOne(db, String(input.session), { now, windowMin }));
      } catch (err: any) {
        return { content: `agent_progress: ${err?.message ?? String(err)}` };
      }
    } else {
      const limit =
        typeof input.limit === "number" && input.limit > 0 ? Math.min(input.limit, 50) : DEFAULT_LIMIT;
      const sinceMin =
        typeof input.sinceMin === "number" && input.sinceMin > 0 ? input.sinceMin : DEFAULT_SINCE_MIN;
      const rows = await listSessions(db, { now, sinceMin, limit });
      for (const row of rows) {
        if (ctx.signal?.aborted) return { content: "agent_progress: aborted (session interrupted)" };
        analyses.push(await analyzeOne(db, row.id, { now, windowMin }));
      }
    }

    // Loudest first: LOOP/IDLE (needs attention), then WORKING, then DONE.
    const rank: Record<string, number> = { LOOP: 0, IDLE: 1, WORKING: 2, DONE: 3 };
    analyses.sort((x, y) => (rank[x.verdict] ?? 9) - (rank[y.verdict] ?? 9));

    const note = onlyAll
      ? `all sessions active in the last ${
          typeof input.sinceMin === "number" && input.sinceMin > 0 ? input.sinceMin : DEFAULT_SINCE_MIN
        }m`
      : undefined;
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
    });
  },
  // opencode 1.x function form: loads, but tool registration needs the zod helper → no-op.
  async server(_input: any) {
    return {};
  },
};
