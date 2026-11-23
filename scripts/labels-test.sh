#!/usr/bin/env bash
# labels-test.sh — offline coverage for scripts/labels.sh with a mock `gh` on PATH.
# The RED arms are the point: a taxonomy tool that cannot fail is not a tool.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$STATE/repo/scripts" "$STATE/repo/labels" "$STATE/bin"
cp "$root/scripts/labels.sh" "$root/scripts/lib-org.sh" "$STATE/repo/scripts/"
cp "$root/labels/taxonomy.json" "$root/labels/category-rules.json" "$STATE/repo/labels/"
jq -n '{used:["opencharly/repo1#10"],rounds:[]}' > "$STATE/repo/labels/cold-reader-used.json"

cat > "$STATE/bin/gh" <<'GH'
#!/usr/bin/env bash
set -uo pipefail
S="${STATE:?}"
cmd="${1:-}"; shift || true
record() { printf '%s\n' "$*" >> "$S/calls"; }
case "$cmd" in
  api)
    url=""; jqexpr=""
    while (($#)); do
      case "$1" in
        --paginate) ;;
        --jq) shift; jqexpr="${1:-}" ;;
        *) url="$1" ;;
      esac
      shift
    done
    case "$url" in
      orgs/opencharly/repos*)
        printf 'repo1\tfalse\tfalse\tmain\nrepo2\tfalse\tfalse\tmain\narchived\ttrue\tfalse\tmain\n' ;;
      orgs/opencharly)
        printf '{"public_repos":3,"total_private_repos":0}' ;;
      repos/opencharly/repo1/labels*)
        printf 'category:runtime\tD93F0B\tThe charly host, loader/provider framework, cross-cutting contract, or host capability.\ntype:fix\tB60205\tstale description\nbug\td73a4a\tdefault\n' ;;
      repos/opencharly/repo2/labels*)
        if [[ -f "$S/quota" ]]; then echo 'API rate limit exceeded' >&2; exit 1; fi
        if [[ -f "$S/perm" ]]; then echo 'Resource not accessible by integration' >&2; exit 1; fi
        : ;;
      repos/opencharly/repo1/issues*)
        if [[ "$jqexpr" == *".number"* && "$jqexpr" != *"@json"* ]]; then
          printf '10\n11\n12\n'
        else
          printf '%s\n' \
            '{"number":10,"title":"missing type","body":"### Category\n\ncategory:runtime\n\n### Type\n\ntype:fix\n","labels":["category:runtime"]}' \
            '{"number":11,"title":"two categories","body":"","labels":["category:runtime","category:delivery","type:fix"]}' \
            '{"number":12,"title":"retired label","body":"","labels":["category:runtime","type:fix","bug"]}'
        fi ;;
      repos/opencharly/repo1/pulls*) : ;;
      repos/opencharly/repo2/issues*) : ;;
      repos/opencharly/repo2/pulls*) : ;;
      *) echo "unexpected api: $url" >&2; exit 1 ;;
    esac
    exit 0 ;;
  label)
    record "label $*"
    case "${1:-}" in delete) [[ -f "$S/delete_fail" ]] && exit 1 ;; esac
    exit 0 ;;
  issue)
    record "issue $*"
    case "${1:-}" in
      edit) [[ -f "$S/edit_fail" ]] && exit 1; exit 0 ;;
      list) printf '1\n'; exit 0 ;;
      view)
        if [[ "$*" == *"TITLE:"* ]]; then printf 'TITLE: t\nURL: u\nBODY: b\n'
        else printf '{"title":"t","body":"Amend DESIGN.md to add the rule","labels":["category:runtime","type:fix"]}\n'; fi
        exit 0 ;;
    esac ;;
  pr)
    record "pr $*"
    printf '{"title":"fix: x","body":"Closes #10","files":["candy/x/Containerfile"]}\n'
    exit 0 ;;
esac
echo "unexpected gh: $cmd $*" >&2
exit 1
GH
chmod +x "$STATE/bin/gh"

OUT=""; RC=0
run() { PATH="$STATE/bin:$PATH" STATE="$STATE" OPENCHARLY_ORG=opencharly TMPDIR="$STATE" bash "$STATE/repo/scripts/labels.sh" "$@"; }
capture() { set +e; OUT="$(run "$@" 2>&1)"; RC=$?; set -e; }

