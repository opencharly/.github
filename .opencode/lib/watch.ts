/**
 * watch.ts — the ONE native TypeScript GitHub watcher engine shared by the
 * OpenCode coordination plugins (`coord.ts`'s `coord_watch`; `pr-watch.ts`).
 *
 * HARNESS SPLIT (operator directive, 2026-09-29). Harness-INDEPENDENT tooling is
 * SHELL — `marketplace/scripts/{coord,gh_watch,pr_watch_many,pr_state_watch}.sh` +
 * `_watch_common.sh` — usable from bash / Claude Code / Codex / git hooks / CI. The
 * OpenCode plugins are PURE TypeScript: they implement the watcher NATIVELY (HTTP + a
 * poll loop) and NEVER spawn a `.sh` (no `Bun.spawn` / `spawnSync` of a script, and
 * no dependency on any `.sh` file — hence NO `marketplace` submodule pin).
 *
 * R3 — the two are deliberately NOT a forked copy of one implementation: each is
 * native to its harness (the operator's SIGNED-OFF clean split — a maintainer-account
 * R3 divergence, not a self-asserted waiver). The shared CONTRACT is defined ONCE in
 * the shell family's docs; the native engine implements the SAME contract and the gate
 * asserts the TS side against it. Drift in the SHELL side alone is not compared by the
 * gate (the shell is not a dependency — no `.sh`, no pin) — the signed-off condition
 * requires only honest wording, so the contract is stated as a SPECIFICATION the TS
 * implements and the gate pins, never as a claim the two "cannot drift":
 *   * the event vocabulary + wake-line format — MERGED / CLOSED / COMMENT / VERDICT /
 *     STALL — and its SEMANTICS (merged/closed are STATE events, firing from the arm
 *     baseline; comment/verdict are DELTA events seeded at arm, so a pre-existing
 *     comment or run never false-fires; stall is a SILENCE alarm keyed on the item's
 *     `updated_at` while it is open+unmerged);
 *   * the item grammar (`owner/repo#num`, `owner/repo/pull|issues/num`, a full
 *     `https://github.com/...` URL).
 *
 * API EFFICIENCY (operator requirement, 2026-09-29):
 *   * ONE request per poll for N items — a single batched GraphQL query with one
 *     alias per item returning state / merged / updatedAt / commentCount /
 *     latest-commit / verdict-run. Calls-per-poll is 1 regardless of item count.
 *   * SKIP UNCHANGED ITEMS — a per-item fingerprint (state|merged|updatedAt|comments|
 *     verdict|commit) means a delta event is only evaluated when the fingerprint
 *     changed; an idle watch costs exactly one batched call per interval. The stall
 *     (silence) alarm is wall-clock-driven and still evaluated every poll.
 *   * RATE LIMITS FAIL HARD — a REST 403/429 or a GraphQL `RATE_LIMITED` error throws
 *     `RateLimitedError` (with the reset time); the watch surfaces it distinctly and
 *     NEVER spins/retries it as "no event". The remaining quota is read from the
 *     batched response's own `x-ratelimit-remaining` header (FREE — no extra call), so
 *     calls-per-poll stays 1 while a near-exhausted quota backs the watch off visibly.
 *
 * AUTH — the native client authenticates with `GITHUB_TOKEN` / `GH_TOKEN` when set,
 * else the `gh` CLI's stored token (`gh auth token` — one async `execFile`; the `gh`
 * binary is a TOOL, never a `.sh` script). REST is `https://api.github.com`; GraphQL is
 * `<REST>/graphql`. `GITHUB_API_URL` overrides the base (GitHub Enterprise / tests).
 *
 * CANCELLATION — every call takes an `AbortSignal` (the plugin executor's
 * `context.signal`), threaded into `fetch` and the poll sleep, so stopping the
 * Session terminates the watch promptly.
 */
import { execFile } from "node:child_process";

export const DEFAULT_API = "https://api.github.com";

/** The poll-interval FLOOR, seconds — sub-floor intervals are refused. */
export const POLL_FLOOR = 60;

/** Default poll cadence, seconds (the floor). */
export const DEFAULT_INTERVAL_S = POLL_FLOOR;

/** Default stall window, minutes. */
export const DEFAULT_STALL_MIN = 60;

/** Core-quota floor below which the watcher backs off instead of polling. */
export const RATE_FLOOR = 200;

/** Backoff multiplier applied to the poll interval when below `RATE_FLOOR`. */
export const BACKOFF_FACTOR = 4;

