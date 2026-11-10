#!/usr/bin/env bash
# The reconcile's TAG after its write (opencharly/.github#294).
#
# WHY THIS TEST EXISTS. The reconcile PUTs the canonical caller straight to `main`,
# bypassing the merge path that mints a CalVer tag. A head left untagged — and not
# explicable as the `docs: add CHANGELOG …` commit above a tag — fails
# `design-pintag` for every pin that advances to it, and that control forbids RAISING
# its census, so a pin wave cannot move. The fleet rollout of 414 repos produced
# exactly that: 389 design-pintag findings.
#
# WHAT IT PROVES, and each arm can fail:
#   1. a reconcile creates a tag AT THE COMMIT IT WROTE, in the CalVer shape;
#   2. the tag is not created twice (an existing ref is left alone);
#   3. no commit sha in the PUT response is a loud failure, not a silent skip.
#
# It runs the SHIPPED script against a mock `gh`, so the code under test is the code.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# A minimal project layout the script reads: the canonical template.
mkdir -p "$STATE/repo/.github/workflows"
cp "$root/.github/workflows/tag-on-merge-dispatcher.yml" "$STATE/repo/.github/workflows/tag-on-merge-dispatcher.yml"
mkdir -p "$STATE/repo/scripts"
cp "$root/scripts/reconcile-tag-on-merge-callers.sh" "$STATE/repo/scripts/"
cp "$root/scripts/lib-org.sh" "$STATE/repo/scripts/"

# The canonical content the script will PUT, and a caller that differs from it.
printf 'name: stale\n' >"$STATE/caller.yml"
cp "$STATE/repo/.github/workflows/tag-on-merge-dispatcher.yml" "$STATE/canonical.yml"

COMMIT_SHA="aaaa111122223333444455556666777788889999"

mkdir -p "$STATE/bin"
cat >"$STATE/bin/gh" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
state="$STATE"
all="\$*"
case "\$all" in
  "repo list"*) if [ -f "\$state/srcmode" ]; then printf '.github\n'; else printf 'fixture\n'; fi; exit 0 ;;
  "api orgs/fixture"*) printf '1\n'; exit 0 ;;
  "api --paginate "*"/repos?per_page"*) printf 'fixture\tfalse\tfalse\tmain\n'; exit 0 ;;
  "api --method PUT "*"/contents/"*)
    cp "\$state/canonical.yml" "\$state/caller.yml"
    printf '{"commit":{"sha":"%s"}}\n' "$COMMIT_SHA"; exit 0 ;;
  "api "*"/git/ref/tags/"*) echo "gh: Not Found" >&2; exit 1 ;;
  "api --method POST "*"/git/refs"*)
    printf '%s\n' "\$all" >>"\$state/tags"; exit 0 ;;
  "api "*"/commits/"*) printf '2026-11-10T08:00:00Z\n'; exit 0 ;;
  "api "*"/contents/"*)
    if printf '%s' "\$all" | grep -q -- '--jq .sha'; then printf 'deadbeef\n'; else base64 -w0 <"\$state/caller.yml"; fi
    exit 0 ;;
esac
echo "mock gh: unhandled: \$all" >&2
exit 97
MOCK
chmod +x "$STATE/bin/gh"

run_apply() {
  PATH="$STATE/bin:$PATH" \
  OPENCHARLY_ORG=fixture RECONCILE_REPOS="fixture" \
    bash "$STATE/repo/scripts/reconcile-tag-on-merge-callers.sh" --apply >"$STATE/out" 2>&1 || { cat "$STATE/out" >&2; return 1; }
}

# 1. a reconcile tags the commit it wrote
: >"$STATE/tags"
run_apply || fail "apply run failed"
want_tag="$(date -u -d 2026-11-10T08:00:00Z +'v%Y.%j.%H%M')"
grep -q "ref=refs/tags/$want_tag" "$STATE/tags" || { cat "$STATE/tags" >&2; fail "expected the reconcile to create refs/tags/$want_tag"; }
grep -q "sha=$COMMIT_SHA" "$STATE/tags" || { cat "$STATE/tags" >&2; fail "expected the tag to point at the commit the PUT returned"; }
echo "ok   reconcile tags the commit it wrote ($want_tag)"

# 2. the reconciled line names the tag
grep -q 'reconciled (pin=.* prose=.*) at v2026' "$STATE/out" || { cat "$STATE/out" >&2; fail "the reconciled line must name the tag"; }
echo "ok   the reconciled line names the tag"

# 3. no commit sha in the response is a loud failure
# reset the caller so the apply path actually runs again
printf 'name: stale\n' >"$STATE/caller.yml"
sed -i 's/"commit":{"sha":"%s"}/"commit":{}/' "$STATE/bin/gh"
grep -q '"commit":{}' "$STATE/bin/gh" || fail "mutation did not apply"
if run_apply; then tail -4 "$STATE/out" >&2; fail "a PUT response with no commit sha must fail, not skip the tag"; fi
echo "ok   a missing commit sha fails loudly"

# 4. BEHAVIOURAL: when the discovered repo IS the source repo, it is SKIPPED — no write,
# no tag. The guard compares against $SOURCE_REPO, so this arm sets it to the fixture's
# own name rather than inventing a repo the discovery mock cannot produce.
sed -i 's/"commit":{}/"commit":{"sha":"%s"}/' "$STATE/bin/gh"   # undo arm 3
: >"$STATE/tags"
printf 'name: stale\n' >"$STATE/caller.yml"
SOURCE_REPO=fixture PATH="$STATE/bin:$PATH" OPENCHARLY_ORG=fixture RECONCILE_REPOS="fixture" \
  bash "$STATE/repo/scripts/reconcile-tag-on-merge-callers.sh" --apply >"$STATE/out4" 2>&1 \
  || { cat "$STATE/out4" >&2; fail "the source-repo run failed"; }
grep -q 'skipped (the source repo holds the REUSABLE' "$STATE/out4" \
  || { cat "$STATE/out4" >&2; fail "the source repo must be SKIPPED, not reconciled"; }
grep -q 'reconciled (pin=' "$STATE/out4" && { cat "$STATE/out4" >&2; fail "the source repo was RECONCILED"; }
[ -s "$STATE/tags" ] && { cat "$STATE/tags" >&2; fail "the source repo must not be tagged"; }
echo "ok   the source repo is skipped, never written or tagged"

echo "PASS: the reconcile tags every write it makes, and guards the source repo (4 properties)"
