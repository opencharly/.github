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
 * native to its harness (the operator's chosen clean split). They DO share ONE
 * contract, asserted by `scripts/check-opencode-coord.mjs` so the two cannot drift:
 *   * the event vocabulary + wake-line format — MERGED / CLOSED / COMMENT / VERDICT /
 *     STALL — and its SEMANTICS (merged/closed are STATE events, firing from the arm
 *     baseline; comment/verdict are DELTA events seeded at arm, so a pre-existing
 *     comment or run never false-fires; stall is a SILENCE alarm keyed on the item's
 *     `updated_at` while it is open+unmerged);
 *   * the item grammar (`owner/repo#num`, `owner/repo/pull|issues/num`, a full
 *     `https://github.com/...` URL).
 *
 * AUTH — the native client authenticates with `GITHUB_TOKEN` / `GH_TOKEN` when set,
 * else the `gh` CLI's stored token (`gh auth token` — one async `execFile`; the `gh`
 * binary is a TOOL, never a `.sh` script). The API is GitHub REST v3
 * (`https://api.github.com`, overridable with `GITHUB_API_URL` for GH Enterprise).
 *
 * CANCELLATION — every call takes an `AbortSignal` (the plugin executor's
 * `context.signal`), threaded into `fetch` and the poll sleep, so stopping the
 * Session terminates the watch promptly.
 */
import { execFile } from "node:child_process";

export const DEFAULT_API = "https://api.github.com";

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

// --- GitHub REST client -----------------------------------------------------

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

export interface GhOptions {
  method?: string;
  body?: unknown;
  signal?: AbortSignal;
}

/** Perform one GitHub API request, returning the raw `Response` (2xx only). */
export async function ghFetch(path: string, opts: GhOptions = {}): Promise<Response> {
  const base = process.env.GITHUB_API_URL || DEFAULT_API;
  const token = await resolveToken();
  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "opencharly-opencode-coord",
  };
  if (token) headers.Authorization = `token ${token}`;
  if (opts.body !== undefined) headers["Content-Type"] = "application/json";
  const res = await fetch(base + path, {
    method: opts.method ?? "GET",
    headers,
    body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
    signal: opts.signal,
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new GhError(res.status, `${opts.method ?? "GET"} ${path} → ${res.status} ${text.slice(0, 300)}`);
  }
  return res;
}

/** Perform one GitHub API request and parse the JSON body. */
export async function ghJson<T = any>(path: string, opts: GhOptions = {}): Promise<T> {
  return (await ghFetch(path, opts)).json() as Promise<T>;
}

// --- snapshot + event decision ---------------------------------------------

/** The observed state of one item at one poll. */
export interface Snap {
  type: "pr" | "issue";
  state: string;
  merged: boolean;
  comments: number | null;
  verdictId: string;
  updatedEpoch: number;
  verdictEpoch: number;
}

const nowEpoch = () => Math.floor(Date.now() / 1000);
const toEpoch = (iso: unknown): number => {
  const ms = Date.parse(String(iso ?? ""));
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : 0;
};

/** The newest COMPLETED run of `wf` on the item's repo, or undefined. */
async function latestRun(it: Item, wf: string, signal?: AbortSignal): Promise<any | undefined> {
  const j = await ghJson<{ workflow_runs?: any[] }>(
    `/repos/${it.owner}/${it.repo}/actions/runs?per_page=50`,
    { signal },
  );
  const done = (j?.workflow_runs ?? []).filter((r) => r?.name === wf && r?.status === "completed");
  return done[0];
}

/**
 * Observe one item. Every field is best-effort: a transient failure leaves its
 * field UNKNOWN (never throws), so one bad poll skips the item instead of killing
 * the watch — the same resilience `gh_watch.sh` encodes with `|| echo ""`.
 */
export async function snapshot(it: Item, opts: { wf: string; signal?: AbortSignal }): Promise<Snap> {
  const base = `/repos/${it.owner}/${it.repo}`;
  const s: Snap = {
    type: "issue",
    state: "unknown",
    merged: false,
    comments: null,
    verdictId: "",
    updatedEpoch: nowEpoch(),
    verdictEpoch: 0,
  };

  try {
    const p = await ghJson(`${base}/pulls/${it.num}`, { signal: opts.signal });
    s.type = "pr";
    s.merged = p?.merged === true;
  } catch {
    s.type = "issue";
    s.merged = false;
  }

  try {
    const issue = await ghJson(`${base}/issues/${it.num}`, { signal: opts.signal });
    s.state = typeof issue?.state === "string" ? issue.state : "unknown";
    s.comments = typeof issue?.comments === "number" ? issue.comments : null;
    const e = toEpoch(issue?.updated_at);
    if (e) s.updatedEpoch = e;
  } catch {
    /* leave state unknown / updatedEpoch now */
  }

  try {
    const run = await latestRun(it, opts.wf, opts.signal);
    if (run) {
      s.verdictId = String(run.id);
      s.verdictEpoch = toEpoch(run.updated_at);
    }
  } catch {
    /* no run visible */
  }
  return s;
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
        cur.type === "pr" ? "pull" : "issues"
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

/**
 * One poll over every item. Returns the FIRST fire (matching `gh_watch.sh`, which
 * exits on the first event) and updates `seeds` in place. An item with no seed yet
 * adopts its first observation as the baseline WITHOUT firing — EXCEPT that STATE
 * events (merged/closed/stall) intentionally fire from the baseline, which is what
 * makes arming `merged` on an already-merged PR wake immediately.
 */
export async function pollOnce(
  items: Item[],
  seeds: Map<string, Snap>,
  opts: PollOptions,
): Promise<Fire | null> {
  const now = nowEpoch();
  for (const it of items) {
    const cur = await snapshot(it, { wf: opts.wf, signal: opts.signal });
    const seed = seeds.get(it.key);
    const ev = seed
      ? watchEvent(seed, cur, opts.events, { armEpoch: opts.armEpoch, nowEpoch: now, stallMin: opts.stallMin })
      : null;
    seeds.set(it.key, cur);
    if (ev) {
      return { item: it, event: ev, seed: seed as Snap, snap: cur, line: formatWake(it, ev, seed as Snap, cur, { wf: opts.wf, stallMin: opts.stallMin }) };
    }
  }
  return null;
}

/** Seed the baseline for every item (best-effort; an item with no seed never fires a delta). */
export async function seedAll(
  items: Item[],
  opts: { wf: string; signal?: AbortSignal },
): Promise<Map<string, Snap>> {
  const seeds = new Map<string, Snap>();
  for (const it of items) seeds.set(it.key, await snapshot(it, opts));
  return seeds;
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

/** Remaining core API quota, or `null` when the FREE `/rate_limit` read failed. */
export async function rateRemaining(signal?: AbortSignal): Promise<number | null> {
  try {
    const j = await ghJson<{ resources?: { core?: { remaining?: number } } }>("/rate_limit", { signal });
    const r = j?.resources?.core?.remaining;
    return typeof r === "number" ? r : null;
  } catch {
    return null;
  }
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
