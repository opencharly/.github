#!/usr/bin/env bash
# Coverage for the IMAGE TAG DERIVATION in .github/workflows/image-build.yml.
#
# WHY THIS EXISTS. The workflow decides the image tag four different ways depending on the event and
# the `push` input, and that decision is what enforces W5's central invariant (image tag == git tag).
# Until this file, none of it had ever executed — opencharly/.github#270 round 1 blocked on exactly
# that ("the new behavior ships no in-diff test").
#
# HOW. The step's `run:` text is EXTRACTED from the shipped workflow and executed against fixtures,
# the same pattern scripts/retired-sweep-arm_test.sh and scripts/head-settle_test.sh use — so the
# thing under test and the thing that ships cannot drift. The step references NO GitHub expression in
# its body: every input arrives as an environment variable, which is what makes it runnable here.
#
# THE CONTROL AT THE END proves the coverage can fail: it strips the build-only `ci-<sha>` arm from a
# copy of the workflow and requires case 3 to go RED. A check that cannot fail is not coverage.
#
# usage: scripts/image-build-tag_test.sh [--workflow <path>]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
WF="$root/.github/workflows/image-build.yml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workflow) WF="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "FAIL: $*" >&2; exit 1; }

# shellcheck source=scripts/lib-org.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-org.sh"
extract_step_run "$WF" '^ *- name: Derive the image tag$' "$STATE/step.sh"
[[ -s "$STATE/step.sh" ]] || fail "the 'Derive the image tag' step was not found in $WF"
grep -q 'tag=' "$STATE/step.sh" || fail "the extracted step derives no tag — the extraction drifted"
if grep -q '${{' "$STATE/step.sh"; then
  fail "the step body carries a GitHub expression, so it cannot be executed here — move it to env:"
fi

# run_step executes the SHIPPED text with one fixture's environment.
run_step() {
  : >"$STATE/out"
  ( export GITHUB_OUTPUT="$STATE/out" GITHUB_SHA="${SHA:-0123456789abcdef0123456789abcdef01234567}"
    bash "$STATE/step.sh" ) >"$STATE/log" 2>&1
}

tag_of() { sed -n 's/^tag=//p' "$STATE/out" | tail -1; }

# ---- case 1: an explicit tag input is used verbatim -------------------------------
export INPUT_TAG="2026.999.9999" PUSH_INPUT=true EVENT_NAME=push REF=refs/heads/main REF_NAME=main
run_step || fail "an explicit tag must not fail: $(cat "$STATE/log")"
[[ "$(tag_of)" == "2026.999.9999" ]] || fail "explicit tag ignored: got '$(tag_of)'"

# ---- case 2: a v-tag push derives the tag with the v stripped ---------------------
export INPUT_TAG="" PUSH_INPUT=true EVENT_NAME=push REF=refs/tags/v2026.306.0314 REF_NAME=v2026.306.0314
run_step || fail "a v-tag push must not fail: $(cat "$STATE/log")"
[[ "$(tag_of)" == "2026.306.0314" ]] || fail "v-tag push derived '$(tag_of)', want 2026.306.0314"

# ---- case 3: a BUILD-ONLY run with no derivable tag uses ci-<sha> -----------------
# This is the arm the pull_request proof depends on, and the one round 1 of #268 broke by
# hard-failing here.
export INPUT_TAG="" PUSH_INPUT=false EVENT_NAME=pull_request REF=refs/pull/1/merge REF_NAME=1/merge
export SHA=0123456789abcdef0123456789abcdef01234567
run_step || fail "a build-only run must not fail: $(cat "$STATE/log")"
[[ "$(tag_of)" == "ci-0123456789ab" ]] || fail "build-only derived '$(tag_of)', want ci-0123456789ab"
grep -q 'build-only run' "$STATE/log" || fail "the build-only tag must be announced: $(cat "$STATE/log")"

# ---- case 4: a PUBLISHING run with no derivable tag is a hard failure -------------
export INPUT_TAG="" PUSH_INPUT=true EVENT_NAME=pull_request REF=refs/pull/1/merge REF_NAME=1/merge
if run_step; then fail "a publishing run with no derivable tag must FAIL, but it passed"; fi
grep -q 'no image tag derivable for a PUBLISHING run' "$STATE/log" \
  || fail "the publishing refusal must name the reason: $(cat "$STATE/log")"

