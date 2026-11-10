#!/usr/bin/env bash
# The missing-tag backfill's own coverage (opencharly/.github#294).
#
# WHY IT EXISTS. The caller reconcile writes straight to `main`, outside the merge path
# that mints a CalVer tag. Before #296 that left ~411 org heads untagged and UNEXPLAINED —
# not the `docs: add CHANGELOG …` commit `design-pintag` excuses — so every pin that
# advanced to one failed that control, whose census may only be lowered. The backfill
# tags those heads. A wrong tag is worse than no tag, so each property below is load-
# bearing and each arm can fail:
#
#   1. a head with NO tag and NO CHANGELOG excuse gets a tag at that head;
#   2. an EXPLAINED head (the `docs: add CHANGELOG …` commit above a tag) is SKIPPED —
#      tagging it would invent a second release for a commit the control already excuses;
#   3. a proxy-consumed ROOT MODULE (sdk, spec, plugin-gh) gets Go's form
#      v0.<y><doy>.<hhmm>, never a plain v<major> tag that needs a /vN module path;
#   4. an EXISTING tag at the head means no action — the run is idempotent and add-only;
#   5. a repo with no tag-on-merge caller is skipped: it mints no releases.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$STATE/repo/scripts"
cp "$root/scripts/backfill-missing-tags.sh" "$STATE/repo/scripts/"
cp "$root/scripts/lib-org.sh" "$STATE/repo/scripts/"

HEAD_SHA="bbbb222233334444555566667777888899990000"
DATE="2026-11-10T08:00:00Z"

