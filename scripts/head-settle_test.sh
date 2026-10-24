#!/usr/bin/env bash
# The head-settle gate's OWN coverage (opencharly/.github#229).
#
# WHY THE COVERAGE WORKS ON THE SHIPPED TEXT: the settle logic lives INSIDE the
# reusable workflow, and the reusable workflow runs in the CALLER's repository — it
# never checks out opencharly/.github, so a script in this repo does not exist in the
# caller's workspace and could not be the thing the caller runs. The coverage
# therefore EXTRACTS the shipped step's `run:` text out of
# .github/workflows/pr-validator.yml and RUNS THAT TEXT against fixtures — the same
# pattern the umbrella uses for its own manifest steps
# (scripts/check-verify-branch-audit.mjs). The text under test IS the shipped text,
# so the two cannot drift.
#
# The classes it proves — the EXIT CODE IS THE CLASS:
#   0 GREEN       every check on the head passed.
#   1 NOT-PASSED  a check on the head did not pass — a FINDING about the change.
#   2 IN-FLIGHT   a check is still RUNNING — NOT a finding: re-run only this job.
#   3 UNREAD      the head could not be read — refuse to arm.
#   4 EMPTY       the head carries NO check run at all — refuse to arm
#                 (opencharly/.github#248).
#
# The pre-#229 shape had three defects, and this test proves each one against a
# restored copy of that shape:
#   * the wait's budget was an INDEPENDENT literal (3600s) under the step's own
#     backstop (4200s) — two unrelated numbers, with nothing asserting the relation;
#   * "a check did not pass" and "a check is still RUNNING" shared ONE exit code
#     (1) and ONE remedy — a whole-workflow re-run, i.e. a FRESH REVIEW;
#   * the unread-head guard was UNREACHABLE: the fetch was `curl … | jq …`, so a
#     failed API read produced an empty snapshot, every count read from it was the
#     empty STRING, and the step fell through to "safe to arm auto-merge" with exit
#     0 — arming auto-merge on a head whose checks it had never read.
#
# The pre-#248 shape had ONE more defect, and this test proves it against a
# restored copy of that shape too:
#   * the snapshot's guard was on the BODY, not on the SET: a body of
#     `{"total_count":0,"check_runs":[]}` is not empty, so it passed the guard, the
#     filter yielded `{pending:[],bad:[],all:[],total:0}`, every count read 0, and
#     the step fell through to "all 0 check run(s) on this head passed — safe to arm
#     auto-merge" with exit 0 — the gate satisfied by observing NOTHING.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
WF="$root/.github/workflows/pr-validator.yml"

# The pre-#229 numbers, and the slowest SIBLING check measured across the org over
# two independent sample sets (2026-10-24). A sibling is a check the `arm` job
# actually WAITS for, so the pr-validator's OWN review job is not one: `arm`
# depends on it, so it has always finished before the wait begins.
#   Set A — the 25 most-recent PRs of 4 org repos: 233 completed check-runs, of
#     which 100 are the review job, leaving 133 siblings. 17 of them exceed the
#     600 s budget of the pre-#236 shape, 0 exceed the 3600 s budget of the
#     pre-#229 shape, and the slowest is 1073 s (`pin-currency`, opencharly/charly).
#   Set B — the 6 most-recent CLOSED PRs of 8 org repos: 182 completed check-runs,
#     of which 53 are the review job, leaving 129 siblings. 11 exceed 600 s, 0
#     exceed 3600 s, and the slowest is 974 s (`pin-currency`, opencharly/charly);
#     the next are 822 s (`deploy`, opencharly/docs) and 775 s (`build`,
#     opencharly/marketplace).
# The constant is the LARGER of the two, so the assertion below is the
# conservative one: the DERIVED budget must exceed the slowest sibling ever
# observed. No measured sibling has yet exceeded the pre-#229 budget of 3600 s —
# the truncation was measured under the pre-#236 shape, whose budget was 600 s
# (opencharly/marketplace#540, 2026-10-23) — so what the pre-#229 budget still
# carried was the UNASSERTED relation, not an observed truncation.
SLOWEST_SIBLING_SECONDS=1073
LEGACY_BUDGET_SECONDS=3600
LEGACY_BACKSTOP_SECONDS=4200

