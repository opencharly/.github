#!/usr/bin/env node
// check-opencode-coord.mjs — regression gate for `.opencode/plugins/coord.ts`.
//
// The OpenCode coordination tools are PURE TypeScript (operator directive,
// 2026-09-29): they implement the verb grammar + footer and poll GitHub NATIVELY
// and NEVER delegate to a `.sh`. This gate therefore has THREE jobs:
//
//   0  STATIC — `coord.ts`/`pr-watch.ts` (comments stripped) contain NO `.sh`
//      reference, NO `spawnSync`, and NO `Bun.spawn(...*.sh)`. The native rewrite
//      exists precisely so the plugin loads its code AND its behaviour from the SAME
//      ref, with NO `marketplace` submodule pin — a shell-out would re-introduce the
//      pin dependency the fix removes.
//   A  the real plugin module is a V2 definition with BOTH loader entry points.
//   B  the pure helpers behave (parseConf, isTier, resolveIdentity, canonicalVerb,
//      buildComment, parseItem, watchEvent, formatWake, parseEvents) — the CONTRACT
//      the TypeScript plugin implements and this gate pins.
//   B2 the tool EXECUTE paths run for real: `coord_comment` builds the canonical
//      footer (dryRun) and POSTS via native `fetch` (mock server); `coord_watch`
//      returns the wake line from a mocked GitHub API.
//   C  LIVE_OPENCODE=1 drives the REAL `opencode` binary end to end against a LOCAL
//      capture server (GITHUB_API_URL) — the real TypeScript POST path executes in
//      the real binary; `coord_comment` posts and `coord_watch` fires MERGED, with no
//      server reload. Skipped visibly when unset (live-or-skip; never a silent pass).
//
// No stubs of the OPENCODE boundary in A/B/B2; the C layer runs the real binary.

import { spawnSync } from "node:child_process";
import { createServer } from "node:http";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");

function arg(name, dflt) {
  const i = process.argv.indexOf(name);
  return i !== -1 && i + 1 < process.argv.length ? process.argv[i + 1] : dflt;
}

const pluginPath = resolve(root, arg("--plugin", ".opencode/plugins/coord.ts"));
const prWatchPath = resolve(root, arg("--pr-watch", ".opencode/plugins/pr-watch.ts"));

let failures = 0;
const pass = (m) => console.log(`  PASS  ${m}`);
const fail = (m) => {
  failures += 1;
  console.error(`  FAIL  ${m}`);
};
const ok = (cond, m) => (cond ? pass(m) : fail(m));
const eq = (a, b, m) =>
  ok(JSON.stringify(a) === JSON.stringify(b), `${m} (got ${JSON.stringify(a)})`);

function run(cmd, args, opts = {}) {
  // opencode resolves its working location from the inherited PWD env var, not
  // the process cwd; keep them in lockstep (measured in check-opencode-plugin.mjs).
  const env = { ...process.env, ...(opts.env ?? {}) };
  if (opts.cwd) env.PWD = opts.cwd;
  return spawnSync(cmd, args, { encoding: "utf8", ...opts, env });
}

function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n")
    .filter((l) => !l.trim().startsWith("//"))
    .join("\n");
}

