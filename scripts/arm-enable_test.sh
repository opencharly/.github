#!/usr/bin/env bash
# The `Enable auto-merge` step's OWN coverage (opencharly/.github#316).
#
# WHY THIS TEST EXISTS. That step is shipped JAVASCRIPT (`uses: actions/github-script`),
# not a `run:` block, and the arm job's behaviour is decided by what it does with GitHub's
# refusals. #313 fixed the first refusal (`unstable` — a finding, reported not retried to
# death); #316 added the second (`Pull request is in clean status` — the head is GREEN and
# the merge is available now, so auto-merge has nothing to wait for). Shipping that branch
# without executed proof is what the review blocked, correctly: the only "proof" was the
# hope that the PR's own arm job would take the path.
#
# HOW IT WORKS. The step's `script:` text is EXTRACTED from the shipped workflow — the text
# under test IS the text that runs, the same discipline the shell steps get — and executed
# under node with mocks for `github` (the GraphQL client), `context` and `core`. The mock's
# mutation throws the refusal the case is about. FOUR assertions, one of them a NEGATIVE
# CONTROL that removes EXACTLY the clean-status branch, so the coverage can fire:
#
#   1. clean-status refusal  -> the step RETURNS and notices CLEAN   (fails without #316)
#   2. the pre-#316 shape    -> the SAME input THROWS                (the hole, isolated)
#   3. any other refusal     -> still THROWS                         (the recogniser is narrow)
#   4. no refusal            -> arms and verifies the postcondition  (the happy path survives)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
WF="$root/.github/workflows/pr-validator.yml"

# shellcheck source=scripts/lib-org.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-org.sh"
extract_step_script "$WF" '^ *id: enable$' "$STATE/enable.js"
[[ -s "$STATE/enable.js" ]] \
  || { echo "FAIL: the shipped Enable auto-merge script was not found in $WF" >&2; exit 1; }
grep -q 'enablePullRequestAutoMerge' "$STATE/enable.js" \
  || { echo "FAIL: the extracted script has no arming mutation — the extraction drifted" >&2; exit 1; }

# The NEGATIVE CONTROL: the shipped script with EXACTLY the clean-status branch removed.
# Isolated (one contiguous block), so if the shipped shape moves the removal count changes
# and this test fails rather than silently testing nothing.
python3 -I - "$STATE/enable.js" "$STATE/enable-no-clean.js" <<'PY'
import sys

lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
out, i, removed = [], 0, 0
while i < len(lines):
    if "is in clean status" in lines[i] and "test(message)" in lines[i]:
        # the `if` line, its body, and the closing brace
        j = i
        while j < len(lines) and lines[j].strip() != "}":
            j += 1
        assert j < len(lines), "the clean-status branch is not closed by `}` — the shipped shape moved"
        removed += 1
        i = j + 1
        continue
    out.append(lines[i])
    i += 1
assert removed == 1, f"the control removed {removed} clean-status branch(es) — the shipped shape moved"
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out))
PY

cat >"$STATE/harness.mjs" <<'HARNESS'
import { readFileSync } from "node:fs";

// argv: <script.js> <mode>
const [, , stepPath, mode] = process.argv;
const src = readFileSync(stepPath, "utf8");

const notices = [];
const infos = [];
const warnings = [];
const core = {
  info: (m) => infos.push(String(m)),
  warning: (m) => warnings.push(String(m)),
  notice: (m) => notices.push(String(m)),
};

