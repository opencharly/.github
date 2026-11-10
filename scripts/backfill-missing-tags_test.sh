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
    if [ -f "$state/present" ]; then printf '%s\n' "$head_sha"; fi
    exit 0 ;;
  "api --method POST "*"/git/refs"*)
    printf '%s\n' "$all" >>"$state/created"; : >"$state/present"; printf '{}\n'; exit 0 ;;
  "api "*"/git/ref/heads/main"*) printf '%s\n' "$head_sha"; exit 0 ;;
  "api "*"/commits/"*)
    # The two callers ask for different fields: the CalVer derivation wants the committer
    # DATE, the explained-check wants the SUBJECT. The mock answers the field the call's
    # own --jq names, exactly as the real API would.
    case "$all" in
      *committer.date*) printf '%s\n' "$date"; exit 0 ;;
    esac
    if [ -f "$state/changelog" ]; then printf 'docs: add CHANGELOG 2026.314.0800 for PR #1\n'; else printf 'ci: reconcile the tag-on-merge caller with the canonical template\n'; fi
    exit 0 ;;
  "api "*"/contents/"*)
    if [ -f "$state/no_caller" ]; then echo "gh: Not Found" >&2; exit 1; fi
    printf '{}\n'; exit 0 ;;
esac
echo "mock gh: unhandled: $all" >&2
exit 97
MOCK
chmod +x "$STATE/bin/gh"

reset() { rm -f "$STATE/present" "$STATE/changelog" "$STATE/no_caller"; : >"$STATE/created"; printf '%s\n' "${1:-fixture}" >"$STATE/repos"; }
run()   { PATH="$STATE/bin:$PATH" OPENCHARLY_ORG=fixture RECONCILE_REPOS="${1:-}" BF_STATE="$STATE" BF_HEAD="$HEAD_SHA" BF_DATE="$DATE" \
            bash "$STATE/repo/scripts/backfill-missing-tags.sh" ${2:-} >"$STATE/out" 2>&1; }

# 1. an unexplained head is tagged at that head
reset fixture; run fixture --apply || { cat "$STATE/out" >&2; fail "apply run failed"; }
cat "$STATE/out" >&2; cat "$STATE/created" >&2; grep -q "ref=refs/tags/v2026.314.0800" "$STATE/created" || { cat "$STATE/out" >&2; cat "$STATE/created" >&2; fail "expected a plain CalVer tag"; }
grep -q "sha=$HEAD_SHA" "$STATE/created" || fail "expected the tag at the head commit"
echo "ok   an unexplained head is tagged at that head"

# 2. an EXPLAINED head is skipped
reset fixture; touch "$STATE/changelog"
run fixture --apply || { cat "$STATE/out" >&2; fail "apply run failed on an explained head"; }
[ -s "$STATE/created" ] && { cat "$STATE/created" >&2; fail "an EXPLAINED (CHANGELOG-tip) head must not be tagged"; }
grep -q 'explained (CHANGELOG tip)' "$STATE/out" || fail "the run must say why it skipped"
echo "ok   an explained head is skipped"

# 3. a module repo gets Go's form
reset sdk; run sdk --apply || { cat "$STATE/out" >&2; fail "apply run failed for a module repo"; }
grep -q "ref=refs/tags/v0.2026314.800" "$STATE/created" || { cat "$STATE/created" >&2; fail "expected Go's module form v0.2026314.800"; }
echo "ok   a proxy-consumed root module gets Go's tag form"

# 4. an existing tag at the head means no action
reset fixture; touch "$STATE/present"
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

echo "PASS: the backfill tags only what is untagged and unexplained, in the right form (6 properties)"
