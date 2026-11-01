#!/usr/bin/env bash
# The ORG-RULEBOOK ASSERT's own coverage (opencharly/opencharly#799, LEG C;
# opencharly/.github#262 round 2).
#
# WHAT IS UNDER TEST. The reusable validator's `validate` job opens with a step that
# asserts the ORG RULEBOOK is in force: the org variable AI_REVIEW_PROMPT carries
# the project's rulebook and REPLACES the engine's generic embedded prompt
# wholesale (the engine reads envStr("AI_REVIEW_PROMPT", embeddedPrompt)), so an
# EMPTY value does not fail — it silently falls back to the generic prompt. That
# fallback is SILENT: the generic prompt still returns a plausible PASS/BLOCK, so
# no check reddens. Measured on 2026-11-01: the org variable's visibility had been
# narrowed to `private`, which GitHub exposes only to private or internal
# repositories, so every PUBLIC repository the gate covers resolved it EMPTY and
# the review ran on the generic prompt — system=2857 bytes instead of the rulebook's
# 35327. The assert is what makes that drift LOUD.
#
# WHY THE COVERAGE WORKS ON THE SHIPPED TEXT. The step lives INSIDE the reusable
# workflow, and the reusable workflow runs in the CALLER's repository — it never
# checks out opencharly/.github, so a script in this repo does not exist in the
# caller's workspace and could not be the thing the caller runs. The coverage
# therefore EXTRACTS the shipped step's `run:` text out of
# .github/workflows/pr-validator.yml and RUNS THAT TEXT against fixtures. The text
# under test IS the shipped text, so the two cannot drift.
#
# WHAT IT PROVES — each case is a DISCRIMINATION:
#   * the project's rulebook is in force -> exit 0: the assert must not redden the
#     org for nothing;
#   * the variable is EMPTY -> exit 1, naming the cause: the org must learn that
#     the review would run on the generic prompt, and WHY;
#   * the forwarded prompt is NOT the project's -> exit 1: the engine's generic
#     fallback names no project, so a prompt that names none is the fallback.
#
# AND THE WIRING: the step's OWN YAML block must forward
# `vars.AI_REVIEW_PROMPT`, or the assert would read a variable nothing supplies.
#
# THE NEGATIVE CONTROLS AT THE END prove the coverage can FAIL: each one neuters
# one branch of the shipped step in a copy, and the coverage must turn RED. A
# control that stayed green would mean the assertion it exercises is a tautology,
# and a tautology is not coverage (R7).
#
# usage: scripts/assert-org-rulebook_test.sh [--workflow <path>] [--no-controls]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
WF="$root/.github/workflows/pr-validator.yml"
SKIP_CONTROLS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workflow) WF="$2"; shift 2 ;;
    --no-controls) SKIP_CONTROLS=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "FAIL: $*" >&2; exit 1; }

# The project's rulebook, as a FIXTURE. The assert does not read the org variable
# itself (that is configuration, not content), it reads what it is handed — so the
# coverage hands it a prompt that names the project, and the two failure modes
# below. The fixture stands for the org's rulebook; the real one is 35301 characters
# and is never copied here.
PROJECT_PROMPT="You are a fresh, independent PR validation agent for the OpenCharly org."
# The engine's GENERIC fallback, whose first line is its own (it names no project).
GENERIC_PROMPT="You are a fresh, independent pull-request review agent. You review a PR read-only."

# ---- the shipped text under test --------------------------------------------------
# The EXTRACTION is the shared one (lib-org.sh), so this test and the other
# step-level tests cannot drift apart in HOW they read the shipped step — only in
# WHICH step they judge.
# shellcheck source=scripts/lib-org.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-org.sh"
extract_step_run "$WF" '^ *- name: Assert the org rulebook is in force$' "$STATE/step.sh"
[[ -s "$STATE/step.sh" ]] \
  || fail "the shipped assert step was not found in $WF"
grep -q 'AI_REVIEW_PROMPT' "$STATE/step.sh" \
  || fail "the extracted step reads no prompt — the extraction drifted"

# The step's own YAML block: it must FORWARD the org variable, or the assert reads
# a variable nothing supplies and the guard is decoration.
extract_step_yaml "$WF" '^ *- name: Assert the org rulebook is in force$' "$STATE/step.yaml"
[[ -s "$STATE/step.yaml" ]] \
  || fail "the shipped assert step's YAML block was not found in $WF"
grep -q 'AI_REVIEW_PROMPT: ${{ vars.AI_REVIEW_PROMPT }}' "$STATE/step.yaml" \
  || fail "the assert step does not forward vars.AI_REVIEW_PROMPT — it would read a variable nothing supplies"

