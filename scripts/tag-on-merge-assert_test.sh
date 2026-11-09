#!/usr/bin/env bash
# The tag-on-merge DETECTOR's own coverage (opencharly/.github#286,
# opencharly/crabbox#40).
#
# WHY THE COVERAGE WORKS ON THE SHIPPED TEXT: the detector lives INSIDE the
# reusable workflow, and that workflow runs in the CALLER's repository — it never
# checks out opencharly/.github, so a script here could not be the thing the
# caller runs. This test therefore EXTRACTS the shipped step
# (scripts/lib-org.sh's extract_step_run / extract_step_yaml) and RUNS THAT against
# a mock `gh`, which also applies the step's own `--jq` filter so the real filter
# is under test. The text under test IS the shipped text.
#
# WHAT IT PROVES — every case below is a property a green run depends on. A
# detector that cannot fail is not a detector, so the RED cases are the point:
#
#   1. GREEN  — a merged PR whose merge commit carries a LIGHTWEIGHT tag: exit 0.
#   2. GREEN  — an ANNOTATED tag is DEREFERENCED to its commit: exit 0. Comparing
#               against the tag OBJECT would be a false negative (red) for every
#               annotated tag in the org.
#   3. RED    — a merged PR with no tag at all: exit 1 AND the PR number is NAMED.
#               A red that does not name the merge is #286's complaint.
#   4. RED    — a tag exists but points at a DIFFERENT commit: exit 1. The property
#               is "the MERGE COMMIT is tagged", not "some tag exists".
#   5. GREEN  — a merge OUTSIDE the window is not judged: exit 0. Without this the
#               step would redden forever on the historical untagged merges this
#               very issue was opened for.
#   6. GREEN  — a closed-but-UNMERGED PR is not judged: exit 0.
#   7. STRUCT — the step carries `!cancelled()`, or it is SKIPPED exactly when the
#               tagging step died — #286's own failure mode — and its coverage
#               would be the silent path alone. (`!cancelled()` rather than
#               `always()`: a superseded run must stay CANCELLED, not turn red on
#               a merge it never tried to tag.)
#   8. STRUCT — the window has ONE literal: `SWEEP_WINDOW_HOURS:` is declared
#               exactly once in the workflow, so the sweep and the detector cannot
#               judge different populations.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib-org.sh
. "$root/scripts/lib-org.sh"

WF="$root/.github/workflows/tag-on-merge.yml"
STEP="Assert every merge in the sweep window carries a tag at its merge commit"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- the extraction drift guard (case 7/8) -----------------------------------
extract_step_run "$WF" "^ *- name: ${STEP}$" "$STATE/step.sh"
extract_step_yaml "$WF" "^ *- name: ${STEP}$" "$STATE/step.yml"

[ -s "$STATE/step.sh" ] \
  || fail "the detector step's run text could not be extracted — the selector and the step name have drifted apart"
grep -q 'matching-refs/tags' "$STATE/step.sh" \
  || fail "the extracted run text is not the detector (it does not list tags)"
grep -q '!cancelled()' "$STATE/step.yml" \
  || fail "the detector must carry a non-cancelled condition (!cancelled()) — without it the step is SKIPPED when the tagging step died, which is the one case (#286) where the untagged merge would otherwise stay unnamed"

decl="$(grep -c '^      SWEEP_WINDOW_HOURS:' "$WF" || true)"
[ "$decl" -eq 1 ] \
  || fail "SWEEP_WINDOW_HOURS must be declared exactly once as the job's one window literal (found $decl)"

# --- a mock `gh` that APPLIES --jq, like the real one -------------------------
mkdir -p "$STATE/bin"
cat >"$STATE/bin/gh" <<'MOCK'
#!/usr/bin/env bash
# The narrowest `gh` that the detector's step uses: `api`, `--paginate`, `--jq`.
# Anything else is a step change the mock does not know about, and it says so
# (97) rather than returning something plausible.
set -euo pipefail
[ "${1:-}" = "api" ] || { echo "mock gh: only 'api' is supported (got: $*)" >&2; exit 97; }
shift
url=""; filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) shift ;;
    --jq) filter="${2:?--jq needs a value}"; shift 2 ;;
    -*) echo "mock gh: unsupported flag $1" >&2; exit 97 ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *"/pulls?"*) page="${FIXTURE_PULLS:?FIXTURE_PULLS unset}" ;;
  *"/git/matching-refs/tags") page="${FIXTURE_TAGS:?FIXTURE_TAGS unset}" ;;
  *"/git/tags/"*) page="${FIXTURE_TAGOBJECT:?FIXTURE_TAGOBJECT unset}" ;;
  *) echo "mock gh: no fixture for $url" >&2; exit 97 ;;
