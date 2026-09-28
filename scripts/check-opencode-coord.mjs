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
        process.env.COORD_SH = saved.COORD_SH;
        process.env.GH_WATCH_SH = saved.GH_WATCH_SH;
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
      cpSync(coordSh, join(proj, "marketplace", "scripts", "coord.sh"));
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

      const out = run(
        "opencode",
        [
          "run",
          "--standalone",
          "--auto",
          "Call the tool coord_comment exactly once with verb=STATUS, " +
            "item=\"opencharly/opencharly#1\", dryRun=true. " +
            "Then output the tool's returned text VERBATIM between <<< and >>> markers.",
        ],
        { cwd: proj, timeout: 240000 },
      );
      const text = `${out.stdout ?? ""}\n${out.stderr ?? ""}`;
      ok(/STATUS/.test(text), "real opencode: the coord_comment tool returned the verb label");
      ok(/\*Agent: `coord-live` · session `ses_/.test(text), "real opencode: the comment carries the Agent: line (slug + live session)");
      ok(
        /\*Assisted-by: OpenCode DeepSeek V4\.1 Flash \(documentation reviewed\)\*/.test(text),
        "real opencode: the comment carries the Assisted-by: trailer",
      );
      const agentAt = text.indexOf("*Agent:");
      const assistAt = text.indexOf("*Assisted-by:");
      ok(
        agentAt !== -1 && assistAt !== -1 && agentAt < assistAt,
        "real opencode: canonical footer order (Agent: BEFORE Assisted-by:)",
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