// A CLEAN pull request: no auto-merge yet, head matches, state OPEN. The mutation's answer
// is the variable under test.
const pr = { id: "PR_test", headRefOid: process.env.REVIEWED_HEAD, state: "OPEN" };
let armed = false;
const graphql = async (query) => {
  const q = String(query);
  if (q.includes("enablePullRequestAutoMerge")) {
    if (mode === "clean") {
      throw new Error("Request failed due to following response errors:\n - Pull request Pull request is in clean status");
    }
    if (mode === "other") {
      throw new Error("Resource not accessible by integration");
    }
    if (mode === "unstable") {
      throw new Error("Request failed due to following response errors:\n - Pull request Pull request is in unstable status");
    }
    // mode "armed": the mutation SUCCEEDS, and the next read must reflect it.
    armed = true;
    return { enablePullRequestAutoMerge: { pullRequest: { id: pr.id } } };
  }
  if (q.includes("disablePullRequestAutoMerge")) {
    return { disablePullRequestAutoMerge: { pullRequest: { id: pr.id } } };
  }
  // Anything else is the PR read.
  return { repository: { pullRequest: { ...pr, autoMergeRequest: armed ? { mergeMethod: "SQUASH" } : null } } };
};
const github = { graphql };
const context = { repo: { owner: "opencharly", repo: ".github" } };

const fn = new Function("github", "context", "core", "process", `return (async () => {\n${src}\n})()`);
let threw = null;
try {
  await fn(github, context, core, process);
} catch (e) {
  threw = String(e?.message || e);
}
process.stdout.write(JSON.stringify({ threw, notices, warnings, infos }));
HARNESS

run_case() { # run_case <script> <mode> -> prints the harness JSON
  (
    export PR_NUMBER=1
    export REVIEWED_HEAD=deadbeef
    node "$STATE/harness.mjs" "$1" "$2"
  )
}

cat >"$STATE/check.py" <<'PY'
import json, sys

mode, raw = sys.argv[1], sys.argv[2]
d = json.loads(raw)
threw = d.get("threw")
notices = d.get("notices") or []
if mode == "clean-ok":
    assert threw is None, "a CLEAN refusal must not throw, got: %s" % threw
    assert any("CLEAN" in n for n in notices), "no CLEAN notice was emitted: %r" % (d,)
elif mode == "clean-throws":
    assert threw and "clean status" in threw, "the pre-#316 shape must throw, got: %r" % (d,)
elif mode == "other-throws":
    assert threw and "not accessible" in threw, "an unrelated refusal must still throw, got: %r" % (d,)
PY

# ---- (1) the CLEAN refusal: a notice, no throw -------------------------------------
out="$(run_case "$STATE/enable.js" clean)"
python3 -I "$STATE/check.py" clean-ok "$out" \
  || { echo "FAIL: (1) a clean-status refusal must return with a CLEAN notice; got: $out" >&2; exit 1; }
echo "ok  (1) clean-status refusal -> notice, no throw"

# ---- (2) the NEGATIVE CONTROL: without the branch, the same refusal THROWS ---------
out="$(run_case "$STATE/enable-no-clean.js" clean)"
python3 -I "$STATE/check.py" clean-throws "$out" \
  || { echo "FAIL: (2) the pre-#316 shape must FAIL on a clean-status refusal — the control is stale; got: $out" >&2; exit 1; }
echo "ok  (2) pre-#316 shape      -> throws (the hole this change closes)"

# ---- (3) the recogniser is NARROW: any other refusal still throws -------------------
out="$(run_case "$STATE/enable.js" other)"
python3 -I "$STATE/check.py" other-throws "$out" \
  || { echo "FAIL: (3) an unrelated arming refusal must still fail the step; got: $out" >&2; exit 1; }
echo "ok  (3) unrelated refusal   -> still throws (the recogniser is narrow)"

# ---- (4) the HAPPY PATH survives: a successful mutation arms and is verified ----------
out="$(run_case "$STATE/enable.js" armed)"
python3 -I -c '
import json,sys
d=json.loads(sys.argv[1])
assert d["threw"] is None, "arming must succeed, got: %r" % (d.get("threw"),)
assert any("verified" in m.lower() for m in (d.get("infos") or [])), "the postcondition was not verified: %r" % (d,)
' "$out" || { echo "FAIL: (4) a successful mutation must arm and verify; got: $out" >&2; exit 1; }
echo "ok  (4) no refusal          -> arms and verifies the postcondition"

echo "arm-enable_test: all assertions passed"
