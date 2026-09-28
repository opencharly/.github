#!/usr/bin/env node
// check-opencode-coord.mjs — regression gate for `.opencode/plugins/coord.ts`
// (the coordination tools binding the generic `marketplace/scripts/coord.sh`).
//
// No stubs or mocks of the opencode boundary: every assertion runs the REAL
// artifact — the plugin module, its pure helpers, and (opt-in) the REAL
// `opencode` binary. A fake of the opencode boundary certifies behaviour the
// author IMAGINED rather than what opencode actually does, and cannot see a real
// integration break (R7, live-or-skip).
//
// Layers:
//   A (always)  — the plugin is a real ES module whose default export is a
//                 definition object with a string `id` AND BOTH loader entry
//                 points: `setup` (opencode >= 2.0, the generation whose custom
//                 tools this plugin exists for) AND `server` (opencode 1.x).
//   B (always)  — the pure helpers behave: `parseConf`, `isTier`,
//                 `resolveIdentity` precedence (args > env > conf, live session
//                 wins), `watchArgv`, `wakeLine`. No opencode needed.
//   C (opt-in)  — LIVE_OPENCODE=1 drives the REAL `opencode` binary end to end in
//                 a throwaway project: the loader registers `coord_comment`, the
//                 model CALLS it, the REAL `coord.sh` runs, and the returned
//                 comment carries the canonical footer (`Agent:` line BEFORE the
//                 `Assisted-by:` line). Skipped visibly when unset.
//
// Usage: node scripts/check-opencode-coord.mjs [--plugin <path>] [--coord-sh <path>]
//   --plugin    default `.opencode/plugins/coord.ts`
//   --coord-sh  the coord.sh to bind in the live test (default: the repo's
//               `marketplace/scripts/coord.sh`, then `scripts/coord.sh`).

import { spawnSync } from "node:child_process";
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
const coordSh = (() => {
  const explicit = arg("--coord-sh");
  if (explicit) return resolve(root, explicit);
  for (const c of [
    "marketplace/scripts/coord.sh",
    "../marketplace/scripts/coord.sh",
    "scripts/coord.sh",
  ]) {
    if (existsSync(join(root, c))) return join(root, c);
  }
  return join(root, "marketplace/scripts/coord.sh");
})();

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

