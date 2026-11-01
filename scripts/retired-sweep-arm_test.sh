#!/usr/bin/env bash
# The org-wide SWEEP arm's own coverage (opencharly/opencharly#799, LEG C).
#
# WHY THE COVERAGE WORKS ON THE SHIPPED TEXT. The sweep runs inside the reusable
# validator, in the CALLER's repository: the reusable never checks out
# opencharly/.github, so a script in this repo does not exist in the caller's
# workspace and could not be the thing the caller runs. The coverage therefore
# EXTRACTS the shipped step's `run:` text out of .github/workflows/pr-validator.yml
# and RUNS THAT TEXT against fixtures — the same pattern scripts/head-settle_test.sh
# uses for the settle gate. The text under test IS the shipped text, so the two
# cannot drift.
#
# THE PIN IS NOT COPIED HERE. The contract's tag is READ out of the workflow the
# same way the step's text is, so this test follows the pin instead of asserting a
# second copy of it: two copies of a pin is how a pin drifts.
#
# WHAT IT PROVES — each case is a DISCRIMINATION, and the tree is built so that the
# rule decides the verdict:
#   * a CLEAN tree passes (exit 0): the arm must not redden the org for nothing;
#   * a tree carrying a CARRIER fails (exit 1) and NAMES it: the arm can go red, so
#     it is a gate and not a report;
#   * in opencharly/.github the records table is a FILE OF THE TREE, so it is read
#     from the tree and is not itself judged as a surface — a table update is then
#     judged by the table it updates;
#   * in every OTHER repository the table is read from the org checkout, OUTSIDE
#     the tree, and the tree is swept in full: a repository that carries a file at
#     the table's own path still has that file judged, so the arm has no hole for
#     a carrier to hide in;
#   * a hit the table COVERS is a RECORD and does not fail the arm, and a record
#     that covers NO hit is itself a finding: the table is a live classification,
#     not a list of excuses;
#   * the sweep is a STEP of the required `validate` job, and every step of it
#     carries the same-repository guard: a sweep in a job of its own would be
#     DEFEATABLE, because GitHub reports a SKIPPED job to the merge gate as a
#     SUCCESS.
#
# THE NEGATIVE CONTROLS AT THE END prove the coverage can FAIL: each one mutates
# the shipped workflow in a copy, and the mutated workflow must turn this coverage
# RED. A control that stayed green would mean the assertion it exercises is a
# tautology, and a tautology is not coverage (R7).
#
# usage: scripts/retired-sweep-arm_test.sh [--workflow <path>] [--contract <dir>]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
WF="$root/.github/workflows/pr-validator.yml"
TABLE="$root/scripts/retired-records.json"
CONTRACT_URL="https://github.com/opencharly/spec.git"
CONTRACT_DIR=""
FIXTURE_REPO="opencharly/example-repo"
SKIP_CONTROLS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workflow) WF="$2"; shift 2 ;;
    --contract) CONTRACT_DIR="$2"; shift 2 ;;
    --no-controls) SKIP_CONTROLS=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---- the shipped text under test --------------------------------------------------
awk '
  function indent(s,   i) { for (i = 1; i <= length(s); i++) if (substr(s, i, 1) != " ") return i - 1; return length(s) }
  /^ *- name: Sweep the tree for withdrawn identifiers$/ { in_step = 1; next }
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
  || fail "the shipped sweep step was not found in $WF"
grep -q 'retired-sweep' "$STATE/step.sh" \
  || fail "the extracted step runs no sweep — the extraction drifted"

# The pinned contract tag, read out of the workflow — the SAME place the step reads
# it, so this test never holds a second copy of the pin. The shipped step clones
# the tag without a credential, so the tag is read out of the clone command.
PIN="$(awk '
  /^ *- name: Fetch the pinned contract$/ { in_step = 1; next }
  in_step && /^ *- name: / { exit }
  in_step && /--branch/ { for (i = 1; i <= NF; i++) if ($i == "--branch") { print $(i + 1); exit } }
' "$WF")"
[[ -n "$PIN" ]] || fail "the contract's pinned tag was not found in $WF"
case "$PIN" in
  v[0-9]*) ;;
  *) fail "the contract's pin '$PIN' is not a tag" ;;
esac