# ---- control: the build-only arm is load-bearing -----------------------------------
# Strip the `ci-<sha>` arm from a copy and require case 3 to go RED. Without this, case 3 could be
# passing for a reason other than the arm it claims to cover.
python3 - "$WF" "$STATE/stripped.yml" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
needle = '            tag="ci-${GITHUB_SHA::12}"\n'
assert needle in text, "the build-only arm moved"
open(sys.argv[2], "w", encoding="utf-8").write(text.replace(needle, '            exit 1\n', 1))
PY
extract_step_run "$STATE/stripped.yml" '^ *- name: Derive the image tag$' "$STATE/stripped.sh"
export INPUT_TAG="" PUSH_INPUT=false EVENT_NAME=pull_request REF=refs/pull/1/merge REF_NAME=1/merge
if ( export GITHUB_OUTPUT="$STATE/out2" GITHUB_SHA=0123456789abcdef0123456789abcdef01234567
     bash "$STATE/stripped.sh" ) >/dev/null 2>&1; then
  fail "NEGATIVE CONTROL: with the build-only arm stripped, a build-only run must fail this coverage"
fi

# ---- case 5: the PUBLISH arm — --push is added only when publishing ----------------------
# The build step's body carries no GitHub expression, so its SHIPPED text runs here against a
# STUB binary; without this the publish arm ships unproven (opencharly/.github#274 finding 2).
extract_step_run "$WF" '^ *- name: Build the image$' "$STATE/build.sh"
[[ -s "$STATE/build.sh" ]] || fail "the 'Build the image' step was not found in $WF"
if grep -q '[$]{{' "$STATE/build.sh"; then
  fail "the build step carries a GitHub expression, so its publish arm cannot be executed here"
fi
mkdir -p "$STATE/bin"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "$@" >"$STUB_ARGS_OUT"' >"$STATE/bin/stub-charly"
chmod +x "$STATE/bin/stub-charly"

run_build() {
  : >"$STATE/args"
  ( export STUB_ARGS_OUT="$STATE/args" BOX="pod-crabbox" REPO_NAME="pod-crabbox" \
           IMAGE_TAG="ci-abc123" PUSH_INPUT="$1" CHARLY_BIN="$STATE/bin/stub-charly"
    bash "$STATE/build.sh" ) >"$STATE/build.log" 2>&1
}

run_build false || fail "a build-only run must not fail: $(cat "$STATE/build.log")"
grep -qx -- '--tag' "$STATE/args" || fail "the build argv must carry --tag; got: $(tr '\n' ' ' <"$STATE/args")"
if grep -qx -- '--push' "$STATE/args"; then
  fail "a build-only run must NOT pass --push; got: $(tr '\n' ' ' <"$STATE/args")"
fi

run_build true || fail "a publishing run must not fail: $(cat "$STATE/build.log")"
grep -qx -- '--push' "$STATE/args" || fail "a publishing run MUST pass --push; got: $(tr '\n' ' ' <"$STATE/args")"

# --- the login step must be UNCONDITIONAL (opencharly/.github#280) ---
# A build-only run still PULLS: a variant's `base:` is an image in this registry. While the
# login carried `if: inputs.push`, that pull fell back to the runner's stale credential and was
# denied even for a PUBLIC package. The extraction test above drives the BUILD step, so it passed
# identically with and without the `if:` -- exactly the "coverage that cannot fail" defect. This
# block reads the SHIPPED login step and requires it to carry no `if:`.

login_guard() {  # $1 = workflow path; prints an `if:` line if the login step is conditional
  awk '
    /- name: Log in to ghcr\.io/ { inlogin = 1; depth = 0 }
    inlogin && /^[[:space:]]+if:/ { print; exit }
    inlogin && /^[[:space:]]+- name:/ && !/Log in to ghcr/ { inlogin = 0 }
  ' "$1"
}

guard="$(login_guard "$WF")"
if [ -n "$guard" ]; then
  fail "the ghcr.io login step is CONDITIONAL (${guard}); a build-only run would not authenticate and every variant's base pull would be denied (opencharly/.github#280)"
fi

# The control: restore the old `if: inputs.push` and require the block above to go RED.
CTL2="$STATE/wf-login-conditional.yml"
awk '
  /- name: Log in to ghcr\.io/ { print; inlogin = 1; next }
  inlogin && !done && /^[[:space:]]+env:/ { print "        if: inputs.push"; done = 1 }
  { print }
' "$WF" > "$CTL2"
if [ -z "$(login_guard "$CTL2")" ]; then
  fail "the login-coverage control did not go RED on a workflow whose login step is conditional -- the check above cannot fail"
fi

echo "image-build-tag_test: OK (explicit tag verbatim; v-tag push strips the v; build-only derives ci-<sha> and announces it; a publishing run without a tag refuses by name; the build-only arm is load-bearing)"