# 1. sync --dry-run plans creates/updates and writes nothing.
: > "$STATE/calls"
capture sync --repo repo1 --dry-run
[[ $RC -eq 0 ]] || fail "sync dry-run must succeed (rc=$RC): $OUT"
grep -q 'PLAN UPDATE repo1 type:fix' <<<"$OUT" || fail "dry-run must plan the stale type:fix update"
grep -q 'PLAN CREATE repo1 category:delivery' <<<"$OUT" || fail "dry-run must plan a missing label"
[[ ! -s "$STATE/calls" ]] || fail "dry-run must not write labels"
echo "ok   sync --dry-run plans creates/updates and writes nothing"

# 2. sync applies creates and edits.
: > "$STATE/calls"
capture sync --repo repo1
[[ $RC -eq 0 ]] || fail "sync must succeed (rc=$RC): $OUT"
grep -q 'label create category:delivery -R opencharly/repo1' "$STATE/calls" || fail "sync must create a missing label"
grep -q 'label edit type:fix -R opencharly/repo1' "$STATE/calls" || fail "sync must update a stale label"
echo "ok   sync creates missing labels and updates stale ones"

# 3. a quota refusal is one named class and the unevaluated set is printed.
: > "$STATE/quota"; : > "$STATE/perm"
capture sync --repo repo1,repo2
[[ $RC -ne 0 ]] || fail "a quota refusal must exit non-zero"
grep -q 'API RATE LIMITED' <<<"$OUT" || fail "the quota class must be named: $OUT"
grep -q 'NOT EVALUATED' <<<"$OUT" || fail "the unevaluated set must be printed: $OUT"
echo "ok   a quota refusal stops the sweep and names the unevaluated set"

# 4. a permission refusal aborts with the required permission.
rm -f "$STATE/quota"; : > "$STATE/perm"
capture sync --repo repo2
[[ $RC -ne 0 ]] || fail "a permission refusal must exit non-zero"
grep -q 'permission denied' <<<"$OUT" || fail "the permission class must abort: $OUT"
rm -f "$STATE/perm"
echo "ok   a permission refusal aborts with the required permission"

# 5. audit finds missing/multi/unknown and --strict reds.
capture audit --repo repo1 --strict
[[ $RC -ne 0 ]] || fail "audit --strict must exit 1 on findings"
grep -q 'FINDING opencharly/repo1#10 missing=1' <<<"$OUT" || fail "missing type must be a finding: $OUT"
grep -q 'FINDING opencharly/repo1#11 missing=0 multi=1' <<<"$OUT" || fail "two categories must be a finding: $OUT"
grep -q 'FINDING opencharly/repo1#12 .*unknown=bug' <<<"$OUT" || fail "a retired label must be a finding: $OUT"
echo "ok   audit finds missing, multi-value and unknown labels"

# 6. audit --apply maps ONLY the form answer and never guesses.
: > "$STATE/calls"
capture audit --repo repo1 --apply
grep -q 'issue edit 10 -R opencharly/repo1 --add-label type:fix' "$STATE/calls" || fail "the form answer must be applied"
! grep -q 'issue edit 11' "$STATE/calls" || fail "a multi-value axis must never be auto-picked"
! grep -q 'issue edit 12' "$STATE/calls" || fail "a complete axis must not be re-applied"
echo "ok   audit --apply maps the form answer only"

# 7. apply reads a reviewed TSV, skips ?, and validates the closed set.
cat > "$STATE/apply.tsv" <<'TSV'
repo	issue	category	type	confidence	evidence	title
repo1	10	category:runtime	type:fix	high	x	y
repo1	11	?	?	low	x	y
TSV
: > "$STATE/calls"
capture apply --from "$STATE/apply.tsv"
[[ $RC -eq 0 ]] || fail "apply must succeed: $OUT"
grep -q 'issue edit 10 -R opencharly/repo1 --add-label category:runtime --add-label type:fix' "$STATE/calls" || fail "apply must add both reviewed labels"
! grep -q 'issue edit 11' "$STATE/calls" || fail "apply must skip ?"
echo "ok   apply adds reviewed labels and skips under-specified rows"

