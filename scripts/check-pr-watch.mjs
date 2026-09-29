#!/usr/bin/env node
// check-pr-watch.mjs — unit tests for the pure logic in .opencode/plugins/pr-watch.ts.
//
// pr-watch.ts is PURE TypeScript (operator directive, 2026-09-29): its native poll
// loop uses the shared engine `../lib/watch.ts` and NEVER spawns a `.sh`. So it is
// proven by (a) the real module importing cleanly as a V2 definition, (b) the pure
// helpers (`parseItems`/`pickSessionID`/`lastWakeLine`) behaving, and (c) the delivery
// AND native-poll primitives being present as CODE (not commented out) on BOTH
// generations:
//   - V2 (opencode >= 2.0, MEASURED 2026-09-28 against v2.0.18): the context has NO
//     `client`; delivery is `ctx.session.synthetic({ sessionID, text })` with the
//     session id captured from `ctx.tool.hook("execute.before", …)`.
//   - V1 (opencode 1.x): the SDK client, `client.tui.showToast` + the noReply
//     context injection.
//   - the native watcher: `pollOnce` + `sleepAbortable` from `lib/watch.ts` (no shell).
//
// Usage: node scripts/check-pr-watch.mjs

import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const pluginPath = join(root, ".opencode/plugins/pr-watch.ts");
const source = readFileSync(pluginPath, "utf8");

// Strip BOTH block comments (`/* … */`, including the ` *`-prefixed docstring) and
// whole-line `//` comments, so a commented-out call no longer counts as present (the
// exact regression this gate exists for: a "load-bearing" call left as a comment). A
// docstring alone must never satisfy the primitive assertions below.
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n")
    .filter((l) => !l.trim().startsWith("//"))
    .join("\n");
}
const code = stripComments(source);

let failures = 0;
const pass = (m) => console.log(`  PASS  ${m}`);
const fail = (m) => {
  failures += 1;
  console.error(`  FAIL  ${m}`);
};
const ok = (cond, m) => (cond ? pass(m) : fail(m));
const eq = (a, b, m) =>
  ok(JSON.stringify(a) === JSON.stringify(b), `${m} (got ${JSON.stringify(a)})`);

const mod = await import(pathToFileURL(pluginPath).href);
const { parseItems, pickSessionID, lastWakeLine } = mod;

ok(
  mod.default !== null && typeof mod.default === "object" && typeof mod.default.setup === "function",
  "default export is the V2 { id, setup } definition",
);
ok(
  typeof parseItems === "function" &&
    typeof pickSessionID === "function" &&
    typeof lastWakeLine === "function",
  "pure helpers parseItems/pickSessionID/lastWakeLine are exported",
);

eq(
  parseItems("acme/widget#12\n\n# comment\n  acme/other#3  \n"),
  ["acme/widget#12", "acme/other#3"],
  "parseItems trims, drops blanks and # comments, preserves order",
);
eq(parseItems("# only comments\n\n"), [], "parseItems yields [] for a comment-only config");

const dir = "/work";
const sessions = [
  { id: "old-root", directory: dir, time: { updated: 10 } },
  { id: "child", directory: dir, parentID: "old-root", time: { updated: 99 } },
  { id: "new-root", directory: dir, time: { updated: 50 } },
  { id: "other-dir", directory: "/elsewhere", time: { updated: 100 } },
];
eq(
  pickSessionID(sessions, dir),
  "new-root",
  "pickSessionID picks the most recently updated root session in the directory (ignores children and other dirs)",
);
eq(pickSessionID(sessions, "/none"), undefined, "pickSessionID returns undefined when no session matches");
eq(pickSessionID([], dir), undefined, "pickSessionID tolerates an empty list");
eq(
  pickSessionID([{ directory: dir, time: { updated: 1 } }], dir),
  undefined,
  "pickSessionID ignores sessions without a string id",
);

eq(
  lastWakeLine("noise\nCOMMENT acme/widget#12 url\n\n"),
  "COMMENT acme/widget#12 url",
  "lastWakeLine returns the last non-empty line",
);
eq(lastWakeLine(""), undefined, "lastWakeLine returns undefined for empty output");

// Negative control: the stripper MUST remove a docstring and a `//` comment, so needles
// that live only there cannot satisfy the positive assertions below.
const synthetic =
  "/** doc: client.tui.showToast + client.session.list + noReply: true + " +
  "ctx.session.synthetic + ctx.tool.hook */\n" +
  "// client.session.prompt\nconst real = 1;\n";
const syntheticCode = stripComments(synthetic);

for (const needle of [
  // V2 delivery (the measured fix): the session domain, not the absent `client`.
  "ctx.session.synthetic",
  "ctx.tool.hook",
  "execute.before",
  "sessionID",
  // V1 delivery (opencode 1.x SDK client).
  "client.tui",
  "showToast",
  "client.session.list",
  "client.session",
  "noReply: true",
  // the NATIVE poll engine (lib/watch.ts) — no shell spawn.
  "pollOnce",
  "sleepAbortable",
]) {
  ok(
    !syntheticCode.includes(needle),
    `stripComments removes ${needle} from a docstring/comment (negative control)`,
  );
  ok(code.includes(needle), `the shipped code (comments stripped) contains ${needle}`);
}

if (failures > 0) {
  console.error(`check-pr-watch: FAIL — ${failures} assertion(s)`);
  process.exit(1);
}
console.log("check-pr-watch: OK");