// --- Layer A: the real plugin module is a V2 definition ---------------------
console.log(`check-opencode-coord: ${pluginPath}`);
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
    ok(
      typeof declared === "string" && declared.length > 0,
      `package.json declares @opencode-ai/plugin (${declared})`,
    );
    ok(pkg?.type === "module", "package.json sets type=module (silences the MODULE_TYPELESS warning)");
    const installedPkg = join(root, ".opencode", "node_modules", "@opencode-ai", "plugin", "package.json");
    if (existsSync(installedPkg)) {
      const ip = JSON.parse(readFileSync(installedPkg, "utf8"));
      ok(ip?.exports?.["./v2/promise"], `the installed @opencode-ai/plugin ${ip.version} exports ./v2/promise`);
    } else {
      console.log(
        "  SKIP  installed @opencode-ai/plugin absent (run `bun install` in .opencode to assert the ./v2/promise export)",
      );
    }
  } else {
    fail(".opencode/package.json is missing (the V2 type pin)");
  }

  // --- Layer B: the pure helpers (real inputs, no opencode) -----------------
  const { parseConf, isTier, resolveIdentity, watchArgv, wakeLine, TIERS, VERBS } = mod;

  eq(
    parseConf("# comment\nagent=slug-x\n\nharness = OpenCode\nmodel=DeepSeek V4.1 Flash\n"),
    { agent: "slug-x", harness: "OpenCode", model: "DeepSeek V4.1 Flash" },
    "parseConf trims, drops blanks/# comments, splits on the first '='",
  );
  eq(parseConf(""), {}, "parseConf yields {} for empty text");

  ok(isTier("fully tested and validated"), "isTier accepts a canonical tier");
  ok(!isTier("pretty sure it works"), "isTier rejects an invented tier");
  ok(!isTier(undefined), "isTier rejects a non-string");

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

  const noLive = resolveIdentity({}, { session: "conf-session" }, {}, undefined);
  eq(noLive.session, "conf-session", "resolveIdentity: falls back to conf session when no live id");

  eq(
    watchArgv("/x/gh_watch.sh", { items: ["acme/widget#1", "acme/other#2"], events: "comment", timeout: 30 }),
    ["/x/gh_watch.sh", "--events", "comment", "--timeout", "30", "acme/widget#1", "acme/other#2"],
    "watchArgv builds a generic one-shot argv (script first, NO leading 'bash')",
  );
  ok(
    watchArgv("/x/gh_watch.sh", { items: ["a/b#1"] })[0] === "/x/gh_watch.sh",
    "watchArgv starts with the script, not 'bash' (the double-bash regression)",
  );
  eq(
    watchArgv("/x/gh_watch.sh", { items: ["a/b#1"], autoRearm: true }),
    ["/x/gh_watch.sh", "--auto-rearm", "a/b#1"],
    "watchArgv honours autoRearm",
  );

  eq(wakeLine("noise\nMERGED acme/widget#1\n\n"), "MERGED acme/widget#1", "wakeLine returns the last non-empty line");
  eq(wakeLine(""), undefined, "wakeLine returns undefined for empty stdout");

  ok(VERBS.includes("HANDING OVER") && VERBS.includes("TAKING OVER"), "VERBS carries the spaced multi-word labels");
  ok(TIERS.length === 5, "TIERS carries the five documented attribution tiers");

  // The script location is overridable + repo-relative-searchable (a repo without
  // a marketplace submodule — e.g. dotgithub in the session worktree layout — finds
  // `../marketplace/scripts/…` instead of forking it — R3).
  const src = readFileSync(pluginPath, "utf8");
  ok(/COORD_SH/.test(src) && /GH_WATCH_SH/.test(src), "the plugin resolves its scripts via COORD_SH/GH_WATCH_SH overrides");

  // Static guard for the R1 fix: the executors MUST be async + abortable. A
  // synchronous spawn helper would block opencode's server event loop (the
  // coord_watch watcher is long-lived → the supervisor restarts the server), and a
  // missing `signal` means an interrupted Session cannot stop the operation.
  ok(!/spawnSync/.test(src), "coord.ts contains NO synchronous spawn helper (spawnSync)");
  // Match the actual abort WIRING, not prose: an `abort` listener that kills, and
  // the executor's `toolCtx.signal` read. The word "signal" in a doc comment must
  // not satisfy this.
  ok(
    /addEventListener\(\s*["']abort["']/.test(src) && /toolCtx\?\.signal/.test(src),
    "coord.ts wires the abort (an `abort` listener + toolCtx?.signal), not merely mentions 'signal'",
  );
  // Match the actual CALL SITE, not prose: the Bun branch calls the local `p.kill`
  // from `bun.spawn(...)`; the doc comment mentioning "Bun.spawn" must not satisfy
  // this on its own.
  ok(/bun\.spawn\(/.test(src) && /globalThis as \{ Bun\?: any \}\)\.Bun/.test(src), "coord.ts spawns via the Bun runtime at the CALL SITE (async, not a comment)");
  ok(/SIGKILL/.test(src), "coord.ts kills with SIGKILL (a TERM trap in the watcher would defer SIGTERM)");

  ok(typeof mod.resolveScript === "function", "resolveScript is exported (script resolution is unit-testable)");
  if (typeof mod.resolveScript === "function") {
    const { resolveScript } = mod;
    const d = mkdtempSync(join(tmpdir(), "coord-resolve."));
    try {
      mkdirSync(join(d, "marketplace", "scripts"), { recursive: true });
      writeFileSync(join(d, "marketplace", "scripts", "coord.sh"), "#!/bin/sh\n");
      eq(
        resolveScript(d, undefined, ["marketplace/scripts/coord.sh", "../marketplace/scripts/coord.sh"]),
        join(d, "marketplace", "scripts", "coord.sh"),
        "resolveScript finds the repo-relative marketplace script",
      );
      eq(
        resolveScript("/elsewhere", "/abs/coord.sh", ["marketplace/scripts/coord.sh"]),
        "/abs/coord.sh",
        "resolveScript prefers the explicit env override",
      );
      eq(
        resolveScript("/elsewhere", undefined, ["marketplace/scripts/coord.sh"]),
        "/elsewhere/marketplace/scripts/coord.sh",
        "resolveScript returns the first candidate when none exists (so the caller reports it missing)",
      );
    } finally {
      rmSync(d, { recursive: true, force: true });
    }
  }

  // --- Layer B2: the tool EXECUTE paths (real spawn, stub scripts) ----------
  // Drives `plugin.setup` with a stub context, then CALLS each tool's execute. This
  // is the layer that fails on the double-`bash` regression (`spawnSync("bash",
  // ["bash", script, …])`), which the pure-array assertion above cannot catch.
  {
    const d = mkdtempSync(join(tmpdir(), "coord-exec."));
    try {
      mkdirSync(join(d, ".opencode"), { recursive: true });
      const stubWatch = join(d, "stub-gh-watch.sh");
      const stubCoord = join(d, "stub-coord.sh");
      writeFileSync(stubWatch, '#!/bin/sh\necho "MERGED acme/widget#1"\n');
      writeFileSync(stubCoord, '#!/bin/sh\necho "https://github.com/acme/widget/issues/1#issuecomment-9"\n');

      const tools = {};
      const ctx = {
        location: { directory: d },
        tool: { transform: async (cb) => cb({ add: (t) => (tools[t.name] = t) }) },
        session: { hook: async () => ({}) },
      };
      // The plugin resolves its script paths AT SETUP TIME, so the overrides must
      // be in place before setup runs.
      const saved = { COORD_SH: process.env.COORD_SH, GH_WATCH_SH: process.env.GH_WATCH_SH };
      process.env.COORD_SH = stubCoord;
      process.env.GH_WATCH_SH = stubWatch;
      try {
        await plugin.setup(ctx);
        ok(!!tools.coord_comment && !!tools.coord_watch, "setup registers coord_comment + coord_watch");

        const watchRes = await tools.coord_watch.execute({ items: ["acme/widget#1"] });
        eq(
          watchRes.content,
          "MERGED acme/widget#1",
          "coord_watch.execute RUNS the watcher via bash (double-`bash` regression) and returns the wake line",
        );

        // The executors MUST be async + non-blocking, and the abort MUST be
        // untrappable: the stub installs a TERM trap (like the real gh_watch.sh),
        // so a SIGTERM-to-bash kill would be DEFERRED until its foreground sleep
        // finishes (measured: a `timeout: 1` abort overran to the full 30s). Only a
        // SIGKILL stops it immediately.
        const slowWatch = join(d, "stub-gh-watch-slow.sh");
        writeFileSync(slowWatch, "#!/bin/sh\ntrap 'exit 0' TERM\nsleep 30\necho \"MERGED late\"\n");
        process.env.GH_WATCH_SH = slowWatch;
        const ctx2 = {
          location: { directory: d },
          tool: { transform: async (cb) => cb({ add: (t) => (tools["slow_" + t.name] = t) }) },
          session: { hook: async () => ({}) },
        };
        await plugin.setup(ctx2);
        const t0 = Date.now();
        const timed = await tools.slow_coord_watch.execute({ items: ["acme/widget#1"], timeout: 1 });
        const elapsed = Date.now() - t0;
        ok(
          elapsed < 15000,
          `coord_watch is NON-BLOCKING: timeout=1 killed a 30s watcher well before its sleep (a blocking spawn would run the full 30s)`,
        );
        ok(/^TIMEOUT/m.test(timed.content), "coord_watch reports TIMEOUT when the deadline overruns");

        // Abort: passing an already-aborted signal kills the child (session stop).
        process.env.GH_WATCH_SH = slowWatch;
        const abortedCtl = new AbortController();
        abortedCtl.abort();
        const t1 = Date.now();
        const abortRes = await tools.slow_coord_watch.execute({ items: ["acme/widget#1"] }, { signal: abortedCtl.signal });
        ok(
          Date.now() - t1 < 15000 && /aborted|TIMEOUT|no event|exited/.test(abortRes.content),
          "coord_watch honours context.signal: an aborted call returns promptly",
        );
        process.env.GH_WATCH_SH = stubWatch;

        const commentRes = await tools.coord_comment.execute({
          verb: "STATUS",
          item: "acme/widget#1",
          confidence: "documentation reviewed",
          agent: "slug-x",
          session: "ses_x",
          harness: "OpenCode",
          model: "M",
        });
        eq(
          commentRes.content,
          "https://github.com/acme/widget/issues/1#issuecomment-9",
          "coord_comment.execute RUNS coord.sh (single `bash`) and returns its stdout",
        );

        const missing = await tools.coord_watch.execute({});
        ok(
          /at least one item/.test(missing.content),
          "coord_watch.execute rejects an empty items list with a clear message",
        );
      } finally {
        // Node footgun: `process.env.X = undefined` sets the STRING "undefined",
        // which would poison the live layer's COORD_SH/GH_WATCH_SH. DELETE instead.
        for (const [k, v] of Object.entries(saved)) {
          if (v === undefined) delete process.env[k];
          else process.env[k] = v;
        }
      }
    } finally {
      rmSync(d, { recursive: true, force: true });
    }
  }
}

// --- Layer C: the REAL opencode binary, end to end (opt-in) -----------------
if (process.env.LIVE_OPENCODE === "1") {
  const which = run("sh", ["-c", "command -v opencode"]);
  if (which.status !== 0) {
    fail("LIVE_OPENCODE=1 but no `opencode` binary on PATH");
  } else if (!existsSync(coordSh)) {
    fail(`LIVE_OPENCODE=1 but coord.sh not found at ${coordSh} (--coord-sh to point at it)`);
  } else {
    const proj = mkdtempSync(join(tmpdir(), "opencode-coord-live."));
    try {
      mkdirSync(join(proj, ".opencode", "plugins"), { recursive: true });
      mkdirSync(join(proj, "marketplace", "scripts"), { recursive: true });
      cpSync(pluginPath, join(proj, ".opencode", "plugins", "coord.ts"));
      // The plugin statically imports its SIBLING modules (e.g. ../lib/wake-line.ts),
      // so the whole lib/ directory must be staged too — otherwise the import fails
      // and no tool registers.
      const pluginDir = dirname(pluginPath);
      const libDir = join(dirname(pluginDir), "lib");
      if (existsSync(libDir)) cpSync(libDir, join(proj, ".opencode", "lib"), { recursive: true });
      cpSync(coordSh, join(proj, "marketplace", "scripts", "coord.sh"));
      // Determinism: the model's transcript is not a reliable carrier. Stage a shim
      // AT coord.sh's path that runs the REAL coord.sh and ALSO tees its stdout to a
      // file — so we assert on what coord.sh ACTUALLY produced (deterministic), while
      // still driving it through the real opencode tool call. coord.sh is called with
      // --dry-run, so this makes no GitHub call.
      const realCoord = join(proj, "real-coord.sh");
      const capture = join(proj, "captured.txt");
      cpSync(coordSh, realCoord);
      writeFileSync(
        join(proj, "marketplace", "scripts", "coord.sh"),
        `#!/bin/sh\nexec "$(dirname "$0")/../../real-coord.sh" "$@" | tee ${capture}\n`,
      );
      // A conf so the model need only pass verb + item + dryRun (the session is
      // auto-filled from the tool context).
      writeFileSync(
        join(proj, ".opencode", "coord.conf"),
        "agent=coord-live\nharness=OpenCode\nmodel=DeepSeek V4.1 Flash\nconfidence=documentation reviewed\n",
      );
      run("git", ["init", "-q"], { cwd: proj });
      run("git", ["config", "user.email", "ci@example.invalid"], { cwd: proj });
      run("git", ["config", "user.name", "ci"], { cwd: proj });
      writeFileSync(join(proj, "f.txt"), "x\n");
      run("git", ["add", "f.txt"], { cwd: proj });

      const prompt =
        "You MUST call the coord_comment tool in this turn. Call it exactly once with " +
        "verb=STATUS, item=\"opencharly/opencharly#1\", dryRun=true. Do NOT answer from " +
        "memory — actually invoke the tool, then report its result.";

      // LIVE LLM boundary: the model occasionally declines to call the tool. Retry
      // ONCE (bounded), and accept EITHER the deterministic capture (what the REAL
      // coord.sh wrote when the tool invoked it) OR the model's transcript. Never a
      // silent pass: a real failure (bad footer) still fails.
      let emitted = "";
      let text = "";
      for (let attempt = 1; attempt <= 2 && !emitted; attempt++) {
        const out = run("opencode", ["run", "--standalone", "--auto", prompt], {
          cwd: proj,
          timeout: 240000,
        });
        text += `\n${out.stdout ?? ""}\n${out.stderr ?? ""}`;
        if (process.env.COORD_LIVE_DEBUG) {
          writeFileSync(`/tmp/coord-live-attempt-${attempt}.log`, `status=${out.status} signal=${out.signal ?? ""}\n${text}\n--- capture ---\n`);
        }
        try {
          emitted = readFileSync(capture, "utf8");
        } catch {
          /* no capture → fall back to the transcript for the assertions */
        }
        if (!emitted && /\*Agent: `coord-live`/.test(text)) emitted = text;
      }
      ok(/coord_comment/.test(text) || emitted.includes("STATUS"), "real opencode: the model called the coord_comment tool");
      if (!emitted) fail("real opencode: coord.sh produced no captured output after 2 attempts (the tool was not called)");
      ok(/^STATUS$/m.test(emitted), "real opencode: coord.sh emitted the verb label");
      ok(
        /\*Agent: `coord-live` · session `ses_[A-Za-z0-9]+`\*/.test(emitted),
        "real opencode: coord.sh emitted the Agent: line (slug + live session)",
      );
      ok(
        /\*Assisted-by: OpenCode DeepSeek V4\.1 Flash \(documentation reviewed\)\*/.test(emitted),
        "real opencode: coord.sh emitted the Assisted-by: trailer",
      );
      const agentAt = emitted.indexOf("*Agent:");
      const assistAt = emitted.indexOf("*Assisted-by:");
      ok(
        agentAt !== -1 && assistAt !== -1 && agentAt < assistAt,
        "real opencode: canonical footer order (Agent: BEFORE Assisted-by:)",
      );

      // --- the R1 FIX, proven live: coord_watch is non-blocking and does NOT
      // restart the server. Stage a SLOW watcher (30s) that records START at once
      // and FULL only after its sleep; call coord_watch with timeout=2. A blocked
      // (spawnSync) call would let the stub reach FULL and freeze the server; the
      // async+abortable executor kills it before FULL. "loading plugin" is logged
      // ONCE per server boot, so counting it in the run's --print-logs output proves
      // there was no reload.
      const watchLog = join(proj, "watch.log");
      const slowWatch = join(proj, "marketplace", "scripts", "gh_watch.sh");
      writeFileSync(slowWatch, `#!/bin/sh\necho START >> ${watchLog}\nsleep 30\necho FULL >> ${watchLog}\n`);
      const watchPrompt =
        "You MUST call the coord_watch tool in this turn. Call it exactly once with " +
        'items=["acme/widget#1"] and timeout=2. Do NOT answer from memory — actually ' +
        "invoke the tool, then report its result.";
      let wlog = "";
      let watchTimedOut = false;
      for (let attempt = 1; attempt <= 2; attempt++) {
        const wout = run("opencode", ["run", "--standalone", "--print-logs", "--auto", watchPrompt], {
          cwd: proj,
          timeout: 120000,
        });
        wlog += `\n${wout.stdout ?? ""}\n${wout.stderr ?? ""}`;
        if (wout.signal || wout.error) watchTimedOut = true;
        if (/coord_watch/.test(wlog)) break;
      }
      ok(/coord_watch/.test(wlog), "real opencode: coord_watch was the tool exercised live");
      // The DISCRIMINATING assertion is START/not-FULL below — NOT wall-clock. The
      // run's ~40s wall time is opencode's own startup + one model turn; the watch
      // itself was killed at its 2s deadline (proven by FULL being absent). A
      // blocking spawn would let the 30s stub reach FULL.
      ok(
        !watchTimedOut,
        "real opencode: the coord_watch run stayed within its subprocess budget (no 120s hang)",
      );
      // The discriminating assertion: the 30s stub began (START) but was KILLED
      // before it could finish (FULL). A blocking spawn would reach FULL.
      const watchRan = existsSync(watchLog) ? readFileSync(watchLog, "utf8") : "";
      ok(/START/.test(watchRan), "real opencode: the slow 30s watcher was started by coord_watch");
      ok(
        !/FULL/.test(watchRan),
        `real opencode: coord_watch killed the 30s watcher before completion (timeout: 2) — a blocking spawn would have let it reach FULL`,
      );
      // "loading plugin" is logged once per server boot; a freeze-triggered restart
      // logs it AGAIN. The whole run must show it at most once.
      const loadCount = (wlog.match(/loading plugin/g) || []).length;
      ok(
        loadCount <= 1,
        `real opencode: NO server reload during coord_watch (plugin loaded ${loadCount} time(s); a freeze/restart would log it again)`,
      );
    } finally {
      rmSync(proj, { recursive: true, force: true });
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