# 8. sample excludes used ids, records the round, and never reuses a set.
capture sample --n 2 --out "$STATE/sample.txt" --record --set T --revision v18
[[ $RC -eq 0 ]] || fail "sample must succeed: $OUT"
grep -q '=== opencharly/repo1#11' "$STATE/sample.txt" || fail "sample must draw an unused id"
grep -q '=== opencharly/repo1#12' "$STATE/sample.txt" || fail "sample must draw the second unused id"
! grep -q 'repo1#10' "$STATE/sample.txt" || fail "sample must exclude a used id"
[[ "$(jq -r '.used | length' "$STATE/repo/labels/cold-reader-used.json")" -eq 3 ]] || fail "sample --record must append the ids to used"
jq -e '.rounds[-1].set == "T" and .rounds[-1].revision == "v18"' "$STATE/repo/labels/cold-reader-used.json" >/dev/null || fail "sample --record must append the round"
echo "ok   sample excludes used ids and records a disjoint round"

# 8b. sample --from records the fixture that was ACTUALLY tested, not a redraw.
cat > "$STATE/from.txt" <<'F'
=== opencharly/repo1#13
=== opencharly/repo1#14
F
capture sample --from "$STATE/from.txt" --record --set R --revision vtest
[[ $RC -eq 0 ]] || fail "sample --from must succeed: $OUT"
[[ "$(jq -r '.used | length' "$STATE/repo/labels/cold-reader-used.json")" -eq 5 ]] || fail "sample --from must append the tested ids"
jq -e '.rounds[-1].set == "R" and .rounds[-1].revision == "vtest" and (.rounds[-1].issues | length) == 2' "$STATE/repo/labels/cold-reader-used.json" >/dev/null || fail "sample --from must record the tested round"
echo "ok   sample --from records the tested fixture exactly"

# 9. retire --dry-run lists a retired label and deletes nothing.
: > "$STATE/calls"
capture retire --repo repo1 --dry-run
[[ $RC -eq 0 ]] || fail "retire --dry-run must succeed: $OUT"
grep -q 'PLAN DELETE repo1 bug' <<<"$OUT" || fail "a present retired label must be planned"
! grep -q 'label delete' "$STATE/calls" || fail "retire --dry-run must not delete"
echo "ok   retire --dry-run lists retired labels and deletes nothing"

# 10. render emits the four required fields and both closed sets.
capture render --out "$STATE/issue.yml"
[[ $RC -eq 0 ]] || fail "render must succeed: $OUT"
for f in category type remedy cited; do grep -q "id: $f" "$STATE/issue.yml" || fail "the form must require $f"; done
[[ "$(grep -c '^        - category:' "$STATE/issue.yml")" -eq 6 ]] || fail "the form must offer 6 categories"
[[ "$(grep -c '^        - type:' "$STATE/issue.yml")" -eq 6 ]] || fail "the form must offer 6 types"
echo "ok   render emits the four fields and the closed sets"

# 11. verify-close reds when the PR paths do not match the issue category.
capture verify-close opencharly/repo1#99 opencharly/repo1#10
[[ $RC -ne 0 ]] || fail "a category mismatch must exit non-zero"
grep -q 'MISMATCH' <<<"$OUT" || fail "a category mismatch must be named: $OUT"
echo "ok   verify-close reds on a category mismatch"

# 12. explain resolves a DESIGN amendment to runtime + design.
capture explain opencharly/repo1#10
[[ $RC -eq 0 ]] || fail "explain must succeed: $OUT"
grep -q 'category: runtime' <<<"$OUT" || fail "DESIGN.md must map to runtime"
grep -q 'type:     design' <<<"$OUT" || fail "a DESIGN amendment must be design, not docs"
echo "ok   explain resolves a DESIGN amendment to runtime + design"

# 13. genericity: the same issue body in an arbitrary repo gets the same answer.
capture explain opencharly/totally-new-repo#10
[[ $RC -eq 0 ]] || fail "explain must succeed for an arbitrary repo: $OUT"
grep -q 'category: runtime' <<<"$OUT" || fail "the repo name must not change the category"
grep -q 'type:     design' <<<"$OUT" || fail "the repo name must not change the type"
echo "ok   genericity: the same body in an arbitrary repo gets the same category"

echo "PASS: the label taxonomy tool syncs, audits, applies, samples, records the tested fixture, retires, renders, verifies close, names the quota/permission classes, and classifies by the issue text alone (never the repo name)"