/** Backoff ceiling, seconds. */
export const MAX_BACKOFF_S = 600;

/** One normalised watch target. */
export interface Item {
  owner: string;
  repo: string;
  num: number;
  /** Canonical `owner/repo#num` — the wake-line item and the seed-map key. */
  key: string;
}

/**
 * Parse an item in any of the accepted forms to `{ owner, repo, num, key }`, or
 * return `null` for anything malformed. Mirrors `gh_watch.sh`'s `parse_item`.
 */
export function parseItem(raw: unknown): Item | null {
  let s = String(raw ?? "").trim();
  s = s.replace(/^https?:\/\/github\.com\//i, "");
  s = s.replace(/^github\.com\//i, "");
  s = s.split("?")[0];
  let m = /^([^/\s#]+)\/([^/\s#]+)#([0-9]+)$/.exec(s);
  if (!m) m = /^([^/\s]+)\/([^/\s]+)\/(?:pull|issues)\/([0-9]+)$/.exec(s);
  if (!m) return null;
  const owner = m[1];
  const repo = m[2];
  const num = Number(m[3]);
  if (!owner || !repo || !Number.isInteger(num)) return null;
  return { owner, repo, num, key: `${owner}/${repo}#${num}` };
}

// --- GitHub client ----------------------------------------------------------

let cachedToken: string | undefined;

/** Resolve a token: `GITHUB_TOKEN` / `GH_TOKEN`, else the `gh` CLI's stored token. */
export async function resolveToken(): Promise<string | undefined> {
  const env = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  if (env) return env;
  if (cachedToken !== undefined) return cachedToken || undefined;
  cachedToken = await new Promise<string>((resolve) => {
    execFile("gh", ["auth", "token"], { encoding: "utf8" }, (err, stdout) =>
      resolve(err ? "" : String(stdout).trim()),
    );
  });
  return cachedToken || undefined;
}

/** A non-2xx GitHub API response. */
export class GhError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
    this.name = "GhError";
  }
}

/**
 * A RATE-LIMIT condition — REST 403/429 or GraphQL `RATE_LIMITED`. NEVER swallowed:
 * the caller surfaces it distinctly and does NOT retry it as "no event".
 */
export class RateLimitedError extends Error {
  /** Unix seconds when the quota resets (0 when unknown). */
  resetAt: number;
  kind: "rest" | "graphql";
  constructor(kind: "rest" | "graphql", resetAt: number, message: string) {
    super(message);
    this.resetAt = resetAt;
    this.kind = kind;
    this.name = "RateLimitedError";
  }
}

/** The REST base (overridable) and its GraphQL endpoint. */
export function apiBase(): string {
  return process.env.GITHUB_API_URL || DEFAULT_API;
}
export function graphqlUrl(): string {
  return `${apiBase()}/graphql`;
}

async function authHeaders(): Promise<Record<string, string>> {
  const token = await resolveToken();
  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "opencharly-opencode-coord",
  };
  if (token) headers.Authorization = `token ${token}`;
  return headers;
}

const headerEpoch = (res: Response): number => {
  const r = res.headers.get("x-ratelimit-reset");
  const n = r ? Number(r) : NaN;
  return Number.isFinite(n) ? n : 0;
};
const headerRemaining = (res: Response): number | null => {
  const r = res.headers.get("x-ratelimit-remaining");
  const n = r ? Number(r) : NaN;
  return Number.isFinite(n) ? n : null;
};

/** A REST response's rate-limit metadata (FREE — read from the response headers). */
export interface RateInfo {
  /** Core-quota remaining, or null when the header was absent. */
  remaining: number | null;
  /** Unix seconds when the quota resets, or 0 when unknown. */
  resetAt: number;
}

export interface GhOptions {
  method?: string;
  body?: unknown;
  signal?: AbortSignal;
}

/** Perform one REST request, returning the raw `Response` (2xx only). */
export async function ghFetch(path: string, opts: GhOptions = {}): Promise<Response> {
  const headers = await authHeaders();
  if (opts.body !== undefined) headers["Content-Type"] = "application/json";
  let res: Response;
  try {
    res = await fetch(apiBase() + path, {
      method: opts.method ?? "GET",
      headers,
      body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
      signal: opts.signal,
    });
  } catch (err: any) {
    if (opts.signal?.aborted) throw err;
    throw new GhError(0, `network error: ${err?.message ?? String(err)}`);
  }
  if (res.status === 403 || res.status === 429) {
    // A 403 is rate-limit ONLY when the quota header says so; a bare 403 (permissions)
    // stays a plain GhError. 429 is always a rate limit.
    if (res.status === 429 || headerRemaining(res) === 0) {
      throw new RateLimitedError("rest", headerEpoch(res), `REST ${res.status} — rate limited`);
    }
  }
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new GhError(res.status, `${opts.method ?? "GET"} ${path} → ${res.status} ${text.slice(0, 300)}`);
  }
  return res;
}