# ---- the shipped text under test --------------------------------------------------
# The step's `run:` block, dedented, with the jq filter inside it untouched.
awk '
  function indent(s,   i) { for (i = 1; i <= length(s); i++) if (substr(s, i, 1) != " ") return i - 1; return length(s) }
  /^ *id: head-checks$/ { in_step = 1; next }
  in_step && !found_run && /^ *run: *\|/ { run_indent = indent($0); found_run = 1; next }
  found_run {
    if ($0 ~ /^[[:space:]]*$/) { print ""; next }
    ind = indent($0)
    if (ind <= run_indent) { exit }
    if (content_indent == 0) content_indent = ind
    if (ind < content_indent) { exit }
    print substr($0, content_indent + 1)
  }
' "$WF" >"$STATE/step.sh"
[[ -s "$STATE/step.sh" ]] \
  || { echo "FAIL: the shipped head-settle step was not found in $WF" >&2; exit 1; }
grep -q 'snapshot()' "$STATE/step.sh" \
  || { echo "FAIL: the extracted step has no snapshot() — the extraction drifted" >&2; exit 1; }

# The step's own YAML block, for the backstop/budget invariants.
awk '
  /^ *- name: .*Head check-runs/ { in_step = 1; print; next }
  in_step && /^ *- name: / { exit }
  in_step { print }
' "$WF" >"$STATE/step.yaml"
[[ -s "$STATE/step.yaml" ]] \
  || { echo "FAIL: the head-settle step's YAML block was not found in $WF" >&2; exit 1; }

# ---- the PRE-#248 SHAPE: the shipped text with the class-4 guard removed ------------
# The NEGATIVE CONTROL for #248, and it is ISOLATED: it is the shipped text with
# EXACTLY ONE block removed — the guard on the SET. If the shipped text ever stops
# carrying that guard, this control stops being the pre-#248 shape and the assertions
# below fail, so the control cannot silently rot into a tautology.
python3 - "$STATE/step.sh" "$STATE/step-248.sh" <<'PY'
import sys

lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
out, i, removed = [], 0, 0
while i < len(lines):
    if lines[i].strip().startswith("#   4 EMPTY"):
        # The whole class-4 span: the class-table row, the comment that explains it,
        # the `ntotal=…` read, the `if … ; then`, its annotations, `exit 4`, and the
        # closing `fi`. The block holds no nested `if`, so the first `fi` closes it.
        j = i
        while j < len(lines) and lines[j].strip() != "fi":
            j += 1
        assert j < len(lines), "the class-4 block is not closed by an `fi` — the shipped shape moved"
        removed += 1
        i = j + 1
        continue
    out.append(lines[i])
    i += 1
assert removed == 1, f"the control removed {removed} class-4 block(s) — the shipped shape moved"
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out))
PY

# ---- the PRE-#229 SHAPE, restored in a copy of the pre-#248 text --------------------
# This is the NEGATIVE CONTROL: the coverage must be able to FAIL. Restoring the old
# shape in the shipped text keeps the control stable — it does not depend on what
# `main` looks like tomorrow, which is what a `git show origin/main:…` control would.
# Three mechanisms are restored:
#   * the fetch: a bare `curl … | jq …` pipeline, so a failed API read is invisible;
#   * the budget: an INDEPENDENT literal (WAIT_BUDGET_SECONDS), not derived;
#   * the classes: "still in flight" merged back into "a check did not pass" (exit 1),
#     with the old whole-validator remedy.
python3 - "$STATE/step-248.sh" "$STATE/step-legacy.sh" <<'PY'
import sys

src = open(sys.argv[1], encoding="utf-8").read()
lines = src.split("\n")
out = []
i = 0
replaced = {"budget": 0, "fetch": 0, "exit": 0, "remedy": 0, "message": 0, "sleep": 0,
            "guard_echo": 0, "guard_exit": 0, "annot_loop": 0, "annot_sum": 0,
            "local": 0}