# A mock gh whose answers are driven by files the arms write.
mkdir -p "$STATE/bin"
cat >"$STATE/bin/gh" <<'MOCK'
#!/usr/bin/env bash
# A QUOTED heredoc: nothing is expanded at fixture-build time, so every $ below is
# resolved at RUN time. The state dir arrives in the environment instead.
set -euo pipefail
state="${BF_STATE:?BF_STATE unset}"
head_sha="${BF_HEAD:?BF_HEAD unset}"
date="${BF_DATE:?BF_DATE unset}"
all="$*"
case "$all" in
  "api --paginate "*"/repos?per_page="*)
    while IFS= read -r n; do [ -n "$n" ] && printf '%s\tfalse\tfalse\tmain\n' "$n"; done <"$state/repos"; exit 0 ;;
  "api orgs/fixture"*) wc -l <"$state/repos" | tr -d ' '; exit 0 ;;
  "api --paginate "*"/tags"*)
    # A refusal at the TAGS LISTING — the read head_tag makes.
    if [ -f "$state/rate_limit_tags" ]; then
      echo '{"message":"API rate limit exceeded for user ID 265000000.","status":"403"}' >&2; exit 1
    fi
    # tags_skip counts successful tags reads BEFORE the refusal, so the arm can refuse the
    # SECOND one (the parent's) rather than the first.
    if [ -f "$state/tags_skip" ]; then
      n="$(cat "$state/tags_skip")"
      if [ "$n" -gt 0 ]; then echo $((n-1)) >"$state/tags_skip"; else rm -f "$state/tags_skip"; echo '{"message":"API rate limit exceeded for user ID 265000000.","status":"403"}' >&2; exit 1; fi
    fi
    if [ -f "$state/tags_sha" ]; then cat "$state/tags_sha"; fi
    exit 0 ;;
  "api --method POST "*"/git/refs"*)
    printf '%s\n' "$all" >>"$state/created"
    # A refusal AT THE CREATE — the branch that decides whether a doomed write is reported as
    # "not evaluated" rather than as a generic failure.
    if [ -f "$state/rate_limit_post" ]; then
      echo '{"message":"API rate limit exceeded for user ID 265000000.","status":"403"}' >&2; exit 1
    fi
    # post_422 models the lost create: the pre-check's LISTING lagged, so the ref already
    # exists and the API refuses with 422. The run must then ask the POINT read which
    # commit it holds, not treat "the POST failed" as "the tag is missing".
    if [ -f "$state/post_422" ]; then echo "gh: Reference already exists (HTTP 422)" >&2; exit 1; fi
    printf '%s\n' "$head_sha" >"$state/ref_sha"
    # listing_lag models what the first pilot measured: the ref exists and is readable
    # while the paginated LISTING has not caught up. Only the point read can see it.
    [ -f "$state/listing_lag" ] || printf '%s\n' "$head_sha" >"$state/tags_sha"
    printf '{}\n'; exit 0 ;;
  "api "*"/git/ref/tags/"*)
    # A refusal at the POINT read of one ref — the read ref_points_at makes AFTER a create.
    if [ -f "$state/rate_limit_ref" ]; then
      echo '{"message":"API rate limit exceeded for user ID 265000000.","status":"403"}' >&2; exit 1
    fi
    if [ -f "$state/ref_sha" ]; then cat "$state/ref_sha"; exit 0; fi
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  "api "*"/git/ref/heads/main"*)
    # A refusal AT THE HEAD FETCH, reachable only after a caller read that succeeded — the
    # path a caller-only rate limit never exercises.
    if [ -f "$state/rate_limit_head" ]; then
      echo '{"message":"API rate limit exceeded for user ID 265000000.","status":"403"}' >&2; exit 1
    fi
    printf '%s\n' "$head_sha"; exit 0 ;;
  "api "*"/commits/"*)
    # The two callers ask for different fields: the CalVer derivation wants the committer
    # DATE, the explained-check wants the SUBJECT. The mock answers the field the call's
    # own --jq names, exactly as the real API would.
    case "$all" in
      *committer.date*) printf '%s\n' "$date"; exit 0 ;;
      *parents*)
        if [ -f "$state/rate_limit_parent" ]; then
          echo '{"message":"API rate limit exceeded for user ID 265000000.","status":"403"}' >&2; exit 1
        fi
        printf 'parent-sha\n'; exit 0 ;;
    esac
    if [ -f "$state/rate_limit_subject" ]; then
      echo '{"message":"API rate limit exceeded for user ID 265000000.","status":"403"}' >&2; exit 1
    fi
    if [ -f "$state/changelog" ]; then printf 'docs: add CHANGELOG 2026.314.0800 for PR #1\n'; else printf 'ci: reconcile the tag-on-merge caller with the canonical template\n'; fi
    exit 0 ;;
  "api "*"/contents/"*)
    # CALLS counts how many repos reached the API, so an arm can prove the run STOPS paying
    # once the quota has refused one call.
    printf 'call\n' >>"$state/calls"
    if [ -f "$state/rate_limit" ]; then
      echo '{"message":"API rate limit exceeded for user ID 265000000.","status":"403"}' >&2; exit 1
    fi
    if [ -f "$state/no_caller" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    printf '{}\n'; exit 0 ;;
esac
echo "mock gh: unhandled: $all" >&2
exit 97
MOCK
chmod +x "$STATE/bin/gh"

reset() { rm -f "$STATE/tags_sha" "$STATE/changelog" "$STATE/no_caller" "$STATE/ref_sha" "$STATE/listing_lag" "$STATE/post_422" "$STATE/rate_limit" "$STATE/rate_limit_head" "$STATE/rate_limit_tags" "$STATE/rate_limit_ref" "$STATE/rate_limit_subject" "$STATE/rate_limit_parent" "$STATE/rate_limit_post" "$STATE/tags_skip" "$STATE/unevaluated.txt"; : >"$STATE/created"; : >"$STATE/calls"; printf '%s\n' "${1:-fixture}" >"$STATE/repos"; }
run()   { PATH="$STATE/bin:$PATH" OPENCHARLY_ORG=fixture RECONCILE_REPOS="${1:-}" BF_STATE="$STATE" BF_HEAD="$HEAD_SHA" BF_DATE="$DATE" \
            bash "$STATE/repo/scripts/backfill-missing-tags.sh" ${2:-} >"$STATE/out" 2>&1; }

# 1. an unexplained head is tagged at that head
reset fixture; run fixture --apply || { cat "$STATE/out" >&2; fail "apply run failed"; }
cat "$STATE/out" >&2; cat "$STATE/created" >&2; grep -q "ref=refs/tags/v2026.314.0800" "$STATE/created" || { cat "$STATE/out" >&2; cat "$STATE/created" >&2; fail "expected a plain CalVer tag"; }
grep -q "sha=$HEAD_SHA" "$STATE/created" || fail "expected the tag at the head commit"
echo "ok   an unexplained head is tagged at that head"

# 2. an EXPLAINED head is skipped
reset fixture; touch "$STATE/changelog"; printf 'parent-sha\n' >"$STATE/tags_sha"
run fixture --apply || { cat "$STATE/out" >&2; fail "apply run failed on an explained head"; }
[ -s "$STATE/created" ] && { cat "$STATE/created" >&2; fail "an EXPLAINED (CHANGELOG-tip) head must not be tagged"; }
grep -q 'explained (CHANGELOG tip above a tag)' "$STATE/out" || { cat "$STATE/out" >&2; fail "the run must say why it skipped"; }
echo "ok   an explained head is skipped"

# 3. a module repo gets Go's form
reset sdk; run sdk --apply || { cat "$STATE/out" >&2; fail "apply run failed for a module repo"; }
grep -q "ref=refs/tags/v0.2026314.800" "$STATE/created" || { cat "$STATE/created" >&2; fail "expected Go's module form v0.2026314.800"; }
echo "ok   a proxy-consumed root module gets Go's tag form"

# 4. an existing tag at the head means no action
reset fixture; printf '%s\n' "$HEAD_SHA" >"$STATE/tags_sha"
run fixture --apply || { cat "$STATE/out" >&2; fail "apply run failed with an existing tag"; }
[ -s "$STATE/created" ] && { cat "$STATE/created" >&2; fail "an existing tag must not be re-created (add-only, idempotent)"; }
echo "ok   an existing tag means no action"

# 5. a repo with no caller is skipped
reset fixture; touch "$STATE/no_caller"
run fixture --apply || { cat "$STATE/out" >&2; fail "apply run failed for a caller-less repo"; }
[ -s "$STATE/created" ] && fail "a repo with no tag-on-merge caller must not be tagged"
grep -q 'no tag-on-merge caller' "$STATE/out" || fail "the run must say why it skipped"
echo "ok   a repo with no caller is skipped"

# 6. CHECK mode writes nothing at all
reset fixture; run fixture "" || { cat "$STATE/out" >&2; fail "check run failed"; }
[ -s "$STATE/created" ] && fail "check mode must not create any ref"
grep -q 'NEED a tag' "$STATE/out" || fail "check mode must report what it would tag"
echo "ok   check mode writes nothing"

# 7. a CHANGELOG tip whose PARENT is untagged still needs a tag — the control excuses a
# CHANGELOG commit ABOVE A TAG, not any CHANGELOG commit
reset fixture; touch "$STATE/changelog"          # subject is the CHANGELOG line …
                                                # … but tags_sha is unset: the parent has no tag
run fixture --apply || { cat "$STATE/out" >&2; fail "apply run failed on an untagged-parent CHANGELOG tip"; }
grep -q "ref=refs/tags/v2026.314.0800" "$STATE/created" \
  || { cat "$STATE/out" >&2; cat "$STATE/created" >&2; fail "a CHANGELOG tip with an UNTAGGED parent must be tagged"; }
grep -q 'UNTAGGED parent' "$STATE/out" || fail "the run must say the parent is untagged"
echo "ok   a CHANGELOG tip with an untagged parent is tagged"

# 8. a created tag is verified by a POINT READ, so a LAGGING LISTING cannot turn a
#    successful create into a reported failure (opencharly/.github#298 — measured on the
#    first live pilot: the tag existed, the listing did not show it yet, and the run
#    counted a failure for a tag it had just created).
reset fixture; touch "$STATE/listing_lag"
run fixture --apply || { cat "$STATE/out" >&2; fail "a lagging listing must not fail a successful create"; }
grep -q 'tagged v2026.314.0800: fixture' "$STATE/out" || { cat "$STATE/out" >&2; fail "the create must be reported as tagged"; }
grep -q 'failures           : 0' "$STATE/out" || { cat "$STATE/out" >&2; fail "the run must report zero failures"; }
echo "ok   a successful create is verified by the ref, not by the listing"

# 9. a create that LOSES to an existing ref (HTTP 422, the listing lagged the PRE-check) is
#    verified the same way and is NOT a failure — the question is which commit the ref
#    holds, never whether the POST returned 0.
reset fixture; touch "$STATE/post_422"; printf '%s\n' "$HEAD_SHA" >"$STATE/ref_sha"
run fixture --apply || { cat "$STATE/out" >&2; fail "an already-present ref at the head must not fail"; }
grep -q 'already present at the head (v2026.314.0800): fixture' "$STATE/out" || { cat "$STATE/out" >&2; fail "the run must say the ref was already present"; }
grep -q 'failures           : 0' "$STATE/out" || { cat "$STATE/out" >&2; fail "an already-present ref is not a failure"; }
echo "ok   a lost create is verified by the ref, not by the POST's exit status"

# 10. … and a ref that exists at a DIFFERENT commit is a real failure, never accepted —
#     otherwise a tag on the wrong commit would be reported as success (R7: this arm is
#     what makes arms 8 and 9 safe rather than permissive).
reset fixture; touch "$STATE/post_422"; printf 'aaaa0000bbbb1111cccc2222dddd3333eeee4444\n' >"$STATE/ref_sha"
if run fixture --apply; then cat "$STATE/out" >&2; fail "a ref at a DIFFERENT commit must fail the run"; fi
grep -q 'REF EXISTS AT A DIFFERENT COMMIT (v2026.314.0800): fixture' "$STATE/out" || { cat "$STATE/out" >&2; fail "the run must name the mismatched ref"; }
echo "ok   a ref at a different commit is a failure"

# 11. an exhausted quota is ONE class, said ONCE, with the not-evaluated set written out —
#     and it stops paying for calls that cannot succeed (opencharly/.github#300). Measured
#     on the fleet pass: 60 repos reported as individual failures, all one 403.
reset fixture; printf 'a\nb\nc\n' >"$STATE/repos"; touch "$STATE/rate_limit"
export BF_UNEVALUATED_FILE="$STATE/unevaluated.txt"
if run "a b c" --apply; then cat "$STATE/out" >&2; fail "a rate-limited run must exit non-zero — nothing is known about those repos"; fi
[ -s "$STATE/created" ] && { cat "$STATE/created" >&2; fail "no tag may be created when the API refuses the read"; }
[ "$(grep -c 'API RATE LIMITED (the quota is exhausted)' "$STATE/out")" -eq 1 ] \
  || { cat "$STATE/out" >&2; fail "the cause must be named exactly once, not once per repo"; }
grep -q 'API RATE LIMITED   : 3 repo(s) NOT evaluated' "$STATE/out" \
  || { cat "$STATE/out" >&2; fail "the summary must count the repos that were not evaluated"; }
grep -q 'retry with' "$STATE/out" || fail "the summary must hand back the retry allow-list"
[ "$(wc -l <"$STATE/unevaluated.txt")" -eq 3 ] \
  || { cat "$STATE/unevaluated.txt" >&2; fail "the not-evaluated set must be written as a file"; }
[ "$(wc -l <"$STATE/calls")" -eq 1 ] \
  || { cat "$STATE/calls" >&2; fail "only the FIRST repo may reach the API once the quota refuses it — the rest must not pay another call"; }
echo "ok   an exhausted quota is one named class, once, and the run stops paying for it"

# 12. a refusal AT THE HEAD FETCH is the same class — the branch a caller-only rate limit
#     never reaches, and the one the first version of this fix left untested.
reset fixture; touch "$STATE/rate_limit_head"
export BF_UNEVALUATED_FILE="$STATE/unevaluated.txt"
if run fixture --apply; then cat "$STATE/out" >&2; fail "a refused head read must exit non-zero"; fi
[ -s "$STATE/created" ] && { cat "$STATE/created" >&2; fail "no tag may be created when the head cannot be read"; }
grep -q 'API RATE LIMITED   : 1 repo(s) NOT evaluated' "$STATE/out" \
  || { cat "$STATE/out" >&2; fail "the summary must count the head-refused repo"; }
[ "$(wc -l <"$STATE/unevaluated.txt")" -eq 1 ] || fail "the set must name the head-refused repo"
[ "$(wc -l <"$STATE/calls")" -eq 1 ] \
  || { cat "$STATE/calls" >&2; fail "the caller read must have happened FIRST, so the refusal is at the HEAD fetch and not earlier"; }
grep -q 'retry with         : RECONCILE_REPOS="fixture" .* --apply' "$STATE/out" \
  || { cat "$STATE/out" >&2; fail "the retry line must be a runnable command with the set and the mode"; }
echo "ok   a quota refusal at the head fetch is the same one named class, with a runnable retry line"

# 13. a refusal at the TAGS LISTING (head_tag) is the same class, and still emits the summary,
#     the set and the file — a refusal never leaves the run half-reported.
reset fixture; touch "$STATE/rate_limit_tags"
export BF_UNEVALUATED_FILE="$STATE/unevaluated.txt"
if run fixture --apply; then cat "$STATE/out" >&2; fail "a refused tags listing must exit non-zero"; fi
[ -s "$STATE/created" ] && fail "no tag may be created when the tags cannot be read"
grep -q 'API RATE LIMITED   : 1 repo(s) NOT evaluated' "$STATE/out" || fail "the summary must count the tags-refused repo"
[ "$(wc -l <"$STATE/unevaluated.txt")" -eq 1 ] || fail "the set must name the tags-refused repo"
echo "ok   a quota refusal at the tags listing reports through the same summary and set"

# 14. … and at the POINT REF read after a create, which is the read that CONFIRMS a tag.
reset fixture; touch "$STATE/rate_limit_ref"
export BF_UNEVALUATED_FILE="$STATE/unevaluated.txt"
if run fixture --apply; then cat "$STATE/out" >&2; fail "a refused ref read must exit non-zero"; fi
[ -s "$STATE/created" ] || fail "the create must have been ATTEMPTED, so the refusal is at the READ-BACK and not earlier"
grep -q 'API RATE LIMITED   : 1 repo(s) NOT evaluated' "$STATE/out" || fail "the summary must count the ref-refused repo"
[ "$(wc -l <"$STATE/unevaluated.txt")" -eq 1 ] || fail "the set must name the ref-refused repo"
grep -q 'tagged now         : 0' "$STATE/out" || fail "an unconfirmed create must never be counted as tagged"
echo "ok   a quota refusal at the confirming ref read is reported, never counted as tagged"


# 16. a refusal at the SUBJECT read — the read that decides whether a head is the excused
#     CHANGELOG tip — is the same class.
reset fixture; touch "$STATE/rate_limit_subject"
export BF_UNEVALUATED_FILE="$STATE/unevaluated.txt"
if run fixture --apply; then cat "$STATE/out" >&2; fail "a refused subject read must exit non-zero"; fi
[ -s "$STATE/created" ] && fail "no tag may be created when the subject cannot be read"
grep -q 'API RATE LIMITED   : 1 repo(s) NOT evaluated' "$STATE/out" || fail "the summary must count the subject-refused repo"
[ "$(wc -l <"$STATE/unevaluated.txt")" -eq 1 ] || fail "the set must name the subject-refused repo"
echo "ok   a quota refusal at the subject read is the same one named class"

# 17. … and at the PARENT read, which only the CHANGELOG-tip path reaches.
reset fixture; touch "$STATE/changelog" "$STATE/rate_limit_parent"
export BF_UNEVALUATED_FILE="$STATE/unevaluated.txt"
if run fixture --apply; then cat "$STATE/out" >&2; fail "a refused parent read must exit non-zero"; fi
[ -s "$STATE/created" ] && fail "no tag may be created when the parent cannot be read"
grep -q 'API RATE LIMITED   : 1 repo(s) NOT evaluated' "$STATE/out" || fail "the summary must count the parent-refused repo"
[ "$(wc -l <"$STATE/unevaluated.txt")" -eq 1 ] || fail "the set must name the parent-refused repo"
echo "ok   a quota refusal at the parent read is the same one named class"

# 18. … and at the CREATE POST itself, which is the branch that decides whether a write the
#     API refused is reported as NOT EVALUATED instead of as a generic failure.
reset fixture; touch "$STATE/rate_limit_post"
export BF_UNEVALUATED_FILE="$STATE/unevaluated.txt"
if run fixture --apply; then cat "$STATE/out" >&2; fail "a refused create must exit non-zero"; fi
[ -s "$STATE/created" ] || fail "the create must have been ATTEMPTED, so the refusal is at the write"
grep -q 'API RATE LIMITED   : 1 repo(s) NOT evaluated' "$STATE/out" || { cat "$STATE/out" >&2; fail "the summary must count the create-refused repo"; }
[ "$(wc -l <"$STATE/unevaluated.txt")" -eq 1 ] || fail "the set must name the create-refused repo"
grep -q 'TAG CREATE FAILED' "$STATE/out" && fail "a quota refusal at the create must not be reported as a generic create failure"
echo "ok   a quota refusal at the create POST is reported as NOT EVALUATED, not as a create failure"

# 19. a refusal at the PARENT's tags listing — the SECOND head_tag call, which a static flag
#     can never reach: the first read must succeed and the second be refused.
reset fixture; touch "$STATE/changelog"; printf '1\n' >"$STATE/tags_skip"
export BF_UNEVALUATED_FILE="$STATE/unevaluated.txt"
if run fixture --apply; then cat "$STATE/out" >&2; fail "a refused parent tags read must exit non-zero"; fi
[ -s "$STATE/created" ] && fail "no tag may be created when the parent's tags cannot be read"
grep -q 'API RATE LIMITED   : 1 repo(s) NOT evaluated' "$STATE/out" || { cat "$STATE/out" >&2; fail "the summary must count the parent-tags-refused repo"; }
echo "ok   a quota refusal at the SECOND (parent) tags read is reached and reported"

# 20. … and at the ref read inside the 422 path, which only a lost create enters.
reset fixture; touch "$STATE/post_422" "$STATE/rate_limit_ref"
export BF_UNEVALUATED_FILE="$STATE/unevaluated.txt"
if run fixture --apply; then cat "$STATE/out" >&2; fail "a refused ref read after a 422 must exit non-zero"; fi
grep -q 'API RATE LIMITED   : 1 repo(s) NOT evaluated' "$STATE/out" || { cat "$STATE/out" >&2; fail "the summary must count the 422-ref-refused repo"; }
grep -q 'REF EXISTS AT A DIFFERENT COMMIT' "$STATE/out" && fail "an unreadable ref must never be reported as a different-commit ref"
echo "ok   a quota refusal at the ref read inside the 422 path is reported, not mislabelled"



echo "PASS: the backfill tags only what is untagged and unexplained, in the right form, verifies every create by the ref itself, and names an exhausted quota once at every read AND at the create (19 properties)"