# ---- the sweep lives INSIDE the required `validate` job, and every step of it is
#      guarded against a fork's head -------------------------------------------------
# WHY THIS IS A STATIC ASSERTION AND NOT A RUNTIME ONE. The arm's power is its
# POSITION: the required check is `validate / validate`, and GitHub reports a
# SKIPPED job to the merge gate as a SUCCESS — so a sweep in a job of its own,
# with the review job declared `needs: sweep`, would be defeatable (the sweep
# fails, the review is skipped, the PR merges on a green required check). The
# position is a property of the FILE, and a runtime fixture cannot see it.
awk '
  /^jobs:$/ { in_jobs = 1; next }
  in_jobs && /^  [a-zA-Z0-9_-]+: *$/ { job = $1; sub(/:$/, "", job); next }
  /- name: Sweep the tree for withdrawn identifiers$/ { print job; exit }
' "$WF" >"$STATE/job.txt"
SWEEP_JOB="$(cat "$STATE/job.txt")"
[[ "$SWEEP_JOB" == "validate" ]] \
  || fail "the sweep step lives in the job '$SWEEP_JOB', not in 'validate' — a job of its own is defeatable (a skipped job counts as a success)"

# Every step of the arm carries the same-repository guard: a fork's head SHA is
# not in this repository, so the tree under judgement cannot be checked out there.
guard_count="$(awk '
  /^ *- name: (Check out the tree under judgement|Fetch the pinned contract|Fetch the org.s retired-records table|Set up Go \(the contract.s sweep is a Go command\)|Sweep the tree for withdrawn identifiers)$/ { in_step = 1; guarded = 0; next }
  in_step && /^ *if: github\.event\.pull_request\.head\.repo\.full_name == github\.repository$/ { guarded = 1; next }
  in_step && /^ *- name: / { if (guarded) n++; in_step = 0; guarded = 0; next }
  in_step && /^ *[a-z-]+:/ { if (guarded) { n++; in_step = 0; guarded = 0 } }
  END { print n + 0 }
' "$WF")"
[[ "$guard_count" -eq 5 ]] \
  || fail "$guard_count of the arm's 5 steps carry the same-repository guard — a fork's head would break the checkout"

# ---- the contract at that pin -----------------------------------------------------
mkdir -p "$STATE/ws"
if [[ -n "$CONTRACT_DIR" ]]; then
  cp -a "$CONTRACT_DIR" "$STATE/ws/contract"
else
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$PIN" "$CONTRACT_URL" "$STATE/ws/contract" \
    || fail "the pinned contract tag $PIN could not be checked out"
fi
[[ -f "$STATE/ws/contract/retired/cmd/retired-sweep/main.go" ]] \
  || fail "the pinned contract carries no retired-sweep command"

# ---- the withdrawn name is DERIVED, never copied -----------------------------------
# The registry the contract publishes is the ONE list of withdrawn names, so the
# coverage READS it instead of holding a second copy (R2: two copies of one rule
# is how the copies drift). Copying the name would also make THIS repo a
# carrier of it — the name has to be spelled somewhere to be planted in a
# fixture, and spelling it here would put it in the tree this arm sweeps.
#
# The name picked is the FIRST UNSCOPED config-key in the registry: unscoped,
# because a scoped name is only swept inside its own Go type and would never
# appear in a text fixture; a config-key, because that is the shape a YAML
# fixture plants.
WITHDRAWN="$(python3 - "$STATE/ws/contract/retired/identifiers.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    registry = json.load(handle)
for entry in registry["identifiers"]:
    if entry.get("type"):
        continue
    if entry["kind"] != "config-key":
        continue
    print(entry["name"])
    break
PY
)"
[[ -n "$WITHDRAWN" ]] \
  || fail "the pinned contract's registry publishes no unscoped config-key to plant"
# The planted fixture is the ONLY place the name appears in this repo, and it
# appears in a TEMPORARY tree, not in this file.
plant() {
  printf 'defaults:\n  %s: 4\n' "$WITHDRAWN" >"$1"
}

# The org's table, in the org checkout — the layout the job builds.
mkdir -p "$STATE/ws/org-rules/scripts"
cp "$TABLE" "$STATE/ws/org-rules/scripts/retired-records.json"

# reset_tree empties the tree under judgement.
reset_tree() {
  rm -rf "$STATE/ws/repo"
  mkdir -p "$STATE/ws/repo/candy/plugin-x"
}