/** Perform one REST request and parse the JSON body. */
export async function ghJson<T = any>(path: string, opts: GhOptions = {}): Promise<T> {
  return (await ghFetch(path, opts)).json() as Promise<T>;
}

// --- batched GraphQL snapshot (ONE request per poll for N items) -------------

/** The observed state of one item at one poll. */
export interface Snap {
  isPr: boolean;
  state: string;
  merged: boolean;
  comments: number | null;
  verdictId: string;
  updatedEpoch: number;
  verdictEpoch: number;
  latestCommit: string;
}

const nowEpoch = () => Math.floor(Date.now() / 1000);
const toEpoch = (iso: unknown): number => {
  const ms = Date.parse(String(iso ?? ""));
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : 0;
};

/** A stable per-item fingerprint — a delta event is only considered when it changes. */
export function fingerprint(s: Snap): string {
  return [s.state, s.merged ? 1 : 0, s.updatedEpoch, s.comments ?? "", s.verdictId, s.latestCommit].join("|");
}

/** A blank observation (state UNKNOWN) — used when a field is absent. */
function emptySnap(): Snap {
  return {
    isPr: false,
    state: "unknown",
    merged: false,
    comments: null,
    verdictId: "",
    updatedEpoch: nowEpoch(),
    verdictEpoch: 0,
    latestCommit: "",
  };
}

interface BatchResult {
  snaps: Map<string, Snap>;
  rate: RateInfo;
}

/**
 * Observe EVERY item in ONE batched GraphQL query (one alias per item). Calls-per-poll
 * is 1 regardless of item count. Throws `RateLimitedError` on a GraphQL `RATE_LIMITED`
 * error; other GraphQL field errors are tolerated when partial `data` is returned.
 */
export async function batchSnapshot(
  items: Item[],
  opts: { wf: string; signal?: AbortSignal },
): Promise<BatchResult> {
  const fields: string[] = [];
  const vars: Record<string, unknown> = {};
  items.forEach((it, i) => {
    vars[`o${i}`] = it.owner;
    vars[`r${i}`] = it.repo;
    vars[`n${i}`] = it.num;
    fields.push(
      `i${i}: repository(owner: $o${i}, name: $r${i}) {
        pullRequest(number: $n${i}) {
          state merged updatedAt
          commits(last: 1) { nodes { commit { oid committedDate
            checkSuites(first: 50) { nodes { workflowRun { databaseId workflow { name } status conclusion updatedAt } } } } } }
        }
        issue(number: $n${i}) { state updatedAt comments { totalCount } }
      }`,
    );
  });
  const query = `query(${Object.keys(vars).map((k) => `$${k}: ${k.startsWith("n") ? "Int" : "String"}!`).join(", ")}) { ${fields.join("\n")} }`;

  const headers = await authHeaders();
  headers["Content-Type"] = "application/json";
  let res: Response;
  try {
    res = await fetch(graphqlUrl(), {
      method: "POST",
      headers,
      body: JSON.stringify({ query, variables: vars }),
      signal: opts.signal,
    });
  } catch (err: any) {
    if (opts.signal?.aborted) throw err;
    throw new GhError(0, `network error: ${err?.message ?? String(err)}`);
  }
  const rate: RateInfo = { remaining: headerRemaining(res), resetAt: headerEpoch(res) };
  if (res.status === 403 || res.status === 429) {
    if (res.status === 429 || headerRemaining(res) === 0) {
      throw new RateLimitedError("rest", rate.resetAt, `GraphQL HTTP ${res.status} — rate limited`);
    }
  }
  const body: any = await res.json().catch(() => ({}));
  const errors: any[] = Array.isArray(body?.errors) ? body.errors : [];
  for (const e of errors) {
    const type = String(e?.type ?? e?.extensions?.code ?? "");
    if (type === "RATE_LIMITED" || /rate limit/i.test(String(e?.message ?? ""))) {
      throw new RateLimitedError("graphql", rate.resetAt, `GraphQL RATE_LIMITED: ${e?.message ?? ""}`);
    }
  }
  if (!body?.data) {
    const msg = errors.map((e) => e?.message).filter(Boolean).join("; ") || `GraphQL HTTP ${res.status}`;
    throw new GhError(res.status, `GraphQL query failed: ${msg}`);
  }

  const snaps = new Map<string, Snap>();
  items.forEach((it, i) => {
    const node = body.data[`i${i}`] ?? {};
    const pr = node.pullRequest;
    const issue = node.issue;
    const s = emptySnap();
    if (pr) {
      s.isPr = true;
      s.state = String(pr.state ?? "unknown").toLowerCase();
      s.merged = pr.merged === true;
      s.updatedEpoch = toEpoch(pr.updatedAt) || s.updatedEpoch;
      const commit = pr.commits?.nodes?.[0]?.commit;
      if (commit?.oid) s.latestCommit = String(commit.oid);
      // verdict = the newest COMPLETED run of the watched workflow in the latest commit's check suites.
      const runs: any[] = [];
      for (const suite of commit?.checkSuites?.nodes ?? []) {
        const run = suite?.workflowRun;
        if (run && run?.workflow?.name === opts.wf && run?.status === "completed") runs.push(run);
      }
      runs.sort((a, b) => toEpoch(b.updatedAt) - toEpoch(a.updatedAt));
      if (runs[0]) {
        s.verdictId = String(runs[0].databaseId);
        s.verdictEpoch = toEpoch(runs[0].updatedAt);
      }
    } else if (issue) {
      s.state = String(issue.state ?? "unknown").toLowerCase();
      s.updatedEpoch = toEpoch(issue.updatedAt) || s.updatedEpoch;
      const cc = issue.comments?.totalCount;
      if (typeof cc === "number") s.comments = cc;
    }
    snaps.set(it.key, s);
  });
  return { snaps, rate };
}