while i < len(lines):
    ln = lines[i]
    stripped = ln.strip()
    indent = ln[: len(ln) - len(ln.lstrip())]
    # (a) the budget block: backstop/margin/budget/interval/deadline -> one literal.
    if stripped.startswith("backstop="):
        replaced["budget"] += 1
        out.append(f"{indent}deadline=$(( $(date +%s) + WAIT_BUDGET_SECONDS ))")
        i += 1
        while i < len(lines) and not lines[i].strip().startswith("deadline="):
            i += 1
        i += 1  # skip the shipped deadline line too
        continue
    # the shipped text declares the local its checked fetch writes into; the base
    # had no such declaration.
    if stripped == "local body":
        replaced["local"] += 1
        i += 1
        continue
    # (b) the fetch: the checked fetch -> the bare pipeline.
    if stripped == 'if ! body="$(curl -fsS "${auth[@]}" \\':
        replaced["fetch"] += 1
        out.extend([
            f'{indent}curl -fsS "${{auth[@]}}" \\',
            f'{indent}  "${{api}}/commits/${{HEAD_SHA}}/check-runs?per_page=100&filter=all" \\',
            f'{indent}| jq --arg selfctx "$self_ctx" -c \'',
        ])
        i += 1
        # skip: the URL line, the "); then", "return 1", "fi", the comment, the
        # emptiness guard, and the "printf … | jq" line.
        while i < len(lines) and "printf '%s' \"$body\" | jq" not in lines[i]:
            i += 1
        i += 1
        continue
    # (c) the in-flight message: the shipped wording -> the old one, with the old
    #     budget variable (the shape had no derived `budget`).
    if "Still in flight" in stripped:
        replaced["message"] += 1
        out.append(
            f'{indent}echo "::error::could not confirm this head is green: still in flight after '
            f'${{WAIT_BUDGET_SECONDS}}s — $(jq -r \'.pending | join(", ")\' <<<"$snap")"'
        )
        i += 1
        continue
    # (d) the remedy: the "NOT a finding" block -> the old whole-validator remedy.
    if stripped.startswith('echo "::error::NOT a finding about the change'):
        replaced["remedy"] += 1
        out.append(
            f'{indent}echo "::error::re-run this check once they finish '
            f'(a push, or a REST re-run of this workflow run, re-evaluates it)."'
        )
        i += 1
        while i < len(lines) and lines[i].strip().startswith('echo "::error::'):
            i += 1
        continue
    # (e) the merged class: exit 2 -> exit 1.
    if stripped == "exit 2":
        replaced["exit"] += 1
        out.append(f"{indent}exit 1")
        i += 1
        continue
    # (f) the fixed poll interval -> the old literal.
    if stripped == 'sleep "$interval"':
        replaced["sleep"] += 1
        out.append(f"{indent}sleep 15")
        i += 1
        continue
    # (g) the unread-head guard: the shipped class (3) -> the base's untitled guard
    #     with exit 1. It is UNREACHABLE in the legacy shape — exactly as it was in
    #     the base, where the unchecked pipeline swallowed the failed API read.
    if "The head could not be read" in stripped:
        replaced["guard_echo"] += 1
        out.append(
            f'{indent}echo "::error::could not read the check runs for ${{HEAD_SHA}} — refusing to arm auto-merge on an unread head"'
        )
        i += 1
        continue
    if stripped == "exit 3":
        replaced["guard_exit"] += 1
        out.append(f"{indent}exit 1")
        i += 1
        continue
    # (h) the not-passed annotations: the titled form -> the base's untitled form.
    if "while IFS= read -r line" in stripped and "did not pass" in stripped:
        replaced["annot_loop"] += 1
        out.append(
            ln.replace(
                "::error title=A check on this head did not pass::",
                "::error::a check on this head did not pass — ",
            )
        )
        i += 1
        continue
    if "check(s) on this head did not pass. Auto-merge" in stripped:
        replaced["annot_sum"] += 1
        out.append(
            ln.replace(
                "::error title=A check on this head did not pass::${nbad}",
                "::error::${nbad}",
            )
        )
        i += 1
        continue
    out.append(ln)
    i += 1

for what, n in replaced.items():
    assert n == 1, f"the control restored {what} {n} time(s) — the shipped shape moved"
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out))
PY

# ---- the mocks: the API, the clock, the sleep --------------------------------------
mkdir -p "$STATE/bin"
cat >"$STATE/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -u
if [[ "${MOCK_CURL_MODE:-ok}" == fail ]]; then
  printf 'curl: (22) The requested URL returned error: 500\n' >&2
  exit 22