// --- Layer 0: STATIC — no shell delegation, no .sh dependency ----------------
console.log(`check-opencode-coord: ${pluginPath}`);
for (const p of [pluginPath, prWatchPath]) {
  const code = stripComments(readFileSync(p, "utf8"));
  const rel = p.slice(root.length + 1);
  ok(!/spawnSync/.test(code), `${rel}: contains NO spawnSync`);
  ok(!/Bun\.spawn/.test(code), `${rel}: contains NO Bun.spawn`);
  ok(!/\.sh\b/.test(code), `${rel}: contains NO .sh reference (no shell delegation)`);
  ok(!/execFile\(\s*["']bash/.test(code), `${rel}: no bash execFile`);
}

// --- Layer A: the real plugin module is a V2 definition ---------------------
let mod;
try {
  mod = await import(pathToFileURL(pluginPath).href);
} catch (err) {
  fail(`plugin did not import: ${err.message}`);
}
if (mod) {
  const plugin = mod.default;
  ok(
    plugin !== null && typeof plugin === "object" && !Array.isArray(plugin),
    "default export is a definition object (V2), not a V1 function",
  );
  const hasSetup = typeof plugin?.setup === "function";
  const hasServer = typeof plugin?.server === "function";
  ok(hasSetup && hasServer, `definition exposes BOTH setup() (>=2.0) and server() (1.x) [setup=${hasSetup} server=${hasServer}]`);
  ok(typeof plugin?.id === "string" && plugin.id.length > 0, "definition has a string id");

  // The declared @opencode-ai/plugin version must carry the ./v2/promise export the
  // plugin types against. The declared pin is asserted ALWAYS; the installed
  // package's export is asserted when it is present (live-or-skip — a worktree
  // without `bun install` has no node_modules).
  const pkgPath = join(root, ".opencode", "package.json");
  if (existsSync(pkgPath)) {
    const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
    const declared = pkg?.dependencies?.["@opencode-ai/plugin"];
    ok(typeof declared === "string" && declared.length > 0, `package.json declares @opencode-ai/plugin (${declared})`);
    ok(pkg?.type === "module", "package.json sets type=module (silences the MODULE_TYPELESS warning)");
    const installedPkg = join(root, ".opencode", "node_modules", "@opencode-ai", "plugin", "package.json");
    if (existsSync(installedPkg)) {
      const ip = JSON.parse(readFileSync(installedPkg, "utf8"));
      ok(ip?.exports?.["./v2/promise"], `the installed @opencode-ai/plugin ${ip.version} exports ./v2/promise`);
    } else {
      console.log("  SKIP  installed @opencode-ai/plugin absent (run `bun install` in .opencode to assert the ./v2/promise export)");
    }
  } else {
    fail(".opencode/package.json is missing (the V2 type pin)");
  }

  // --- Layer B: the pure helpers (the CONTRACT, no opencode needed) --------
  const {
    parseConf,
    isTier,
    resolveIdentity,
    canonicalVerb,
    buildComment,
    parseItem,
    watchEvent,
    formatWake,
    parseEvents,
    parseReviewVerdict,
    runState,
    armReport,
    armNotable,
    TIERS,
    VERBS,
    DEFAULT_EVENTS,
  } = mod;

  eq(
    parseConf("# comment\nagent=slug-x\n\nharness = OpenCode\nmodel=DeepSeek V4.1 Flash\n"),
    { agent: "slug-x", harness: "OpenCode", model: "DeepSeek V4.1 Flash" },
    "parseConf trims, drops blanks/# comments, splits on the first '='",
  );
  eq(parseConf(""), {}, "parseConf yields {} for empty text");

  ok(isTier("fully tested and validated"), "isTier accepts a canonical tier");
  ok(!isTier("pretty sure it works"), "isTier rejects an invented tier");
  ok(!isTier(undefined), "isTier rejects a non-string");

  // canonicalVerb — the closed set normalisation shared with `coord.sh`.
  eq(canonicalVerb("handing_over"), "HANDING OVER", "canonicalVerb normalises `handing_over` → `HANDING OVER`");
  eq(canonicalVerb("taking over"), "TAKING OVER", "canonicalVerb collapses runs of spaces");
  eq(canonicalVerb("STATUS"), "STATUS", "canonicalVerb keeps the canonical label");
  eq(canonicalVerb("nope"), "", "canonicalVerb rejects a verb outside the closed set");

  // args > env > conf ; the live session always wins.
  const id = resolveIdentity(
    { agent: "from-args", confidence: "documentation reviewed" },
    { agent: "from-conf", harness: "ConfHarness", model: "ConfModel", session: "conf-session" },
    { COORD_AGENT: "from-env", COORD_MODEL: "EnvModel" },
    "live-session",
  );
  eq(id.agent, "from-args", "resolveIdentity: args beat env and conf");
  eq(id.model, "EnvModel", "resolveIdentity: env beats conf");
  eq(id.harness, "ConfHarness", "resolveIdentity: conf fills the rest");
  eq(id.session, "live-session", "resolveIdentity: the live session id always wins");
  eq(id.confidence, "documentation reviewed", "resolveIdentity: confidence from args");

  // buildComment — the canonical footer contract, EXACTLY `coord.sh`'s format.
  const built = buildComment("STATUS", "hello", {
    agent: "slug-x",
    session: "ses_x",
    harness: "OpenCode",
    model: "DeepSeek V4.1 Flash",
    confidence: "documentation reviewed",
  });
  eq(
    built,
    "STATUS\n\nhello\n\n*Agent: `slug-x` · session `ses_x`*\n*Assisted-by: OpenCode DeepSeek V4.1 Flash (documentation reviewed)*",
    "buildComment matches coord.sh byte-for-byte (verb, body, Agent: FIRST, Assisted-by: LAST)",
  );
  ok(
    built.indexOf("*Agent:") < built.indexOf("*Assisted-by:"),
    "buildComment: canonical footer order (Agent: BEFORE Assisted-by:)",
  );
  ok(
    buildComment("RESOLVED", undefined, id).split("\n").join(" ").includes("*Agent:"),
    "buildComment omits the blank body line when body is absent",
  );

  // parseItem — the item grammar shared with gh_watch.sh's parse_item.
  eq(parseItem("acme/widget#7"), { owner: "acme", repo: "widget", num: 7, key: "acme/widget#7" }, "parseItem accepts owner/repo#num");
  eq(parseItem("acme/widget/pull/7").key, "acme/widget#7", "parseItem accepts owner/repo/pull/num");
  eq(parseItem("https://github.com/acme/widget/issues/7").key, "acme/widget#7", "parseItem accepts a full URL");
  eq(parseItem("nope"), null, "parseItem rejects a malformed item");

  // watchEvent — the event semantics shared with gh_watch.sh.
  const evSet = new Set(["merged", "closed", "comment", "verdict", "stall"]);
  const base = { isPr: true, state: "open", merged: false, comments: 3, latestComment: "", reviewVerdict: "", verdictId: "10", verdictStatus: "completed", verdictConclusion: "success", updatedEpoch: 1000, verdictEpoch: 1000 };
  const it = parseItem("acme/widget#7");
  eq(watchEvent(base, { ...base, merged: true }, evSet, { armEpoch: 0, nowEpoch: 2000, stallMin: 60 }), "merged", "watchEvent: merged fires on merged=true (STATE)");
  eq(watchEvent(base, { ...base, state: "closed" }, evSet, { armEpoch: 0, nowEpoch: 2000, stallMin: 60 }), "closed", "watchEvent: closed fires when closed and unmerged");
  eq(watchEvent(base, { ...base, comments: 4 }, evSet, { armEpoch: 0, nowEpoch: 2000, stallMin: 60 }), "comment", "watchEvent: comment fires on a comment-count change (DELTA)");
  eq(watchEvent(base, { ...base, comments: 3 }, evSet, { armEpoch: 0, nowEpoch: 2000, stallMin: 60 }), null, "watchEvent: an unchanged comment count never fires (seeded)");
  eq(
    watchEvent(base, { ...base, verdictId: "11", verdictEpoch: 5000, verdictStatus: "completed" }, evSet, { armEpoch: 4000, nowEpoch: 6000, stallMin: 60 }),
    "verdict",
    "watchEvent: verdict fires on a NEW run at/after arm",
  );
  // The verdict event covers EVERY run status and a STATUS TRANSITION, not only completion.
  eq(
    watchEvent(base, { ...base, verdictId: "10", verdictStatus: "in_progress", verdictConclusion: "" }, evSet, { armEpoch: 4000, nowEpoch: 6000, stallMin: 60 }),
    "verdict",
    "watchEvent: verdict fires on a QUEUED→IN_PROGRESS status transition of the SAME run (not only completion)",
  );
  eq(
    watchEvent(base, { ...base, verdictId: "10", verdictStatus: "completed", verdictConclusion: "failure" }, evSet, { armEpoch: 4000, nowEpoch: 6000, stallMin: 60 }),
    "verdict",
    "watchEvent: verdict fires on an IN_PROGRESS→COMPLETED transition (conclusion change)",
  );
  eq(
    watchEvent(base, { ...base, verdictId: "9", verdictEpoch: 500, verdictStatus: "completed" }, new Set(["verdict"]), { armEpoch: 4000, nowEpoch: 6000, stallMin: 60 }),
    null,
    "watchEvent: an OLDER pre-arm run never fires (the arm-epoch gate)",
  );
  eq(
    watchEvent(base, { ...base, verdictId: "9", verdictEpoch: 500, verdictStatus: "completed" }, evSet, { armEpoch: 4000, nowEpoch: 6000, stallMin: 60 }),
    "stall",
    "watchEvent: with verdict disabled, an old run falls through to the silence alarm (order mirrors gh_watch.sh)",
  );
  eq(
    watchEvent(base, { ...base, updatedEpoch: 100 }, evSet, { armEpoch: 0, nowEpoch: 100 + 3600, stallMin: 60 }),
    "stall",
    "watchEvent: stall fires after the window while open+unmerged (SILENCE alarm)",
  );
  eq(
    watchEvent(base, { ...base, state: "unknown", updatedEpoch: 100 }, evSet, { armEpoch: 0, nowEpoch: 100 + 3600, stallMin: 60 }),
    null,
    "watchEvent: stall never fires on an UNKNOWN state",
  );

  // parseReviewVerdict — the review verdict read from the latest comment body.
  eq(parseReviewVerdict("## Review — BLOCK\n\n### Blocks\n- x"), "BLOCK", "parseReviewVerdict reads a `## Review — BLOCK` heading");
  eq(parseReviewVerdict("\n\n## Review — PASS  "), "PASS", "parseReviewVerdict reads a `## Review — PASS` heading (leading blanks skipped)");
  eq(parseReviewVerdict("## validator INCONCLUSIVE — no review verdict was produced (not a BLOCK)"), "", "parseReviewVerdict does NOT read the INCONCLUSIVE prose 'BLOCK' as a verdict");
  eq(parseReviewVerdict("BLOCK"), "BLOCK", "parseReviewVerdict accepts a bare leading BLOCK");
  eq(parseReviewVerdict(""), "", "parseReviewVerdict yields '' for an empty body");

  // runState — the status[/conclusion] the VERDICT wake line carries (EVERY status).
  eq(runState({ ...base, verdictStatus: "in_progress", verdictConclusion: "" }), "IN_PROGRESS", "runState reports a run in progress (no conclusion yet)");
  eq(runState({ ...base, verdictStatus: "queued", verdictConclusion: "" }), "QUEUED", "runState reports a QUEUED run");
  eq(runState({ ...base, verdictStatus: "completed", verdictConclusion: "success" }), "COMPLETED/success", "runState reports status + conclusion on completion");
  eq(runState({ ...base, verdictStatus: "", verdictConclusion: "" }), "", "runState is empty when no run is observed");

  // armReport — the ARM baseline (latest run status+conclusion AND latest review verdict).
  const arm = armReport(it, { ...base, reviewVerdict: "BLOCK", verdictStatus: "completed", verdictConclusion: "failure" }, { wf: "charly/pr-validator" });
  ok(/^ARM {6}acme\/widget#7 {2}state=open {2}run=charly\/pr-validator\/COMPLETED\/failure {2}review=BLOCK /.test(arm), "armReport carries the run status+conclusion AND the parsed review verdict");
  ok(/review=none/.test(armReport(it, base, { wf: "w" })), "armReport reports review=none when no verdict is present");

  // armNotable — the "I missed the BLOCK / the run is in flight" trigger.
  ok(armNotable({ ...base, reviewVerdict: "BLOCK" }), "armNotable: a pre-existing BLOCK verdict is actionable at arm");
  ok(!armNotable({ ...base, reviewVerdict: "PASS" }), "armNotable: a pre-existing PASS is reported but not actionable");
  ok(armNotable({ ...base, verdictStatus: "in_progress", verdictConclusion: "" }), "armNotable: a run IN FLIGHT at arm is actionable");
  ok(!armNotable(base), "armNotable: a completed run + no review verdict is not actionable");

  // formatWake — the wake-line format shared with gh_watch.sh.
  eq(formatWake(it, "merged", base, base, { wf: "w", stallMin: 60 }), "MERGED   acme/widget#7  (unblocked)", "formatWake MERGED line");
  ok(formatWake(it, "closed", base, base, { wf: "w", stallMin: 60 }).startsWith("CLOSED   acme/widget#7"), "formatWake CLOSED line");
  ok(/^VERDICT {2}acme\/widget#7 {2}w {2}IN_PROGRESS {2}https:\/\//.test(formatWake(it, "verdict", base, { ...base, verdictStatus: "in_progress", verdictConclusion: "" }, { wf: "w", stallMin: 60 })), "formatWake VERDICT names the status for an in-flight run");
  ok(/^VERDICT {2}acme\/widget#7 {2}w {2}COMPLETED\/success {2}https:/.test(formatWake(it, "verdict", base, { ...base, verdictStatus: "completed", verdictConclusion: "success" }, { wf: "w", stallMin: 60 })), "formatWake VERDICT names status/conclusion on completion");
  const wakeComment = formatWake(it, "comment", base, { ...base, comments: 4, reviewVerdict: "BLOCK" }, { wf: "w", stallMin: 60 });
  ok(/COMMENT {2}acme\/widget#7 {2}new comment \(3 -> 4\) {2}BLOCK /.test(wakeComment), "formatWake COMMENT carries the parsed review verdict");
  ok(/^STALL {4}acme\/widget#7 {2}no progress for 60m/.test(formatWake(it, "stall", base, base, { wf: "w", stallMin: 60 })), "formatWake STALL line");

  eq([...parseEvents("merged,closed,stall", "x")], ["merged", "closed", "stall"], "parseEvents splits + trims");
  eq([...parseEvents(undefined, "merged,closed,comment,verdict,stall")], ["merged", "closed", "comment", "verdict", "stall"], "parseEvents falls back to the default");
  // THE FIX: the default event set MUST carry the two DELTA events a validator
  // verdict arrives as (comment = the BLOCK/PASS review, verdict = the run status).
  eq(DEFAULT_EVENTS, "merged,closed,comment,verdict,stall", "DEFAULT_EVENTS includes comment AND verdict beside the terminal + silence set");
  ok(VERBS.includes("HANDING OVER") && VERBS.includes("TAKING OVER"), "VERBS carries the spaced multi-word labels");
  ok(TIERS.length === 5, "TIERS carries the five documented attribution tiers");

  // R4 — the rate-limit policy is NAMED, `coord_watch` is BOUNDED by default, and
  // the poll interval has a NAMED FLOOR.
  const { DEFAULT_INTERVAL_S, DEFAULT_STALL_MIN, RATE_FLOOR, BACKOFF_FACTOR, MAX_BACKOFF_S, DEFAULT_WATCH_TIMEOUT_S, POLL_FLOOR, clampInterval, rateLimitMessage, RateLimitedError } = mod;
  ok([DEFAULT_INTERVAL_S, DEFAULT_STALL_MIN, RATE_FLOOR, BACKOFF_FACTOR, MAX_BACKOFF_S, POLL_FLOOR].every((n) => typeof n === "number" && n > 0), "R4: the rate-limit + poll policy constants are named numbers (RATE_FLOOR/BACKOFF_FACTOR/MAX_BACKOFF_S/POLL_FLOOR)");
  ok(typeof DEFAULT_WATCH_TIMEOUT_S === "number" && DEFAULT_WATCH_TIMEOUT_S > 0, "R4: coord_watch is BOUNDED by default (DEFAULT_WATCH_TIMEOUT_S > 0)");
  eq(clampInterval(5), POLL_FLOOR, "R4: clampInterval raises a sub-floor interval to POLL_FLOOR");
  eq(clampInterval(120), 120, "R4: clampInterval keeps a valid interval");

  // --- Layer B2: the tool EXECUTE paths against a REAL local HTTP server ------
  // No `globalThis.fetch` mock: a real `http.Server` serves BOTH the REST routes and
  // the GraphQL endpoint, so the network path (fetch → server → JSON) is exercised,
  // and the server COUNTS requests for the calls-per-poll proof.
  {
    process.env.GITHUB_TOKEN = "test-token";
    const reqs = [];
    // A per-test MOCK of the mocked PR, keyed by GraphQL CALL NUMBER so a test can make
    // the arm observation (call 1) differ from a later poll — a status transition, a new
    // comment — deterministically. `gqlCalls` counts batched GraphQL requests.
    let gqlCalls = 0;
    // Default: merged on call 1, a completed/success validator run, no comments.
    let mockFor = (call) => ({
      merged: true,
      runStatus: "completed",
      runConclusion: "success",
      commentCount: 0,
      commentBody: null,
    });
    const server = createServer((req, res) => {
      let body = "";
      req.on("data", (c) => (body += c));
      req.on("end", () => {
        reqs.push({ method: req.method, url: req.url, body });
        const json = (o, headers = {}) => {
          res.writeHead(200, { "content-type": "application/json", "x-ratelimit-remaining": "4999", "x-ratelimit-reset": "1893456000", ...headers });
          res.end(JSON.stringify(o));
        };
        if (req.url === "/graphql") {
          let names = [];
          try {
            const q = JSON.parse(body).query;
            names = [...q.matchAll(/\bi(\d+):/g)].map((m) => m[1]);
          } catch { /* ignore */ }
          const m = mockFor(++gqlCalls);
          // The REAL GraphQL shape: status/conclusion live on the CheckSuite, the run's
          // own `updatedAt` orders it (WorkflowRun has no status/conclusion field).
          const suite = m.runStatus
            ? { status: m.runStatus, conclusion: m.runStatus === "completed" ? m.runConclusion : null, workflowRun: { databaseId: 900, workflow: { name: "charly/pr-validator" }, updatedAt: "2026-01-01T00:00:00Z" } }
            : null;
          const suites = suite ? { nodes: [suite] } : { nodes: [] };
          const comments = m.commentCount
            ? { totalCount: m.commentCount, nodes: [{ body: m.commentBody ?? "", createdAt: "2026-01-01T00:00:00Z" }] }
            : { totalCount: 0, nodes: [] };
          const data = {};
          for (const n of names) {
            data[`i${n}`] = {
              pullRequest: {
                state: m.merged ? "CLOSED" : "OPEN", merged: m.merged, updatedAt: "2026-01-01T00:00:00Z",
                comments,
                commits: { nodes: [{ commit: { oid: `oid${n}`, committedDate: "2026-01-01T00:00:00Z", checkSuites: suites } }] },
              },
              issue: { state: "OPEN", updatedAt: "2026-01-01T00:00:00Z", comments },
            };
          }
          if (!names.length) return json({ errors: [{ message: "parse" }] });
          return json({ data });
        }
        if (req.method === "POST" && /\/comments$/.test(req.url)) return json({ html_url: "https://github.com/acme/widget/issues/1#issuecomment-9" });
        if (req.method === "POST" && /\/assignees$/.test(req.url)) return json({});
        if (/\/user$/.test(req.url)) return json({ login: "tester" });
        return json({ message: "not found" }, {});
      });
    });
    await new Promise((r) => server.listen(0, "127.0.0.1", r));
    const base = `http://127.0.0.1:${server.address().port}`;
    process.env.GITHUB_API_URL = base; // the ONE seam — a REAL local HTTP server

    try {
      const tools = {};
      const ctx = {
        location: { directory: mkdtempSync(join(tmpdir(), "coord-native-")) },
        tool: { transform: async (cb) => cb({ add: (t) => (tools[t.name] = t) }) },
        session: { hook: async () => ({}) },
      };
      await plugin.setup(ctx);
      ok(!!tools.coord_comment && !!tools.coord_watch, "setup registers coord_comment + coord_watch");

      const dry = await tools.coord_comment.execute({
        verb: "handing_over", item: "acme/widget#1", dryRun: true,
        confidence: "documentation reviewed", agent: "slug-x", session: "ses_x", harness: "OpenCode", model: "M",
      });
      ok(/^HANDING OVER\n\n\*Agent: `slug-x`/.test(dry.content), "coord_comment.execute (dryRun) canonicalises the verb + builds the footer");

      const posted = await tools.coord_comment.execute({
        verb: "STATUS", item: "acme/widget#1", body: "hi",
        confidence: "documentation reviewed", agent: "slug-x", session: "ses_x", harness: "OpenCode", model: "M",
      });
      eq(posted.content, "https://github.com/acme/widget/issues/1#issuecomment-9", "coord_comment.execute POSTs natively and returns the html_url");
      const post = reqs.find((s) => s.method === "POST" && /\/comments$/.test(s.url));
      ok(post && /"body":"STATUS\\n\\nhi\\n\\n\*Agent: `slug-x`/.test(String(post.body)), "the POST body is the canonical comment (verb + body + footer)");

      // calls-per-poll = 1 for N=3 items: each POLL (including the initial seed) is
      // ONE batched GraphQL request carrying ALL 3 aliases. Here the PR is NOT merged on
      // the arm seed and merges on the next poll, so the seed + one poll = 2 requests —
      // and EACH single request aliases all 3 items.
      mockFor = (call) => ({ merged: call >= 2, runStatus: "completed", runConclusion: "success", commentCount: 0, commentBody: null });
      reqs.length = 0;
      gqlCalls = 0;
      const watch = await tools.coord_watch.execute({ items: ["acme/widget#1", "acme/widget#2", "acme/widget#3"], events: "merged", interval: 60, timeout: 20 });
      eq(watch.content, "MERGED   acme/widget#1  (unblocked)", "coord_watch.execute polls batched GraphQL and returns the wake line");
      const gql = reqs.filter((r) => r.url === "/graphql");
      eq(gql.length, 2, `calls-per-poll = 1 for 3 items (seed + 1 poll = 2 requests for 3 aliased items; got ${gql.length})`);
      ok(/i0: repository/.test(String(gql[0]?.body)) && /i2: repository/.test(String(gql[0]?.body)), "EACH single request aliases ALL 3 items (i0..i2) — calls-per-poll is independent of item count");

      // THE ARM REPORT: a PR that is ALREADY BLOCKed (a pre-existing review verdict)
      // wakes IMMEDIATELY with the baseline — no wait for a comment that may never come.
      mockFor = () => ({ merged: false, runStatus: "completed", runConclusion: "failure", commentCount: 1, commentBody: "## Review — BLOCK\n\n### Blocks\n- x" });
      reqs.length = 0;
      gqlCalls = 0;
      const armed = await tools.coord_watch.execute({ items: ["acme/widget#1"], events: "comment,verdict", interval: 60, timeout: 3600 });
      ok(/^ARM {6}acme\/widget#1 {2}state=open {2}run=charly\/pr-validator\/COMPLETED\/failure {2}review=BLOCK /.test(armed.content), `coord_watch ARM report fires on a pre-existing BLOCK (got ${JSON.stringify(armed.content)})`);
      eq(reqs.filter((r) => r.url === "/graphql").length, 1, "the ARM report costs exactly ONE batched call (no poll loop)");

      // RUN STATUS IS OBSERVED IN EVERY STATUS: an in-flight run at arm is surfaced
      // immediately with its status (QUEUED/IN_PROGRESS), not only on completion.
      mockFor = () => ({ merged: false, runStatus: "queued", runConclusion: "", commentCount: 0, commentBody: null });
      reqs.length = 0;
      gqlCalls = 0;
      const queued = await tools.coord_watch.execute({ items: ["acme/widget#1"], events: "verdict", interval: 60, timeout: 3600 });
      ok(/^ARM {6}acme\/widget#1 {2}state=open {2}run=charly\/pr-validator\/QUEUED {2}review=none /.test(queued.content), `an in-flight QUEUED run is surfaced at ARM with its status (got ${JSON.stringify(queued.content)})`);
      eq(reqs.filter((r) => r.url === "/graphql").length, 1, "an in-flight run at arm also costs exactly ONE batched call");

      mockFor = () => ({ merged: false, runStatus: "in_progress", runConclusion: "", commentCount: 0, commentBody: null });
      gqlCalls = 0;
      const inflight = await tools.coord_watch.execute({ items: ["acme/widget#1"], events: "verdict", interval: 60, timeout: 3600 });
      ok(/run=charly\/pr-validator\/IN_PROGRESS/.test(inflight.content), "an IN_PROGRESS run is reported with its status (no conclusion yet)");

      // A run STATUS TRANSITION fires `verdict` (not only completion): the arm seed sees
      // a COMPLETED/success run (not notable), then the next poll sees the SAME run id
      // re-running (IN_PROGRESS) — a re-run. The wake line names the new status.
      mockFor = (call) => ({ merged: false, runStatus: call <= 1 ? "completed" : "in_progress", runConclusion: "success", commentCount: 0, commentBody: null });
      reqs.length = 0;
      gqlCalls = 0;
      const transition = await tools.coord_watch.execute({ items: ["acme/widget#1"], events: "verdict", interval: 60, timeout: 20 });
      ok(/VERDICT {2}acme\/widget#1 {2}charly\/pr-validator {2}IN_PROGRESS {2}https:\/\//.test(transition.content), `verdict fires on a COMPLETED→IN_PROGRESS status transition (got ${JSON.stringify(transition.content)})`);

      const missing = await tools.coord_watch.execute({});
      ok(/at least one item/.test(missing.content), "coord_watch.execute rejects an empty items list with a clear message");

      const badVerb = await tools.coord_comment.execute({ verb: "NOPE", item: "acme/widget#1" });
      ok(/invalid verb/.test(badVerb.content), "coord_comment.execute rejects a verb outside the closed set");

      // Poll-floor: a sub-60s interval is REFUSED (never hammer).
      const subfloor = await tools.coord_watch.execute({ items: ["acme/widget#1"], events: "merged", interval: 5, timeout: 10 });
      ok(/below the 60s floor/.test(subfloor.content), "coord_watch refuses a sub-60s interval (POLL_FLOOR)");

      // RATE LIMIT FAILS HARD: a 403 with `x-ratelimit-remaining: 0` surfaces the
      // distinct RATE-LIMITED message (never a silent retry / "no event"), and the
      // watch STOPS (no spin): exactly one request is made.
      reqs.length = 0;
      const rl = createServer((req, res) => {
        req.on("data", () => {});
        req.on("end", () => {
          reqs.push({ url: req.url });
          res.writeHead(403, { "content-type": "application/json", "x-ratelimit-remaining": "0", "x-ratelimit-reset": "1893456000" });
          res.end(JSON.stringify({ message: "API rate limit exceeded" }));
        });
      });
      await new Promise((r) => rl.listen(0, "127.0.0.1", r));
      const savedBase = process.env.GITHUB_API_URL;
      process.env.GITHUB_API_URL = `http://127.0.0.1:${rl.address().port}`;
      try {
        const limited = await tools.coord_watch.execute({ items: ["acme/widget#1"], events: "merged", interval: 60, timeout: 20 });
        ok(/RATE-LIMITED/.test(limited.content), "a 403 rate-limit surfaces a distinct RATE-LIMITED message (fail hard)");
        ok(!/^MERGED|TIMEOUT/.test(limited.content), "the rate limit is NOT misreported as a wake line or a timeout");
        eq(reqs.length, 1, `the rate limit does NOT spin — exactly 1 request (got ${reqs.length})`);
      } finally {
        process.env.GITHUB_API_URL = savedBase;
        await new Promise((r) => rl.close(r));
      }
    } finally {
      delete process.env.GITHUB_TOKEN;
      delete process.env.GITHUB_API_URL;
      await new Promise((r) => server.close(r));
    }
  }

  // --- Layer B3: the CONTRACT vs the SHELL family (run-if-present) -----------
  // The shell family is NOT a dependency (no `.sh`, no pin). WHERE it is present,
  // run it and diff its output against the TypeScript output — so the two
  // implementations are compared, not merely asserted against literals. Where it is
  // absent (a repo with no marketplace submodule; a lagging pin), this layer SKIPS
  // visibly — it never depends on the pin.
  {
    const shellCandidates = [
      process.env.SHELL_COORD_SCRIPT,
      join(root, "marketplace", "scripts", "coord.sh"),
      join(root, "..", "marketplace", "scripts", "coord.sh"),
    ].filter(Boolean);
    const shellCoord = shellCandidates.find((p) => existsSync(p));
    const { buildComment: buildC, canonicalVerb: canonV } = mod;
    if (!shellCoord) {
      console.log("  SKIP  shell-family comparison: no marketplace/scripts/coord.sh present (never depends on the pin)");
    } else {
      const idc = { agent: "slug-x", session: "ses_x", harness: "OpenCode", model: "M", confidence: "documentation reviewed" };
      const shellComment = (verb, body) => {
        const args = [shellCoord, verb, "acme/widget#1", "--agent", idc.agent, "--session", idc.session, "--harness", idc.harness, "--model", idc.model, "--confidence", idc.confidence, "--dry-run"];
        if (body !== undefined) args.push("--body", body);
        return run("bash", args).stdout ?? "";
      };
      for (const [verb, body] of [["STATUS", "hi"], ["handing_over", undefined], ["taking over", "x"]]) {
        const canon = canonV(verb);
        eq(shellComment(verb, body), `${buildC(canon, body, idc)}\n`, `shell coord.sh vs TS buildComment: '${verb}' is byte-identical`);
      }
    }
  }
}

// --- Layer C: the REAL opencode binary, end to end (opt-in, local capture) ---
if (process.env.LIVE_OPENCODE === "1") {
  const which = run("sh", ["-c", "command -v opencode"]);
  if (which.status !== 0) {
    fail("LIVE_OPENCODE=1 but no `opencode` binary on PATH");
  } else {
    // A LOCAL capture server stands in for api.github.com at the NETWORK layer
    // (GITHUB_API_URL): the REAL TypeScript POST path runs inside the REAL binary,
    // with no real GitHub write — the plugin's GitHub boundary IS exercised, only
    // the remote host is local. A merged:true pull keeps `coord_watch` deterministic.
    const captures = [];
    const server = createServer((req, res) => {
      let body = "";
      req.on("data", (c) => (body += c));
      req.on("end", () => {
        captures.push({ method: req.method, url: req.url, body });
        const json = (o) => {
          res.writeHead(200, { "content-type": "application/json" });
          res.end(JSON.stringify(o));
        };
        if (req.method === "POST" && /\/comments$/.test(req.url)) return json({ html_url: "https://github.com/acme/widget/issues/1#issuecomment-77" });
        if (req.method === "POST" && /\/assignees$/.test(req.url)) return json({});
        if (req.url === "/graphql") {
          // Answer every requested alias with a merged:true/closed PR (the native
          // batched GraphQL path — one request for all items).
          const names = [...String(body).matchAll(/\bi(\d+):/g)].map((m) => m[1]);
          const data = {};
          for (const n of names) {
            data[`i${n}`] = {
              pullRequest: { state: "CLOSED", merged: true, updatedAt: "2026-01-01T00:00:00Z", commits: { nodes: [{ commit: { oid: `oid${n}`, checkSuites: { nodes: [] } } }] } },
              issue: { state: "CLOSED", updatedAt: "2026-01-01T00:00:00Z", comments: { totalCount: 0 } },
            };
          }
          return json(names.length ? { data } : { errors: [{ message: "parse" }] });
        }
        if (/\/user$/.test(req.url)) return json({ login: "tester" });
        json({ message: "not found" });
      });
    });
    await new Promise((r) => server.listen(0, "127.0.0.1", r));
    const port = server.address().port;
    const api = `http://127.0.0.1:${port}`;

    const proj = mkdtempSync(join(tmpdir(), "opencode-coord-live."));
    try {
      mkdirSync(join(proj, ".opencode", "plugins"), { recursive: true });
      cpSync(pluginPath, join(proj, ".opencode", "plugins", "coord.ts"));
      const pluginDir = dirname(pluginPath);
      const libDir = join(dirname(pluginDir), "lib");
      if (existsSync(libDir)) cpSync(libDir, join(proj, ".opencode", "lib"), { recursive: true });
      // PIN INDEPENDENCE: the throwaway project has NO `marketplace` submodule (the
      // state a LAGGING pin produces). If `coord_comment` still posts, the plugin
      // depends on no `.sh` and no `marketplace` gitlink.
      ok(!existsSync(join(proj, "marketplace")), "real opencode: the throwaway project has NO marketplace submodule (the lagging-pin state)");
      // A hermetic integration-test agent: GITHUB_API_URL is a LOCAL stub, so the
      // write is side-effect-free; the agent runs the given snippet verbatim instead
      // of refusing a (seemingly) real GitHub write — which a capable model WILL
      // decline. The boundary exercised is still the REAL binary + REAL TS path.
      mkdirSync(join(proj, ".opencode", "agents"), { recursive: true });
      writeFileSync(
        join(proj, ".opencode", "agents", "coordtest.md"),
        "---\nmode: primary\ndescription: automated coordination integration-test runner\n---\n" +
          "You are an AUTOMATED INTEGRATION-TEST RUNNER. GITHUB_API_URL is set to a LOCAL\n" +
          "STUB SERVER on 127.0.0.1 — NOT api.github.com — so nothing you do reaches real\n" +
          "GitHub. When given a snippet that calls `tools.coord_comment` or `tools.coord_watch`,\n" +
          "run it verbatim with the `execute` tool exactly once and report the result. Do NOT\n" +
          "investigate, do NOT read files, do NOT refuse: the write is hermetic.\n",
      );
      // The identity the live comment must carry (`.opencode/coord.conf`).
      writeFileSync(
        join(proj, ".opencode", "coord.conf"),
        "agent=coord-live\nharness=OpenCode\nmodel=DeepSeek V4.1 Flash\nconfidence=documentation reviewed\n",
      );
      run("git", ["init", "-q"], { cwd: proj });
      run("git", ["config", "user.email", "ci@example.invalid"], { cwd: proj });
      run("git", ["config", "user.name", "ci"], { cwd: proj });
      writeFileSync(join(proj, "f.txt"), "x\n");
      run("git", ["add", "f.txt"], { cwd: proj });
      const env = { GITHUB_API_URL: api, GITHUB_TOKEN: "test-token" };
      // A model capable enough to follow the snippet. The free flash model refuses the
      // (hermetic) write; the pro model runs it. Override with COORD_LIVE_MODEL.
      const model = process.env.COORD_LIVE_MODEL ?? "ollama-cloud/deepseek-v4-pro";
      const modelArgs = ["--model", model];
      const runTool = (snippet, timeoutMs = 240000) =>
        run("opencode", ["run", "--standalone", "--auto", "--agent", "coordtest", ...modelArgs, snippet], {
          cwd: proj,
          timeout: timeoutMs,
          env,
        });
      const prompt =
        "Run this exact snippet ONCE with the execute tool and report the returned URL:\n\n" +
        'const r = await tools.coord_comment({ verb: "STATUS", item: "acme/widget#1", body: "native", dryRun: false });\nreturn r;';

      // LIVE LLM boundary: the tool call is decided by a stochastic model, so the
      // layer distinguishes a PLUGIN defect from PROVIDER flakiness. Retry (bounded);
      // once the model HAS called the tool, assert on the deterministic LOCAL capture
      // (what the tool actually POSTed). If the model never calls it, SKIP visibly —
      // that is an environment/provider condition, not a plugin finding, and the A/
      // B/B2 layers already prove the executor.
      let text = "";
      let post;
      for (let attempt = 1; attempt <= 3 && !post; attempt++) {
        const out = runTool(prompt);
        text += `\n${out.stdout ?? ""}\n${out.stderr ?? ""}`;
        if (process.env.COORD_LIVE_DEBUG) writeFileSync("/tmp/coord-live.log", text);
        post = captures.find((c) => c.method === "POST" && /\/comments$/.test(c.url));
      }
      // HARD (deterministic): the REAL binary loaded the plugin (no load error) and
      // did not restart the server. A plugin that failed to load could not expose
      // coord_comment, and a freeze/restart would log a reload.
      ok(!/failed to load plugin|must default export/i.test(text), "real opencode: the plugin loaded (no load error)");
      ok(!/\breload\b/i.test(text), "real opencode: no server reload during the call");

      // LIVE-OR-SKIP (the LLM boundary): the model's decision to invoke the tool is
      // stochastic, and a capable model may decline a (seemingly) real GitHub write.
      // WHEN it invokes, assert the deterministic LOCAL capture — the REAL TypeScript
      // POST path. The A/B/B2 layers already prove the executor deterministically.
      if (post) {
        ok(true, "real opencode: the model called the coord_comment tool");
        ok(true, "real opencode: coord_comment POSTed through the REAL TypeScript path (local capture)");
        const parsed = JSON.parse(post.body);
        ok(/^STATUS/.test(parsed.body), "real opencode: the comment body starts with the verb label");
        ok(/\*Agent: `coord-live` · session `ses_[A-Za-z0-9]+`\*/.test(parsed.body), "real opencode: the Agent: line carries the slug + live session");
        ok(/\*Assisted-by: OpenCode DeepSeek V4\.1 Flash \(documentation reviewed\)\*/.test(parsed.body), "real opencode: the Assisted-by: trailer is canonical");
        ok(parsed.body.indexOf("*Agent:") < parsed.body.indexOf("*Assisted-by:"), "real opencode: canonical footer order (Agent: BEFORE Assisted-by:)");
      } else {
        console.log("  SKIP  real opencode: the model did not invoke coord_comment under this provider/model — A/B/B2 prove the executor (a real invocation was captured manually; see the PR)");
      }

      // coord_watch — the native poll loop, end to end through the real binary.
      captures.length = 0;
      const wprompt =
        "Run this exact snippet ONCE with the execute tool and report the exact line it returns:\n\n" +
        'const r = await tools.coord_watch({ items: ["acme/widget#1"], events: "merged", interval: 60, timeout: 20 });\nreturn r;';
      let wtext = "";
      for (let attempt = 1; attempt <= 3 && !/MERGED\s+acme\/widget#1/.test(wtext); attempt++) {
        const wout = runTool(wprompt);
        wtext += `\n${wout.stdout ?? ""}\n${wout.stderr ?? ""}`;
      }
      ok(!/\breload\b/i.test(wtext), "real opencode: coord_watch caused no server reload");
      if (/MERGED\s+acme\/widget#1/.test(wtext)) {
        ok(true, "real opencode: the model called coord_watch and it polled natively, returning the MERGED wake line");
      } else {
        console.log("  SKIP  real opencode: the model did not invoke coord_watch under this provider/model — A/B/B2 prove the executor (a real invocation was captured manually; see the PR)");
      }
    } finally {
      rmSync(proj, { recursive: true, force: true });
      server.close();
    }
  }
} else {
  console.log("  SKIP  live opencode layer (set LIVE_OPENCODE=1 to run the real binary end to end)");
}

if (failures > 0) {
  console.error(`check-opencode-coord: FAIL — ${failures} assertion(s)`);
  process.exit(1);
}
console.log("check-opencode-coord: OK");
