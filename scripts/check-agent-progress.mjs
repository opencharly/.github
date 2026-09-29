#!/usr/bin/env node
// check-agent-progress.mjs — regression gate for `.opencode/plugins/agent-progress.ts`.
//
// The agent-progress monitor is PURE TypeScript (operator directive; see
// opencharly/opencharly#302): it reads the opencode store READ-ONLY and NEVER
// delegates to a `.sh`, so it loads its code AND its data path from the SAME ref
// with NO `marketplace` submodule pin. This gate has THREE jobs:
//
//   (A) STATIC — the plugin (comments stripped) contains NO `.sh` reference, NO
//       `spawnSync`, NO `Bun.spawn`; it opens the store READ-ONLY (`readonly: true` /
//       `readOnly: true`); and it resolves the documented DB path.
//   (B) UNIT   — the CLASSIFIER, given a synthetic transcript, returns
//       WORKING / IDLE / LOOP / DONE correctly. The RCA REGRESSION this gate pins:
//       a turn-count-heavy-but-working transcript must be WORKING, NOT stalled — a
//       "message" is an assistant TURN, never a progress signal.
//   (C) LIVE   — `LIVE_OPENCODE=1` drives the REAL `opencode` binary against the REAL
//       store and calls the `agent_progress` tool. Live-or-skip, visibly: a missing
//       binary or a model that declines to call the tool SKIPS (never a silent pass).
//
// No stub of the opencode boundary in A/B; the C layer runs the real binary.