fi
mapfile -t files <"${MOCK_CURL_SEQ:?}"
n="$(cat "${MOCK_CURL_COUNTER:?}")"
idx=$n
(( idx < ${#files[@]} )) || idx=$(( ${#files[@]} - 1 ))
printf '%s' "$(( n + 1 ))" >"${MOCK_CURL_COUNTER:?}"
cat "${files[$idx]}"
MOCK
cat >"$STATE/bin/date" <<'MOCK'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == "+%s" ]]; then cat "${MOCK_CLOCK:?}"; else exec /usr/bin/date "$@"; fi
MOCK
cat >"$STATE/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
set -u
now="$(cat "${MOCK_CLOCK:?}")"
printf '%s' "$(( now + ${MOCK_CLOCK_STEP:-1} ))" >"${MOCK_CLOCK:?}"
MOCK
chmod +x "$STATE/bin/curl" "$STATE/bin/date" "$STATE/bin/sleep"

# ---- the fixtures ------------------------------------------------------------------
# Every fixture but one carries the gate's own check ("validate / arm"), which the
# gate EXCLUDES: it is in flight for the whole poll, so counting it would make every
# PR wait out the budget. The exception is fx-empty.json, which carries NO check at
# all — that is the point of it.
cat >"$STATE/fx-green.json" <<'JSON'
{"check_runs":[
 {"id":101,"name":"validate / validate","status":"completed","conclusion":"success","app":{"slug":"github-actions"}},
 {"id":102,"name":"validate / lint","status":"completed","conclusion":"success","app":{"slug":"github-actions"}},
 {"id":103,"name":"go","status":"completed","conclusion":"success","app":{"slug":"github-actions"}},
 {"id":104,"name":"validate / arm","status":"in_progress","conclusion":null,"app":{"slug":"github-actions"}}
]}
JSON
cat >"$STATE/fx-bad.json" <<'JSON'
{"check_runs":[
 {"id":101,"name":"validate / validate","status":"completed","conclusion":"success","app":{"slug":"github-actions"}},
 {"id":102,"name":"validate / lint","status":"completed","conclusion":"success","app":{"slug":"github-actions"}},
 {"id":103,"name":"go","status":"completed","conclusion":"failure","app":{"slug":"github-actions"}},
 {"id":104,"name":"validate / arm","status":"in_progress","conclusion":null,"app":{"slug":"github-actions"}}
]}
JSON
cat >"$STATE/fx-pending.json" <<'JSON'
{"check_runs":[
 {"id":101,"name":"validate / validate","status":"completed","conclusion":"success","app":{"slug":"github-actions"}},
 {"id":103,"name":"pin-currency","status":"in_progress","conclusion":null,"app":{"slug":"github-actions"}},
 {"id":104,"name":"validate / arm","status":"in_progress","conclusion":null,"app":{"slug":"github-actions"}}
]}
JSON
# The same head as fx-pending.json, one poll later: the slow sibling has settled.
cat >"$STATE/fx-settled.json" <<'JSON'
{"check_runs":[
 {"id":101,"name":"validate / validate","status":"completed","conclusion":"success","app":{"slug":"github-actions"}},
 {"id":103,"name":"pin-currency","status":"completed","conclusion":"success","app":{"slug":"github-actions"}},
 {"id":104,"name":"validate / arm","status":"in_progress","conclusion":null,"app":{"slug":"github-actions"}}
]}
JSON
printf '%s\n' "$STATE/fx-green.json" >"$STATE/seq-green.txt"
printf '%s\n' "$STATE/fx-bad.json" >"$STATE/seq-bad.txt"
printf '%s\n' "$STATE/fx-pending.json" >"$STATE/seq-pending.txt"
# The EMPTY SET (opencharly/.github#248). The body is NOT empty — it is a well-formed
# answer from the API that reports ZERO check runs — so it passes the snapshot's
# body-guard, and the filter yields {pending:[], bad:[], all:[], total:0}. Every
# count reads 0, so before #248 the step fell through to "all 0 check run(s) on this
# head passed — safe to arm auto-merge" with exit 0.
cat >"$STATE/fx-empty.json" <<'JSON'
{"total_count":0,"check_runs":[]}
JSON
printf '%s\n' "$STATE/fx-empty.json" >"$STATE/seq-empty.txt"
# The slow sibling: 37 polls in flight, then it settles. Each poll advances the mock
# clock by 100 s, so it settles at t=3700 s — LATER than the pre-#229 budget
# (3600 s) and INSIDE the derived one (4200 - 300 = 3900 s). The gap between the
# two budgets is where the old shape called a still-running check a failure.
: >"$STATE/seq-slow37.txt"
n=0
while [ "$n" -lt 37 ]; do
  printf '%s\n' "$STATE/fx-pending.json" >>"$STATE/seq-slow37.txt"
  n=$(( n + 1 ))
done
printf '%s\n' "$STATE/fx-settled.json" >>"$STATE/seq-slow37.txt"

# ---- the runner --------------------------------------------------------------------
# run_settle <out> <step-file> <backstop> <margin> <seq> <clock-step> [curl-mode]
# The clock step compresses the wall clock so the budget arithmetic is exercised at
# speed; the DEADLINE comparison and the class are the shipped ones.
run_settle() {
  local out="$1" step="$2" backstop="$3" margin="$4" seq="$5" step_size="$6" mode="${7:-ok}"
  printf '0' >"$STATE/clock"
  printf '0' >"$STATE/counter"
  local rc=0
  (
    export PATH="$STATE/bin:$PATH"
    export MOCK_CLOCK="$STATE/clock" MOCK_CURL_COUNTER="$STATE/counter" MOCK_CURL_SEQ="$seq"
    export MOCK_CLOCK_STEP="$step_size" MOCK_CURL_MODE="$mode"
    export GITHUB_API_URL="https://api.github.com" GITHUB_REPOSITORY="opencharly/charly"
    export GITHUB_RUN_ID="4242" GH_TOKEN="test-token" HEAD_SHA="deadbeef"
    export SETTLE_BACKSTOP_SECONDS="$backstop" SETTLE_REPORT_MARGIN_SECONDS="$margin"
    export SETTLE_POLL_INTERVAL_SECONDS="1"
    # The pre-#229 shape read its budget from this variable; the shipped shape must
    # NOT read it, and the invariant below asserts that.
    export WAIT_BUDGET_SECONDS="$LEGACY_BUDGET_SECONDS"
    # The workflow's own shell for a `run:` with no `shell:` key is `bash -e`.
    bash -e "$step"
  ) >"$out" 2>&1 || rc=$?
  return $rc
}

# ---- (A) GREEN: every check passed -> 0 --------------------------------------------
rc=0
run_settle "$STATE/a.out" "$STATE/step.sh" 4200 300 "$STATE/seq-green.txt" 100 || rc=$?
[[ "$rc" == 0 ]] \
  || { echo "FAIL: (A) a green head must exit 0 (got $rc)" >&2; cat "$STATE/a.out" >&2; exit 1; }
grep -q 'safe to arm auto-merge' "$STATE/a.out" \
  || { echo "FAIL: (A) the green path must say it is safe to arm" >&2; cat "$STATE/a.out" >&2; exit 1; }
grep -q 'validate / arm' "$STATE/a.out" \
  && { echo "FAIL: (A) the gate must EXCLUDE its own check from the report" >&2; exit 1; }
echo "ok  (A) GREEN            -> exit 0  ($(grep -m1 'check run(s) on this head passed' "$STATE/a.out" | tr -s ' '))"

# ---- (B) NOT-PASSED: a check failed -> 1, and it IS a finding ----------------------
rc=0
run_settle "$STATE/b.out" "$STATE/step.sh" 4200 300 "$STATE/seq-bad.txt" 100 || rc=$?
[[ "$rc" == 1 ]] \
  || { echo "FAIL: (B) a failed check must exit 1 (got $rc)" >&2; cat "$STATE/b.out" >&2; exit 1; }
grep -q 'go -> failure' "$STATE/b.out" \
  || { echo "FAIL: (B) the failure must name the check" >&2; cat "$STATE/b.out" >&2; exit 1; }
grep -q 'did not pass' "$STATE/b.out" \
  || { echo "FAIL: (B) the failure must say the check did not pass" >&2; exit 1; }
grep -q 'NOT a finding about the change' "$STATE/b.out" \
  && { echo "FAIL: (B) a failed check IS a finding — it must not claim otherwise" >&2; exit 1; }
echo "ok  (B) NOT-PASSED       -> exit 1  ($(grep -m1 'go -> failure' "$STATE/b.out" | tr -s ' '))"

# ---- (C) IN-FLIGHT: a check is still RUNNING -> 2, and it is NOT a finding ---------
rc=0
run_settle "$STATE/c.out" "$STATE/step.sh" 4200 300 "$STATE/seq-pending.txt" 100 || rc=$?
[[ "$rc" == 2 ]] \
  || { echo "FAIL: (C) a still-running check must exit 2, not 1 (got $rc)" >&2; cat "$STATE/c.out" >&2; exit 1; }
grep -q 'NOT a finding about the change' "$STATE/c.out" \
  || { echo "FAIL: (C) the in-flight class must say it is not a finding" >&2; cat "$STATE/c.out" >&2; exit 1; }
grep -q 'Re-run ONLY this job' "$STATE/c.out" \
  || { echo "FAIL: (C) the in-flight class must name its remedy" >&2; cat "$STATE/c.out" >&2; exit 1; }
grep -q 'gh run rerun --job' "$STATE/c.out" \
  || { echo "FAIL: (C) the remedy must be the cheap one — this job only" >&2; exit 1; }
echo "ok  (C) IN-FLIGHT        -> exit 2  ($(grep -m1 'still in flight after' "$STATE/c.out" | tr -s ' '))"

# ---- (D) UNREAD: the API read fails -> 3, and it refuses to arm -------------------
rc=0
run_settle "$STATE/d.out" "$STATE/step.sh" 4200 300 "$STATE/seq-green.txt" 100 fail || rc=$?
[[ "$rc" == 3 ]] \
  || { echo "FAIL: (D) an unreadable head must exit 3 (got $rc)" >&2; cat "$STATE/d.out" >&2; exit 1; }
grep -q 'refusing to arm auto-merge on an unread head' "$STATE/d.out" \
  || { echo "FAIL: (D) the unread head must be refused by name" >&2; cat "$STATE/d.out" >&2; exit 1; }
grep -q 'safe to arm auto-merge' "$STATE/d.out" \
  && { echo "FAIL: (D) an unread head must NEVER reach the arming line" >&2; exit 1; }
echo "ok  (D) UNREAD           -> exit 3  ($(grep -m1 'could not read the check runs' "$STATE/d.out" | tr -s ' '))"

# ---- (E) the budget, and the class it decides -------------------------------------
# (E1) the DERIVED budget (4200 backstop - 300 margin = 3900 s) waits the slow
# sibling out: the head is green by the time it settles at 3700 s.
rc=0
run_settle "$STATE/e1.out" "$STATE/step.sh" 4200 300 "$STATE/seq-slow37.txt" 100 || rc=$?
[[ "$rc" == 0 ]] \
  || { echo "FAIL: (E1) the derived budget must wait out a slow sibling (got $rc)" >&2; cat "$STATE/e1.out" >&2; exit 1; }
echo "ok  (E1) derived budget  -> exit 0  (the slow sibling settled inside it: $(grep -m1 'check run(s) on this head passed' "$STATE/e1.out" | tr -s ' '))"
# (E2) the SAME head at the pre-#229 budget (the margin is the knob that reproduces
# it: 4200 - 600 = 3600): the sibling is still running when the wait ends, so the
# head is IN-FLIGHT — a distinct class, and NOT a failure of the change.
rc=0
run_settle "$STATE/e2.out" "$STATE/step.sh" 4200 600 "$STATE/seq-slow37.txt" 100 || rc=$?
[[ "$rc" == 2 ]] \
  || { echo "FAIL: (E2) the pre-#229 budget must yield the in-flight class (got $rc)" >&2; cat "$STATE/e2.out" >&2; exit 1; }
echo "ok  (E2) pre-#229 budget -> exit 2  (the SAME head, the pre-#229 budget: $(grep -m1 'still in flight after' "$STATE/e2.out" | tr -s ' '))"
# (E3) the pre-#229 SHAPE on the SAME head at the SAME budget: it exits 1 — the same
# status as a FAILED check — and names the whole-validator re-run as the remedy.
rc=0
run_settle "$STATE/e3.out" "$STATE/step-legacy.sh" 4200 600 "$STATE/seq-slow37.txt" 100 || rc=$?
[[ "$rc" == 1 ]] \
  || { echo "FAIL: (E3) the pre-#229 shape must report the same head as a failure (got $rc)" >&2; cat "$STATE/e3.out" >&2; exit 1; }
grep -q 're-evaluates it' "$STATE/e3.out" \
  || { echo "FAIL: (E3) the pre-#229 shape must carry the old remedy — a whole-validator re-run" >&2; exit 1; }
echo "ok  (E3) the pre-#229 shape -> exit 1  (the SAME head, the SAME budget: reported as a FAILURE, with the old whole-validator remedy)"

# ---- (F) the invariants ------------------------------------------------------------
step_timeout="$(sed -n 's/^ *timeout-minutes: *\([0-9]\+\).*/\1/p' "$STATE/step.yaml" | head -1)"
backstop="$(sed -n "s/^ *SETTLE_BACKSTOP_SECONDS: *'\([0-9]\+\)'.*/\1/p" "$STATE/step.yaml" | head -1)"
margin="$(sed -n 's/.*SETTLE_REPORT_MARGIN_SECONDS:-\([0-9]\+\).*/\1/p' "$STATE/step.sh" | head -1)"
[[ -n "$step_timeout" && -n "$backstop" && -n "$margin" ]] \
  || { echo "FAIL: (F) the step must declare its timeout-minutes, its backstop and its margin" >&2; exit 1; }
[[ $(( step_timeout * 60 )) == "$backstop" ]] \
  || { echo "FAIL: (F) the backstop must be the step's own timeout (${step_timeout}m != ${backstop}s)" >&2; exit 1; }
budget=$(( backstop - margin ))
[[ "$budget" -eq $(( backstop - margin )) ]] \
  || { echo "FAIL: (F) the budget must be the backstop minus the margin" >&2; exit 1; }
[[ "$budget" -gt "$SLOWEST_SIBLING_SECONDS" ]] \
  || { echo "FAIL: (F) the derived budget (${budget}s) must exceed the slowest measured sibling (${SLOWEST_SIBLING_SECONDS}s)" >&2; exit 1; }
grep -q 'budget=$(( backstop - margin ))' "$STATE/step.sh" \
  || { echo "FAIL: (F) the budget must be DERIVED from the backstop" >&2; exit 1; }
grep -q 'WAIT_BUDGET_SECONDS' "$STATE/step.sh" \
  && { echo "FAIL: (F) the legacy, independently hard-coded budget must be gone" >&2; exit 1; }
echo "ok  (F) invariants      -> backstop ${backstop}s == ${step_timeout}m timeout, derived budget ${budget}s (backstop - ${margin}s margin) > ${SLOWEST_SIBLING_SECONDS}s (slowest measured sibling)"

# ---- (G) THE NEGATIVE CONTROL: the coverage can fire --------------------------------
# The pre-#229 shape on an UNREADABLE head: the unchecked `curl | jq` pipeline
# swallowed the failed API read, the snapshot was EMPTY rather than missing, every
# count read from it was the empty STRING, and the step fell through to the arming
# line with exit 0 — so the "Enable auto-merge" step that follows this one RAN, and
# auto-merge was enabled on a head whose checks the gate had never read. The
# pre-#229 guard ("refusing to arm auto-merge on an unread head") was UNREACHABLE.
# The shipped shape refuses. This is the hole the change closes, and the test must
# keep it closed.
rc=0
run_settle "$STATE/g1.out" "$STATE/step-legacy.sh" 4200 300 "$STATE/seq-green.txt" 100 fail || rc=$?
[[ "$rc" == 0 ]] \
  || { echo "FAIL: (G1) the pre-#229 shape must exit 0 on an unreadable head (got $rc) — the control is stale" >&2; cat "$STATE/g1.out" >&2; exit 1; }
grep -q 'safe to arm auto-merge' "$STATE/g1.out" \
  || { echo "FAIL: (G1) the pre-#229 shape must reach the arming line on an unreadable head — the control is stale" >&2; cat "$STATE/g1.out" >&2; exit 1; }
echo "ok  (G1) the pre-#229 shape -> exit 0  (an unread head reached 'safe to arm auto-merge' — the hole)"
# The pre-#229 shape carried the whole-validator remedy; the shipped one names the
# cheap one (re-run this job only) and must not carry the old wording.
grep -q 're-evaluates it' "$STATE/step-legacy.sh" \
  || { echo "FAIL: (G2) the control must carry the old remedy — it is what the old shape said" >&2; exit 1; }
grep -q 're-evaluates it' "$STATE/step.sh" \
  && { echo "FAIL: (G2) the shipped shape must NOT name a whole-validator re-run" >&2; exit 1; }
grep -q 're-evaluates it' "$STATE/c.out" \
  && { echo "FAIL: (G2) the shipped in-flight class must NOT name a whole-validator re-run" >&2; exit 1; }
echo "ok  (G2) the remedy       -> the pre-#229 shape names a whole-validator re-run; the shipped one names this job only"
echo "ok  (G3) the shipped text -> exit 3 (an unread head NEVER reaches the arming line)"

# ---- (H) THE EMPTY SET: the gate must not be satisfied by observing NOTHING -------
# (opencharly/.github#248). The snapshot's guard is on the BODY, so a well-formed
# answer that reports ZERO check runs passes it; the filter yields an all-zero
# snapshot; every count reads 0; and the step falls through to "all 0 check run(s) on
# this head passed — safe to arm auto-merge" with exit 0. The gate was then satisfied
# by observing nothing — the same fail-open shape #247 removed for the empty body,
# one level down.
#
# And the empty set is not a legitimate state for THIS job: `arm` has
# `needs: [validate, lint]`, so the `validate` job — the required context — has
# completed by the time this step reads the head, and it left a check run on it.
# Only this job's own run is excluded. A total of 0 means the head's check runs are
# not VISIBLE here — not that the head is green.
rc=0
run_settle "$STATE/h1.out" "$STATE/step.sh" 4200 300 "$STATE/seq-empty.txt" 100 || rc=$?
[[ "$rc" == 4 ]] \
  || { echo "FAIL: (H1) an empty check set must exit 4, not 0 (got $rc)" >&2; cat "$STATE/h1.out" >&2; exit 1; }
grep -q 'safe to arm auto-merge' "$STATE/h1.out" \
  && { echo "FAIL: (H1) an empty check set must NEVER reach the arming line" >&2; cat "$STATE/h1.out" >&2; exit 1; }
grep -q 'no check run to judge' "$STATE/h1.out" \
  || { echo "FAIL: (H1) the empty set must be refused by name" >&2; cat "$STATE/h1.out" >&2; exit 1; }
grep -q 'NOT a finding about the change' "$STATE/h1.out" \
  || { echo "FAIL: (H1) the empty set is NOT a finding about the change — it must say so" >&2; exit 1; }
echo "ok  (H1) EMPTY           -> exit 4  ($(grep -m1 'no check run to judge' "$STATE/h1.out" | tr -s ' '))"

# (H2) THE NEGATIVE CONTROL for #248: the shipped text with EXACTLY the class-4
# block removed — the pre-#248 shape — on the SAME empty set reaches the arming line
# with exit 0. This is the hole, isolated to this one change: if the guard is removed
# again, the control proves the coverage can fire.
rc=0
run_settle "$STATE/h2.out" "$STATE/step-248.sh" 4200 300 "$STATE/seq-empty.txt" 100 || rc=$?
[[ "$rc" == 0 ]] \
  || { echo "FAIL: (H2) the pre-#248 shape must exit 0 on an empty check set (got $rc) — the control is stale" >&2; cat "$STATE/h2.out" >&2; exit 1; }
grep -q 'safe to arm auto-merge' "$STATE/h2.out" \
  || { echo "FAIL: (H2) the pre-#248 shape must reach the arming line on an empty check set — the control is stale" >&2; cat "$STATE/h2.out" >&2; exit 1; }
grep -q 'all 0 check run(s) on this head passed' "$STATE/h2.out" \
  || { echo "FAIL: (H2) the pre-#248 shape must report ZERO observed checks as the arming reason — the control is stale" >&2; cat "$STATE/h2.out" >&2; exit 1; }
echo "ok  (H2) the pre-#248 shape -> exit 0  (an EMPTY set reached 'safe to arm auto-merge' — the hole)"

# (H3) the older pre-#229 shape has the same hole, for the same reason: its counts
# also read 0 on an empty set. Asserted so the defect's history is on the record.
rc=0
run_settle "$STATE/h3.out" "$STATE/step-legacy.sh" 4200 300 "$STATE/seq-empty.txt" 100 || rc=$?
[[ "$rc" == 0 ]] \
  || { echo "FAIL: (H3) the pre-#229 shape must exit 0 on an empty check set (got $rc) — the control is stale" >&2; cat "$STATE/h3.out" >&2; exit 1; }
grep -q 'safe to arm auto-merge' "$STATE/h3.out" \
  || { echo "FAIL: (H3) the pre-#229 shape must reach the arming line on an empty check set — the control is stale" >&2; exit 1; }
echo "ok  (H3) the pre-#229 shape -> exit 0  (the same hole, one shape older)"

# The class table in the shipped text must NAME the class it implements, so the
# exit code and its meaning cannot drift apart.
grep -q '4 EMPTY' "$STATE/step.sh" \
  || { echo "FAIL: (H4) the shipped class table must name the EMPTY class" >&2; exit 1; }
grep -q '4 EMPTY' "$STATE/step-248.sh" \
  && { echo "FAIL: (H4) the pre-#248 control must NOT carry the EMPTY class" >&2; exit 1; }
echo "ok  (H4) the class table  -> 4 EMPTY is named in the shipped text, and absent from the pre-#248 control"

echo "head-settle_test: all assertions passed"