export type WatchEventName = "merged" | "closed" | "comment" | "verdict" | "stall";

export interface EventOptions {
  /** Unix seconds when the watch armed — the verdict newness gate. */
  armEpoch: number;
  /** Unix seconds of this poll. */
  nowEpoch: number;
  /** Stall window, minutes. */
  stallMin: number;
}

/**
 * Decide whether `cur` fires an event against `seed` for the requested event set.
 * The order (merged, closed, comment, verdict, stall) matches `gh_watch.sh` so a
 * multi-condition item resolves identically in both harnesses. Returns the event
 * name, or `null` when nothing fires.
 */
export function watchEvent(
  seed: Snap,
  cur: Snap,
  events: Set<string>,
  opts: EventOptions,
): WatchEventName | null {
  if (events.has("merged") && cur.merged === true) return "merged";
  if (events.has("closed") && cur.state === "closed" && cur.merged !== true) return "closed";
  if (
    events.has("comment") &&
    cur.comments !== null &&
    seed.comments !== null &&
    cur.comments !== seed.comments
  ) {
    return "comment";
  }
  if (
    events.has("verdict") &&
    cur.verdictId !== "" &&
    cur.verdictId !== seed.verdictId &&
    cur.verdictEpoch > 0 &&
    cur.verdictEpoch >= opts.armEpoch
  ) {
    return "verdict";
  }
  // stall requires an OBSERVED open state — never alarm on an unknown state.
  if (
    events.has("stall") &&
    cur.merged !== true &&
    cur.state !== "closed" &&
    cur.state !== "" &&
    cur.state !== "unknown" &&
    Math.floor((opts.nowEpoch - cur.updatedEpoch) / 60) >= opts.stallMin
  ) {
    return "stall";
  }
  return null;
}

/** The wake line for a fired event, byte-compatible with `gh_watch.sh`'s stdout. */
export function formatWake(
  it: Item,
  event: WatchEventName,
  seed: Snap,
  cur: Snap,
  opts: { wf: string; stallMin: number },
): string {
  const url = `https://github.com/${it.owner}/${it.repo}`;
  switch (event) {
    case "merged":
      return `MERGED   ${it.key}  (unblocked)`;
    case "closed":
      return `CLOSED   ${it.key}  closed without merging — find its successor`;
    case "comment":
      return `COMMENT  ${it.key}  new comment (${seed.comments} -> ${cur.comments})  ${url}/${
        cur.isPr ? "pull" : "issues"
      }/${it.num}`;
    case "verdict":
      return `VERDICT  ${it.key}  new ${opts.wf} run ${cur.verdictId}  ${url}/actions/runs/${cur.verdictId}`;
    case "stall":
      return `STALL    ${it.key}  no progress for ${opts.stallMin}m (open, unmerged) — takeover candidate`;
  }
  return "";
}