# run_sweep runs the SHIPPED text with the job's own working directory.
run_sweep() {
  ( cd "$STATE/ws/contract" && GITHUB_REPOSITORY="$1" bash "$STATE/step.sh" ) 2>&1
}

# ---- case 1: a clean tree passes ---------------------------------------------------
reset_tree
out="$(run_sweep "$FIXTURE_REPO")" && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || fail "a clean tree must pass, got exit $rc: $out"
grep -q 'PASS' <<<"$out" || fail "a clean tree must report a PASS verdict: $out"

# ---- case 2: a carrier fails the arm, and is named ----------------------------------
reset_tree
plant "$STATE/ws/repo/candy/plugin-x/charly.yml"
out="$(run_sweep "$FIXTURE_REPO")" && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || fail "a tree carrying a withdrawn name must fail the arm, got exit $rc: $out"
grep -q 'CARRIER' <<<"$out" || fail "the carrier must be named in the output: $out"
grep -q 'candy/plugin-x/charly.yml' <<<"$out" || fail "the carrier must name its file: $out"
reset_tree

# ---- case 3: in the org's own repo the table is a file OF THE TREE -----------------
# The tree's own copy of the table NAMES the withdrawn names, so a control that
# failed to exclude it would report carriers — this case discriminates.
reset_tree
mkdir -p "$STATE/ws/repo/scripts"
cp "$TABLE" "$STATE/ws/repo/scripts/retired-records.json"
out="$(run_sweep "opencharly/.github")" && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] \
  || fail "in opencharly/.github the table is a file of the tree and must not be judged as a surface: $out"
# ...and a carrier in that tree is still a carrier.
plant "$STATE/ws/repo/candy/plugin-x/charly.yml"
out="$(run_sweep "opencharly/.github")" && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || fail "a carrier in opencharly/.github must fail the arm, got exit $rc: $out"
reset_tree

# ---- case 4: in every other repo the tree is swept in FULL --------------------------
# The table's own path in a swept tree is NOT a hole: the file is judged like any
# other file of that tree, because the table is read from OUTSIDE that tree.
reset_tree
mkdir -p "$STATE/ws/repo/scripts"
printf '{"note": "%s"}\n' "$WITHDRAWN" >"$STATE/ws/repo/scripts/retired-records.json"
out="$(run_sweep "$FIXTURE_REPO")" && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] \
  || fail "a withdrawn name at the table's own path must still fail the arm, got exit $rc: $out"
reset_tree

# ---- case 5: the table CLASSIFIES a hit: covered is a RECORD, uncovered is stale ----
# The table used here is a purpose-built one, so the case proves the MECHANISM and
# not today's table's contents; the org's real table is proven against the real
# trees by the org-wide sweep.
cat >"$STATE/ws/org-rules/scripts/retired-records.json" <<JSON
{
  "records": [
    {
      "repo": "$FIXTURE_REPO",
      "file": "candy/plugin-x/charly.yml",
      "identifier": "$WITHDRAWN",
      "contains": "$WITHDRAWN: 4",
      "why": "the fixture exercises the retired key on purpose"
    }
  ]
}
JSON
reset_tree
plant "$STATE/ws/repo/candy/plugin-x/charly.yml"
out="$(run_sweep "$FIXTURE_REPO")" && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] || fail "a hit the table covers must not fail the arm, got exit $rc: $out"
grep -q 'RECORD' <<<"$out" || fail "a covered hit must be reported as a RECORD: $out"

# The same table over a tree the record no longer describes: the record covers no
# hit, and a record that covers nothing is ITSELF a finding.
printf 'defaults:\n  other: 1\n' >"$STATE/ws/repo/candy/plugin-x/charly.yml"
out="$(run_sweep "$FIXTURE_REPO")" && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] || fail "a record that covers no hit must fail the arm, got exit $rc: $out"
grep -q 'STALE' <<<"$out" || fail "the stale record must be named in the output: $out"

# ---- the NEGATIVE CONTROLS: the coverage must be able to FAIL ------------------------
# Each control is the shipped workflow with ONE thing changed, in a copy. The
# mutated workflow must turn this coverage RED — otherwise the assertion it
# exercises is a tautology, and a tautology is not coverage (R7).
if [[ "$SKIP_CONTROLS" -eq 0 ]]; then
  CONTROLS="$STATE/controls"
  mkdir -p "$CONTROLS"

  # control 1: the sweep moved OUT of the required `validate` job.
  python3 - "$WF" "$CONTROLS/moved.yml" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("      # THE SWEEP — the org-wide reach for a WITHDRAWN NAME.")