esac
# `-r` matches the real `gh api --jq`: a top-level STRING is printed raw (measured:
# `gh api repos/opencharly/.github --jq '.name'` → `.github`, no quotes), while an
# array is printed as compact JSON. A mock that quoted the string would compare
# `"<sha>"` against `<sha>` and fail an arm the shipped step gets right.
if [ -n "$filter" ]; then jq -r -c "$filter" "$page"; else cat "$page"; fi
MOCK
chmod +x "$STATE/bin/gh"

now_minus() { date -u -d "-$1 hours" +%Y-%m-%dT%H:%M:%SZ; }

# run_case <name> <pulls.json> <tags.json> <tagobject.json> -> RC, $STATE/<name>.out/.err
RC=0
run_case() {
  local name="$1" pulls="$2" tags="$3" tagobj="$4"
  PATH="$STATE/bin:$PATH" \
  GH_TOKEN=mock GITHUB_REPOSITORY=opencharly/fixture SWEEP_WINDOW_HOURS=24 \
  FIXTURE_PULLS="$pulls" FIXTURE_TAGS="$tags" FIXTURE_TAGOBJECT="$tagobj" \
  RUNNER_TEMP="$STATE" \
    bash "$STATE/step.sh" >"$STATE/$name.out" 2>"$STATE/$name.err" || RC=$?
}

expect_green() { # <name> ; RC must be 0
  [ "$RC" -eq 0 ] || { cat "$STATE/$1.out" "$STATE/$1.err" >&2; fail "case $1: expected GREEN (exit 0), got $RC"; }
  echo "ok   $1"
}

expect_red_naming() { # <name> <pr-number>
  [ "$RC" -ne 0 ] || { cat "$STATE/$1.out" >&2; fail "case $1: expected RED (non-zero), got 0"; }
  grep -q "PR #$2" "$STATE/$1.out" \
    || { cat "$STATE/$1.out" "$STATE/$1.err" >&2; fail "case $1: red, but the merge (PR #$2) is not NAMED — a red that does not name the merge is #286's complaint"; }
  # Show WHAT it named, so the gate log is evidence rather than a verdict.
  echo "ok   $1  ->  $(grep -m1 '^PR #' "$STATE/$1.out")"
}

inner="$(now_minus 1)"
outer="$(now_minus 48)"

# 1. lightweight tag at the merge commit
cat >"$STATE/p1.json" <<JSON
[{"number":101,"merged_at":"${inner}","merge_commit_sha":"aaaa111111111111111111111111111111111111"}]
JSON
cat >"$STATE/t1.json" <<'JSON'
[{"ref":"refs/tags/v2026.313.0001","object":{"sha":"aaaa111111111111111111111111111111111111","type":"commit"}}]
JSON
echo '{}' >"$STATE/tagobj.json"
RC=0; run_case c1 "$STATE/p1.json" "$STATE/t1.json" "$STATE/tagobj.json"
expect_green c1

# 2. annotated tag, dereferenced to the merge commit
cat >"$STATE/t2.json" <<'JSON'
[{"ref":"refs/tags/v2026.313.0002","object":{"sha":"9999999999999999999999999999999999999999","type":"tag"}}]
JSON
cat >"$STATE/tagobj2.json" <<'JSON'
{"object":{"sha":"aaaa111111111111111111111111111111111111","type":"commit"}}
JSON
RC=0; run_case c2 "$STATE/p1.json" "$STATE/t2.json" "$STATE/tagobj2.json"
expect_green c2

# 3. no tag at all -> red, naming the PR
cat >"$STATE/t3.json" <<'JSON'
[{"ref":"refs/tags/v2026.313.0009","object":{"sha":"bbbb222222222222222222222222222222222222","type":"commit"}}]
JSON
RC=0; run_case c3 "$STATE/p1.json" "$STATE/t3.json" "$STATE/tagobj.json"
expect_red_naming c3 101

# 4. a tag exists, but at a DIFFERENT commit -> red (the merge commit is the property)
cat >"$STATE/t4.json" <<'JSON'
[{"ref":"refs/tags/v2026.313.0010","object":{"sha":"cccc333333333333333333333333333333333333","type":"commit"}}]
JSON
RC=0; run_case c4 "$STATE/p1.json" "$STATE/t4.json" "$STATE/tagobj.json"
expect_red_naming c4 101

# 5. outside the window -> not judged (the historical untagged merge cannot redden forever)
cat >"$STATE/p5.json" <<JSON
[{"number":102,"merged_at":"${outer}","merge_commit_sha":"dddd444444444444444444444444444444444444"}]
JSON
RC=0; run_case c5 "$STATE/p5.json" "$STATE/t1.json" "$STATE/tagobj.json"
expect_green c5

# 6. closed but NOT merged -> not judged
cat >"$STATE/p6.json" <<'JSON'
[{"number":103,"merged_at":null,"merge_commit_sha":null}]
JSON
RC=0; run_case c6 "$STATE/p6.json" "$STATE/t1.json" "$STATE/tagobj.json"
expect_green c6

echo "PASS: tag-on-merge untagged-merge detector (8 properties: 4 green arms, 2 red arms naming the merge, 2 structural)"