import { spawnSync } from "node:child_process";
import {
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

const pluginPath = resolve(root, arg("--plugin", ".opencode/plugins/agent-progress.ts"));

let failures = 0;
const pass = (m) => console.log(`  PASS  ${m}`);
const fail = (m) => {
  failures += 1;
  console.error(`  FAIL  ${m}`);
};
const ok = (cond, m) => (cond ? pass(m) : fail(m));
const eq = (a, b, m) => ok(JSON.stringify(a) === JSON.stringify(b), `${m} (got ${JSON.stringify(a)})`);

function run(cmd, args, opts = {}) {
  // opencode resolves its working location from the inherited PWD env var, not the
  // process cwd; keep them in lockstep (measured in check-opencode-plugin.mjs).
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

// --- Layer A: STATIC — no shell delegation, read-only store, known path ------
console.log(`check-agent-progress: ${pluginPath}`);
{
  const code = stripComments(readFileSync(pluginPath, "utf8"));
  const rel = pluginPath.slice(root.length + 1);
  ok(!/spawnSync/.test(code), `${rel}: contains NO spawnSync`);
  ok(!/Bun\.spawn/.test(code), `${rel}: contains NO Bun.spawn`);
  ok(!/\.sh\b/.test(code), `${rel}: contains NO .sh reference (no shell delegation)`);
  ok(!/execFile\(\s*["']bash/.test(code), `${rel}: no bash execFile`);
  ok(/readonly:\s*true/.test(code) && /readOnly:\s*true/.test(code), `${rel}: opens the store READ-ONLY under BOTH drivers`);
  ok(/bun:sqlite/.test(code) && /node:sqlite/.test(code), `${rel}: resolves bun:sqlite (shipped) and node:sqlite (node) drivers`);
  ok(/opencode\.db/.test(code), `${rel}: resolves the documented opencode store path`);
}

// --- Layer B: UNIT — the classifier (no opencode, no database) ---------------
let mod;
try {
  mod = await import(pathToFileURL(pluginPath).href);
} catch (err) {
  fail(`plugin did not import: ${err.message}`);
}
if (mod) {
  // A: the real plugin module is a V2 definition with BOTH loader entry points.
  const plugin = mod.default;
  ok(
    plugin !== null && typeof plugin === "object" && !Array.isArray(plugin),
    "default export is a definition object (V2), not a V1 function",
  );
  const hasSetup = typeof plugin?.setup === "function";
  const hasServer = typeof plugin?.server === "function";
  ok(hasSetup && hasServer, `definition exposes BOTH setup() (>=2.0) and server() (1.x) [setup=${hasSetup} server=${hasServer}]`);
  ok(typeof plugin?.id === "string" && plugin.id.length > 0, "definition has a string id");
  eq(mod.PLUGIN_ID, "agent-progress", "PLUGIN_ID is stable");

  const {
    analyzeSession,
    classify,
    detectLoop,
    extractArtifacts,
    normalizeInput,
    databasePath,
    formatDuration,
    formatReport,
    topTools,
    VERDICTS,
    DEFAULT_WINDOW_MIN,
    ARTIFACT_TAIL,
    LOOP_REPEATS,
    LOOP_TAIL,
  } = mod;

  ok(VERDICTS.length === 4 && VERDICTS.includes("WORKING") && VERDICTS.includes("IDLE") && VERDICTS.includes("LOOP") && VERDICTS.includes("DONE"), "VERDICTS is the closed set WORKING/IDLE/LOOP/DONE");
  ok([DEFAULT_WINDOW_MIN, ARTIFACT_TAIL, LOOP_REPEATS, LOOP_TAIL].every((n) => typeof n === "number" && n > 0), "the policy constants are named numbers (window / artifact-tail / loop)");

  // The path resolver honours the documented precedence.
  eq(
    databasePath({ HOME: "/home/u" }),
    join("/home/u", ".local", "share", "opencode", "opencode.db"),
    "databasePath falls back to ~/.local/share/opencode/opencode.db",
  );
  eq(
    databasePath({ HOME: "/home/u", XDG_DATA_HOME: "/data" }),
    join("/data", "opencode", "opencode.db"),
    "databasePath honours $XDG_DATA_HOME",
  );
  eq(databasePath({ OPENCODE_DB: "/tmp/x.db", HOME: "/home/u" }), "/tmp/x.db", "databasePath honours OPENCODE_DB");

  eq(formatDuration(45_000), "45s", "formatDuration renders seconds");
  eq(formatDuration(12 * 60_000), "12m", "formatDuration renders minutes");
  eq(normalizeInput("shell", { command: "git  status\n  --short" }), "git status --short", "normalizeInput collapses shell whitespace (loop key)");
  eq(normalizeInput("edit", { path: "/a/b.ts" }), "/a/b.ts", "normalizeInput keys a path tool on its path");
  eq(
    mod.parseModel('{"id":"deepseek-v4.1-flash","providerID":"ollama-cloud","variant":"high"}'),
    "ollama-cloud/deepseek-v4.1-flash",
    "parseModel renders provider/model from the store's JSON model column",
  );
  eq(mod.parseModel("plain-model"), "plain-model", "parseModel degrades a plain string");
  eq(mod.parseModel(null), "", "parseModel tolerates a null model");

  // Artifact hints.
  const arts = extractArtifacts(
    "opened opencharly/opencharly#308, `gh pr merge 308`, merged it, tagged v2026.272.0610 and pushed",
  );
  ok(arts.includes("opencharly/opencharly#308"), "extractArtifacts surfaces owner/repo#N");
  ok(arts.includes("gh pr merge"), "extractArtifacts surfaces `gh pr merge`");
  ok(arts.includes("v2026.272.0610"), "extractArtifacts surfaces a CalVer tag");
  ok(arts.includes("pushed"), "extractArtifacts surfaces `pushed`");
  eq([...new Set(arts)].length, arts.length, "extractArtifacts dedupes");

  // detectLoop — the same (tool+input) repeated inside the trailing window.
  const mkCall = (name, key, status = "completed", turn = 0, time = 0) => ({ name, key, status, turn, time });
  ok(!detectLoop([]).isLoop, "detectLoop: empty is not a loop");
  ok(
    !detectLoop([mkCall("shell", "ls"), mkCall("read", "/a"), mkCall("shell", "ls"), mkCall("read", "/a"), mkCall("shell", "ls")]).isLoop,
    "detectLoop: 3 repeats of two alternating actions is NOT a loop (below the threshold)",
  );
  const looped = detectLoop([
    mkCall("shell", "npm test", "error"),
    mkCall("shell", "npm test", "error"),
    mkCall("shell", "npm test", "error"),
    mkCall("shell", "npm test", "error"),
  ]);
  ok(looped.isLoop && looped.count === 4 && looped.tool === "shell" && looped.errors === 4, "detectLoop: 4× the same failing shell call IS a loop (count + errored)");

  // Fixture builders — the transcript shape the real store holds.
  const now = 1_800_000_000_000;
  const minsAgo = (m) => now - m * 60_000;
  const tool = (name, input, status = "completed") => ({ type: "tool", name, state: { status, input } });
  const text = (t) => ({ type: "text", text: t });
  const reasoning = (t) => ({ type: "reasoning", text: t });
  const assistant = (min, content, finish = "tool-calls") => {
    const t = minsAgo(min);
    return { type: "assistant", time_created: t, data: { time: { created: t }, finish, content } };
  };
  const user = (min, t) => ({ type: "user", time_created: minsAgo(min), data: { time: { created: minsAgo(min) }, text: t } });
  const session = { id: "ses_test", slug: "test", title: "fixture", parent_id: null, agent: "general", model: "m", idle_outcome: null };
  const classifyFixture = (messages, windowMin = 15) =>
    analyzeSession(session, messages, { now, windowMin }).verdict;

  // ── THE RCA REGRESSION ────────────────────────────────────────────────────
  // A turn-count-heavy-but-working transcript (74 assistant turns, tools firing
  // every turn, the last turn 1m ago) MUST be WORKING — the exact session that was
  // wrongly rotated for "79 messages / no artifact". Counting turns would call this
  // a stall; reading the transcript shows cadence.
  {
    const heavy = [];
    for (let i = 0; i < 74; i++) {
      heavy.push(assistant(40 - Math.floor(i / 2), [reasoning(`step ${i}`), tool("shell", `echo ${i}`), tool("read", "/x.ts")]));
    }
    heavy.push(assistant(1, [text("still working — measuring the bed output")]));
    const a = analyzeSession(session, heavy, { now, windowMin: 15 });
    eq(a.verdict, "WORKING", "RCA REGRESSION: a 74-turn, tool-heavy, recent transcript is WORKING (not stalled)");
    ok(a.turns === 75, "RCA REGRESSION: the report counts all 75 assistant TURNS (the count is shown, never used as a stall signal)");
    ok(a.toolCalls === 148, "RCA REGRESSION: the tool mix is surfaced (cadence evidence)");
    ok(a.lastTool && a.lastTool.name === "read", "RCA REGRESSION: the LAST tool + its input are surfaced");
  }

  // WORKING — recent turns with steady tool cadence.
  eq(
    classifyFixture([
      user(20, "do the thing"),
      assistant(6, [reasoning("planning"), tool("shell", "git status")]),
      assistant(4, [tool("edit", { path: "/a.ts" }), tool("shell", "pytest -q")]),
      assistant(2, [text("running the gate now")]),
    ]),
    "WORKING",
    "classify: recent turns + tool cadence ⇒ WORKING",
  );

  // WORKING — a fresh user input with no turn yet is a just-dispatched worker, not idle.
  eq(
    classifyFixture([user(30, "old"), assistant(25, [text("done")]), user(2, "next task, go")]),
    "WORKING",
    "classify: a fresh input with no turn yet ⇒ WORKING (just dispatched)",
  );

  // IDLE — no turns past the window and no artifact.
  eq(
    classifyFixture([
      user(120, "do the thing"),
      assistant(90, [reasoning("planning"), tool("read", "/a.ts")]),
    ]),
    "IDLE",
    "classify: no turns > 15m and no artifact ⇒ IDLE",
  );

  // DONE with the opencode idle_outcome surfaced (the run's own terminal marker).
  {
    const a = analyzeSession(
      { ...session, idle_outcome: "succeeded" },
      [user(120, "x"), assistant(90, [text("finished the report")], "stop")],
      { now, windowMin: 15 },
    );
    eq(a.verdict, "DONE", "classify: quiet with a final report and no pending action ⇒ DONE");
    ok(a.idleOutcome === "succeeded", "classify: surfaces the opencode idle_outcome");
  }

  // LOOP — the same tool+input repeated, no artifact.
  eq(
    classifyFixture([
      user(20, "fix it"),
      assistant(10, [tool("shell", "npm test", "error")]),
      assistant(9, [tool("shell", "npm test", "error")]),
      assistant(8, [tool("shell", "npm test", "error")]),
      assistant(7, [tool("shell", "npm test", "error")]),
    ]),
    "LOOP",
    "classify: the same failing tool+input repeated with no artifact ⇒ LOOP",
  );

  // LOOP with NO artifact is not cleared by a fresh user turn: recent ⇒ still LOOP.
  {
    const loop = detectLoop(
      Array.from({ length: LOOP_TAIL }, () => mkCall("shell", "same", "error")),
    );
    ok(loop.isLoop, "detectLoop: a full trailing window of the same call is a loop");
  }

  // DONE — a final report (`finish=stop`), no pending action, quiet past the window.
  eq(
    classifyFixture([
      user(60, "land it"),
      assistant(40, [tool("shell", "gh pr merge 1")]),
      assistant(35, [text("PR merged; report follows below"), text("done")], "stop"),
    ]),
    "DONE",
    "classify: quiet past the window with a final report + an artifact ⇒ DONE",
  );

  // DONE is NOT reached while an action is still pending (a running tool).
  {
    const a = analyzeSession(
      session,
      [
        user(60, "land it"),
        assistant(40, [tool("shell", "sleep 9999", "running")], "tool-calls"),
        assistant(35, [text("about to merge")], "stop"),
      ],
      { now, windowMin: 15 },
    );
    eq(a.verdict, "IDLE", "classify: a pending (running) tool blocks DONE ⇒ IDLE");
  }

  // The artifact signal flips a stale LOOP to DONE only when an artifact lands.
  eq(
    classifyFixture([
      user(60, "work"),
      assistant(40, [tool("shell", "gh pr merge 7")]),
      assistant(35, [text("merged opencharly/opencharly#7")], "stop"),
    ]),
    "DONE",
    "classify: a recent artifact + a final report ⇒ DONE",
  );

  // Empty session, fresh dispatch.
  eq(classifyFixture([user(1, "go")]), "WORKING", "classify: an empty session with a fresh input ⇒ WORKING");
  // Empty session, nothing recent.
  eq(classifyFixture([user(60, "go")]), "IDLE", "classify: an empty session, quiet ⇒ IDLE");

  // Re-briefs are surfaced (>2 orchestrator re-briefs of the SAME task is a rotate trigger).
  {
    const a = analyzeSession(
      session,
      [
        user(90, "same task"),
        user(80, "same task"),
        user(70, "same task"),
        assistant(60, [text("ok")], "stop"),
      ],
      { now, windowMin: 15 },
    );
    ok(a.repeatBriefs.length === 1 && /^3× /.test(a.repeatBriefs[0]), "analyzeSession surfaces repeated user briefs (the re-brief trigger)");
  }

  // The report renders every field the orchestrator needs.
  {
    const a = analyzeSession(session, [user(20, "x"), assistant(1, [text("hello"), tool("shell", "ls")])], { now });
    const report = formatReport([a], { db: "/tmp/x.db", driver: "node:sqlite", windowMin: 15 });
    for (const needle of ["ses_test", "turns 1", "shell×1", "last", "VERDICT  WORKING"]) {
      ok(report.includes(needle), `formatReport renders '${needle}'`);
    }
    ok(topTools({ shell: 3, read: 1 }) === "shell×3 read×1", "topTools orders by count");
  }

  // The tool execute path runs for real against a REAL database file we create.
  {
    const { DatabaseSync } = await import("node:sqlite");
    const dir = mkdtempSync(join(tmpdir(), "agent-progress-"));
    const dbPath = join(dir, "opencode.db");
    try {
      const db = new DatabaseSync(dbPath);
      db.exec(`
        CREATE TABLE session_v2 (
          id TEXT PRIMARY KEY, project_id TEXT, workspace_id TEXT, parent_id TEXT,
          slug TEXT, title TEXT, directory TEXT, agent TEXT, model TEXT,
          idle_outcome TEXT, time_created INTEGER, time_updated INTEGER
        );
        CREATE TABLE session_message (
          id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER,
          time_created INTEGER, data TEXT
        );
      `);
      const t0 = now - 3 * 60_000;
      db.prepare("INSERT INTO session_v2 (id,slug,title,parent_id,agent,model,idle_outcome,time_created,time_updated) VALUES (?,?,?,?,?,?,?,?,?)").run(
        "ses_live01", "live-fixture", "live fixture session", null, "general", "m", null, t0, now,
      );
      const ins = db.prepare("INSERT INTO session_message (id,session_id,type,seq,time_created,data) VALUES (?,?,?,?,?,?)");
      ins.run("m1", "ses_live01", "user", 1, t0, JSON.stringify({ time: { created: t0 }, text: "do it" }));
      ins.run("m2", "ses_live01", "assistant", 2, t0 + 1000, JSON.stringify({ time: { created: t0 + 1000 }, finish: "tool-calls", content: [{ type: "text", text: "on it" }, { type: "tool", name: "shell", state: { status: "completed", input: { command: "echo hi" } } }] }));
      ins.run("m3", "ses_live01", "assistant", 3, now - 60_000, JSON.stringify({ time: { created: now - 60_000 }, finish: "tool-calls", content: [{ type: "tool", name: "read", state: { status: "completed", input: { path: "/a.ts" } } }] }));
      db.close();

      const { content } = await mod.runProgress({ session: "ses_live01", windowMin: 15, db: dbPath });
      ok(/ses_live01/.test(content), "runProgress (single session): reads a REAL read-only database and reports the session");
      ok(/turns 2/.test(content), "runProgress: counts the assistant TURNS from the real store");
      ok(/VERDICT {2}WORKING/.test(content), "runProgress: the real transcript classifies WORKING");
      ok(/shell×1/.test(content) && /read×1/.test(content), "runProgress: surfaces the tool mix from the real store");
      ok(/`read`\(completed\): \/a\.ts/.test(content), "runProgress: surfaces the LAST tool + its input");

      const all = await mod.runProgress({ db: dbPath, sinceMin: 60, limit: 5 });
      ok(/ses_live01/.test(all.content), "runProgress (all): the recent session is listed");

      const missing = await mod.runProgress({ session: "ses_nope", db: dbPath });
      ok(/no session ses_nope/.test(missing.content), "runProgress: an unknown session fails CLEARLY (never fabricates)");

      const badPath = await mod.runProgress({ db: join(dir, "does-not-exist.db") });
      ok(/cannot open the opencode store read-only/.test(badPath.content), "runProgress: a missing store fails CLEARLY (never fabricates)");

      // The store is opened READ-ONLY: a write through the handle is refused by the driver.
      const handle = await mod.openReadonly(dbPath);
      let wrote = false;
      try {
        handle.all("INSERT INTO session_message (id,session_id,type,seq,time_created,data) VALUES ('x','ses_live01','user',9,1,'{}')");
        wrote = true;
      } catch {
        wrote = false;
      }
      ok(!wrote, `the store handle is READ-ONLY — a write is refused by ${handle.driver}`);
      handle.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
}

// --- Layer C: the REAL opencode binary, end to end (opt-in, live-or-skip) -----
if (process.env.LIVE_OPENCODE === "1") {
  const which = run("sh", ["-c", "command -v opencode"]);
  if (which.status !== 0) {
    fail("LIVE_OPENCODE=1 but no `opencode` binary on PATH");
  } else {
    const proj = mkdtempSync(join(tmpdir(), "agent-progress-live."));
    try {
      mkdirSync(join(proj, ".opencode", "plugins"), { recursive: true });
      writeFileSync(join(proj, ".opencode", "plugins", "agent-progress.ts"), readFileSync(pluginPath, "utf8"));
      writeFileSync(join(proj, "opencode.json"), JSON.stringify({ $schema: "https://opencode.ai/config.json" }));
      // The throwaway project has NO `marketplace` submodule (the lagging-pin state):
      // if agent_progress still reports, the plugin depends on no `.sh` and no pin.
      ok(!existsSync(join(proj, "marketplace")), "real opencode: the throwaway project has NO marketplace submodule (the lagging-pin state)");
      run("git", ["init", "-q"], { cwd: proj });
      run("git", ["config", "user.email", "ci@example.invalid"], { cwd: proj });
      run("git", ["config", "user.name", "ci"], { cwd: proj });
      writeFileSync(join(proj, "f.txt"), "x\n");
      run("git", ["add", "f.txt"], { cwd: proj });

      const model = process.env.AGENT_PROGRESS_LIVE_MODEL ?? "ollama-cloud/deepseek-v4-pro";
      const snippet =
        'const r = await tools.agent_progress({ all: true, windowMin: 15, limit: 5 });\nreturn r;';
      const prompt =
        "Run this exact snippet ONCE with the execute tool and report the returned text verbatim:\n\n" + snippet;

      let text = "";
      let reported = false;
      for (let attempt = 1; attempt <= 2 && !reported; attempt++) {
        const out = run("opencode", ["run", "--standalone", "--auto", "--model", model, prompt], {
          cwd: proj,
          timeout: 300000,
        });
        text += `\n${out.stdout ?? ""}\n${out.stderr ?? ""}`;
        reported = /VERDICT {2}(WORKING|IDLE|LOOP|DONE)|agent_progress: /.test(text);
      }
      if (process.env.AGENT_PROGRESS_LIVE_DEBUG) writeFileSync("/tmp/agent-progress-live.log", text);

      // HARD (deterministic): the real binary loaded the plugin with no load error.
      ok(!/failed to load plugin|must default export/i.test(text), "real opencode: the plugin loaded (no load error)");
      ok(!/\breload\b/i.test(text), "real opencode: no server reload during the call");

      // LIVE-OR-SKIP (the LLM boundary): the model's decision to invoke the tool is
      // stochastic. WHEN it invokes, assert the deterministic content contract.
      if (reported) {
        ok(true, "real opencode: the model called the agent_progress tool");
        const body = text;
        ok(/VERDICT {2}(WORKING|IDLE|LOOP|DONE)/.test(body), "real opencode: agent_progress returned a verdict line");
        ok(/turns \d+/.test(body), "real opencode: the report carries the turn count");
      } else {
        console.log(
          "  SKIP  real opencode: the model did not invoke agent_progress under this provider/model — A/B prove the executor (a real invocation is pasted in the PR)",
        );
      }
    } finally {
      rmSync(proj, { recursive: true, force: true });
    }
  }
} else {
  console.log("  SKIP  live opencode layer (set LIVE_OPENCODE=1 to run the real binary end to end)");
}

if (failures > 0) {
  console.error(`check-agent-progress: FAIL — ${failures} assertion(s)`);
  process.exit(1);
}
console.log("check-agent-progress: OK");