end = text.index("      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7, node24\n        with:\n          repository: opencharly/action-review")
block = text[start:end]
moved = text[:start] + text[end:]
# The same block, one job over: a job of its own, with the review job skipped
# when it fails — the shape GitHub reports to the merge gate as a SUCCESS.
job = "  sweep:\n    runs-on: ubuntu-latest\n    steps:\n" + "".join(
    ("  " + line if line.strip() else line) + "\n" for line in block.rstrip("\n").split("\n")
)
moved = moved.replace("  validate:\n", job + "\n  validate:\n", 1)
open(sys.argv[2], "w", encoding="utf-8").write(moved)
PY
  if bash "$0" --workflow "$CONTROLS/moved.yml" --contract "$STATE/ws/contract" --no-controls >"$CONTROLS/moved.log" 2>&1; then
    fail "NEGATIVE CONTROL: a sweep in a job of its own must fail this coverage, but it passed"
  fi
  grep -q "not in 'validate'" "$CONTROLS/moved.log" \
    || { cat "$CONTROLS/moved.log"; fail "the moved-job control failed for the wrong reason"; }

  # control 2: one of the arm's steps lost the same-repository guard.
  python3 - "$WF" "$CONTROLS/unguarded.yml" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
needle = "      - name: Sweep the tree for withdrawn identifiers\n        if: github.event.pull_request.head.repo.full_name == github.repository\n"
assert needle in text, "the shipped shape moved"
open(sys.argv[2], "w", encoding="utf-8").write(text.replace(needle, "      - name: Sweep the tree for withdrawn identifiers\n", 1))
PY
  if bash "$0" --workflow "$CONTROLS/unguarded.yml" --contract "$STATE/ws/contract" --no-controls >"$CONTROLS/unguarded.log" 2>&1; then
    fail "NEGATIVE CONTROL: an unguarded step must fail this coverage, but it passed"
  fi
  grep -q "same-repository guard" "$CONTROLS/unguarded.log" \
    || { cat "$CONTROLS/unguarded.log"; fail "the unguarded control failed for the wrong reason"; }

  # control 3: the contract's pin is no longer a tag.
  python3 - "$WF" "$CONTROLS/floating.yml" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
needle = "          git clone --depth 1 --branch v"
i = text.index(needle)
j = text.index("\n", i)
open(sys.argv[2], "w", encoding="utf-8").write(text[:i] + "          git clone --depth 1 --branch main" + text[j:])
PY
  if bash "$0" --workflow "$CONTROLS/floating.yml" --contract "$STATE/ws/contract" --no-controls >"$CONTROLS/floating.log" 2>&1; then
    fail "NEGATIVE CONTROL: a floating contract ref must fail this coverage, but it passed"
  fi
  grep -q "is not a tag" "$CONTROLS/floating.log" \
    || { cat "$CONTROLS/floating.log"; fail "the floating-ref control failed for the wrong reason"; }

  # control 4: the org's own repo no longer reads the table from its OWN tree, so
  # the tree's copy of the table is judged as a surface and the sweep reports it.
  python3 - "$WF" "$CONTROLS/no-own-table.yml" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
needle = '          if [ "$GITHUB_REPOSITORY" = "opencharly/.github" ]; then\n            records="../repo/scripts/retired-records.json"\n          fi\n'
assert needle in text, "the shipped shape moved"
open(sys.argv[2], "w", encoding="utf-8").write(text.replace(needle, "", 1))
PY
  if bash "$0" --workflow "$CONTROLS/no-own-table.yml" --contract "$STATE/ws/contract" --no-controls >"$CONTROLS/no-own-table.log" 2>&1; then
    fail "NEGATIVE CONTROL: reading the table from outside the org's own tree must fail this coverage, but it passed"
  fi
  grep -q "must not be judged as a surface" "$CONTROLS/no-own-table.log" \
    || { cat "$CONTROLS/no-own-table.log"; fail "the no-own-table control failed for the wrong reason"; }
fi

echo "retired-sweep-arm_test: OK (clean tree passes; a carrier fails and is named; the table is read from the tree in opencharly/.github and from the org checkout everywhere else; a covered hit is a RECORD and a stale record fails; the sweep is a guarded step of the required validate job)"