/** A fired event plus the seed/observation that produced it. */
export interface Fire {
  item: Item;
  event: WatchEventName;
  line: string;
  seed: Snap;
  snap: Snap;
}

export interface PollOptions {
  events: Set<string>;
  wf: string;
  armEpoch: number;
  stallMin: number;
  signal?: AbortSignal;
}

/** The outcome of one batched poll. */
export interface PollOutcome {
  fire: Fire | null;
  /** Core-quota remaining as reported by the batched response (null when absent). */
  rateRemaining: number | null;
  /** Unix seconds when the quota resets (0 when unknown). */
  rateResetAt: number;
  /** How many items were skipped as unchanged this poll. */
  skipped: number;
}

/**
 * One batched poll over EVERY item (ONE GraphQL request), returning the FIRST fire
 * (matching `gh_watch.sh`, which exits on the first event) and updating `seeds` in
 * place. Items whose fingerprint is unchanged skip the delta decision (a delta event
 * cannot have changed); the wall-clock stall alarm is still evaluated. An item with no
 * seed yet adopts its first observation as the baseline WITHOUT firing — EXCEPT that
 * STATE events (merged/closed/stall) intentionally fire from the baseline, which is
 * what makes arming `merged` on an already-merged PR wake immediately.
 *
 * Throws `RateLimitedError` on a rate limit — the caller surfaces it distinctly.
 */
export async function pollOnce(
  items: Item[],
  seeds: Map<string, Snap>,
  opts: PollOptions,
): Promise<PollOutcome> {
  const now = nowEpoch();
  const { snaps, rate } = await batchSnapshot(items, { wf: opts.wf, signal: opts.signal });
  // A fingerprint-unchanged item can be SKIPPED only for DELTA events (comment/verdict),
  // which cannot fire without a change. STATE events (merged/closed/stall) fire from the
  // arm baseline and are wall-clock/state-driven, so they are ALWAYS evaluated (the cost
  // is the ONE batched call already made — the skip only avoids redundant decisions).
  const hasStateEvent = opts.events.has("merged") || opts.events.has("closed") || opts.events.has("stall");
  let skipped = 0;
  let fire: Fire | null = null;
  for (const it of items) {
    const cur = snaps.get(it.key) ?? emptySnap();
    const seed = seeds.get(it.key);
    if (seed && !hasStateEvent && fingerprint(seed) === fingerprint(cur) && !fire) {
      skipped += 1;
      continue;
    }
    const ev = seed
      ? watchEvent(seed, cur, opts.events, { armEpoch: opts.armEpoch, nowEpoch: now, stallMin: opts.stallMin })
      : null;
    seeds.set(it.key, cur);
    if (ev && !fire) {
      fire = {
        item: it,
        event: ev,
        seed: seed as Snap,
        snap: cur,
        line: formatWake(it, ev, seed as Snap, cur, { wf: opts.wf, stallMin: opts.stallMin }),
      };
    }
  }
  return { fire, rateRemaining: rate.remaining, rateResetAt: rate.resetAt, skipped };
}

/** Seed the baseline for every item (ONE batched request; no fire on seed). */
export async function seedAll(
  items: Item[],
  opts: { wf: string; signal?: AbortSignal },
): Promise<Map<string, Snap>> {
  const { snaps } = await batchSnapshot(items, opts);
  return snaps;
}

/** A `setTimeout` that resolves early (without throwing) when `signal` aborts. */
export function sleepAbortable(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal?.aborted) return resolve();
    const onAbort = () => {
      clearTimeout(t);
      resolve();
    };
    const t = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

/** Parse a comma-separated event list into a set (trimmed, lower-case). */
export function parseEvents(list: string | undefined, dflt: string): Set<string> {
  return new Set(
    String(list ?? dflt)
      .split(",")
      .map((s) => s.trim().toLowerCase())
      .filter(Boolean),
  );
}

/** Clamp a requested interval to the floor; returns the effective interval in seconds. */
export function clampInterval(sec: number | undefined): number {
  if (typeof sec !== "number" || !Number.isFinite(sec)) return DEFAULT_INTERVAL_S;
  return Math.max(POLL_FLOOR, Math.floor(sec));
}

/** Human-readable rate-limit message (used verbatim by the tools). */
export function rateLimitMessage(e: RateLimitedError): string {
  const when = e.resetAt > 0 ? ` resets at ${new Date(e.resetAt * 1000).toISOString()}` : "";
  return `RATE-LIMITED (${e.kind}) — GitHub API rate limit hit.${when} No retry (fail hard).`;
}