# ---- case 1: the project's rulebook is in force -> the step passes ----------------
out="$(AI_REVIEW_PROMPT="$PROJECT_PROMPT" bash "$STATE/step.sh" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] \
  || { echo "$out" >&2; fail "the assert refused a project rulebook (exit $rc) — it must let the review run"; }
[[ "$out" != *"::error::"* ]] \
  || { echo "$out" >&2; fail "the assert emitted an error on a project rulebook"; }

# ---- case 2: the variable is EMPTY -> the step fails and NAMES the cause ---------
out="$(AI_REVIEW_PROMPT="" bash "$STATE/step.sh" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] \
  || { echo "$out" >&2; fail "an EMPTY org prompt did not fail the assert — the review would run on the generic fallback"; }
[[ "$out" == *"::error::"* ]] \
  || { echo "$out" >&2; fail "an EMPTY org prompt failed without a ::error:: annotation"; }
[[ "$out" == *"VISIBILITY"* ]] \
  || { echo "$out" >&2; fail "the empty-prompt failure does not name the cause (the variable's VISIBILITY)"; }

# ---- case 3: the forwarded prompt is NOT the project's -> the step fails ----------
out="$(AI_REVIEW_PROMPT="$GENERIC_PROMPT" bash "$STATE/step.sh" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] \
  || { echo "$out" >&2; fail "the generic fallback prompt did not fail the assert — the review would run on it"; }
[[ "$out" == *"not this project's rulebook"* ]] \
  || { echo "$out" >&2; fail "the wrong-prompt failure does not say the prompt is not the project's"; }

# ---- the negative controls: the coverage can FAIL ---------------------------------
if [[ "$SKIP_CONTROLS" -eq 0 ]]; then
  CONTROLS="$STATE/controls"
  mkdir -p "$CONTROLS"

  # control 1: the empty-prompt branch no longer names the cause — the guard is
  # neutered. The step still fails (the wrong-prompt branch catches an empty
  # string too), so what the coverage must catch is the LOST CAUSE: without the
  # empty branch the operator is told the wrong thing.
  python3 - "$WF" "$CONTROLS/neutered-empty.yml" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
needle = '          if [ -z "$AI_REVIEW_PROMPT" ]; then\n'
assert needle in text, "the shipped shape moved"
open(sys.argv[2], "w", encoding="utf-8").write(text.replace(needle, "          if false; then\n", 1))
PY
  if bash "$0" --workflow "$CONTROLS/neutered-empty.yml" --no-controls >"$CONTROLS/neutered-empty.log" 2>&1; then
    fail "NEGATIVE CONTROL: a neutered empty-prompt branch must fail this coverage, but it passed"
  fi
  grep -q "does not name the cause" "$CONTROLS/neutered-empty.log" \
    || { cat "$CONTROLS/neutered-empty.log"; fail "the neutered-empty control failed for the wrong reason"; }

  # control 2: the wrong-prompt branch no longer fails.
  python3 - "$WF" "$CONTROLS/neutered-wrong.yml" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
needle = "            *OpenCharly*) ;;\n"
assert needle in text, "the shipped shape moved"
open(sys.argv[2], "w", encoding="utf-8").write(text.replace(needle, "            *) ;;\n", 1))
PY
  if bash "$0" --workflow "$CONTROLS/neutered-wrong.yml" --no-controls >"$CONTROLS/neutered-wrong.log" 2>&1; then
    fail "NEGATIVE CONTROL: a neutered wrong-prompt branch must fail this coverage, but it passed"
  fi
  grep -q "generic fallback prompt did not fail" "$CONTROLS/neutered-wrong.log" \
    || { cat "$CONTROLS/neutered-wrong.log"; fail "the neutered-wrong control failed for the wrong reason"; }

  # control 3: the assert step is gone from the workflow.
  python3 - "$WF" "$CONTROLS/removed.yml" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
out, i, removed = [], 0, 0
while i < len(lines):
    if lines[i].strip() == "- name: Assert the org rulebook is in force":
        # the step's whole block: its name, its env, its run — up to the next step
        i += 1
        while i < len(lines) and not lines[i].strip().startswith("- name: "):
            i += 1
        removed += 1
        continue
    out.append(lines[i])
    i += 1
assert removed == 1, f"the control removed {removed} assert step(s) — the shipped shape moved"
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out))
PY
  if bash "$0" --workflow "$CONTROLS/removed.yml" --no-controls >"$CONTROLS/removed.log" 2>&1; then
    fail "NEGATIVE CONTROL: a workflow without the assert step must fail this coverage, but it passed"
  fi
  grep -q "assert step was not found" "$CONTROLS/removed.log" \
    || { cat "$CONTROLS/removed.log"; fail "the removed-step control failed for the wrong reason"; }
fi

echo "assert-org-rulebook_test: OK (a project rulebook passes; an empty prompt fails and names the cause; a prompt that names no project fails; the step forwards vars.AI_REVIEW_PROMPT)"
