#!/usr/bin/env bash
set -euo pipefail

# governance-reconcile.sh — the CROSS-SURFACE RECONCILIATION GATE.
#
# WHY THIS EXISTS. A normative OpenCharly rule is routinely stated in two or more
# independently-edited surfaces (the umbrella AGENTS.md, charly/AGENTS.md, the skill
# sources in their standalone candy repos, the GENERATED marketplace corpus, the
# validator rulebook in opencharly/action-review's charly.yml and the AI_REVIEW_PROMPT org
# variable, and the .github workflows/scripts). With no single source of truth and no
# reconciliation gate, a rule edited in one surface silently collides with or drifts
# from the same rule in another — MEASURED (issue opencharly/opencharly#282): the
# identity-footer ORDER, the takeover WINDOW (30 vs 60 min), a stale AI_REVIEW_PROMPT
# mirror, and a dangling reference to a retired CI channel.
#
# This gate makes the class non-silent. A committed MANIFEST (`governance-claims.tsv`)
# declares, per claim, the canonical phrase EVERY surface must carry and the LEGACY
# phrase NO surface may carry; the gate asserts both. Adding a row is how a rule is
# protected from drifting; editing a listed surface out of compliance FAILS the gate.
#
# A SURFACE MUST ALSO EXIST. A named surface that is ABSENT while its owner repo is
# materialized in this checkout is a STALE POINTER — the manifest points at a file
# that moved — and it FAILS. Silently downgrading it to "not checked" is how 19 of
# 81 rows protected nothing while the gate looked green (opencharly/.github#246). A
# skip is right ONLY for a surface this checkout does not carry at all.
#
# AND EVERY SURFACE MUST BE ANCHORED. A path that no 'require' row pins is UNANCHORED:
# the only rows that name it are 'forbid' rows, and a forbid row asserts that a phrase
# is ABSENT — vacuously true of ANY file at that path, including a file that holds no
# rule at all. So the table could not say "this path IS the surface": the day the
# surface moved, its forbid row would keep passing against whatever sat at the path,
# and it could never go red (opencharly/.github#250). The control is about the TABLE,
# not about this checkout: an unanchored path FAILS in every root, including one that
# does not carry the surface at all.
#
# OFFLINE and dependency-free (`bash` + coreutils + `grep`/`sed`). It runs from
# opencharly/.github's `validator-harness.yml` CI job — there, only the .github-local
# surfaces exist, so the cross-repo rows SKIP cleanly and visibly (a silent pass is
# forbidden) — and against a full umbrella checkout (`--root`), where EVERY row is
# asserted.
#
# Path resolution supports BOTH roots: a manifest path `dotgithub/<p>` resolves to
# `<root>/dotgithub/<p>` (umbrella) or `<root>/<p>` (a standalone .github checkout,
# where the repo IS the root).
#
# usage: $0 [--root <checkout>] [--manifest <path>] [--self-test]
#   --root      a checkout to check against. Default: the parent of this file's repo
#               (…/dotgithub/.. == the umbrella root).
#   --manifest  the claims table. Default: scripts/governance-claims.tsv beside this file.
#   --self-test exercise the checker on fixtures (pass AND fail), then exit.
#
# Exit: 0 = every present surface reconciled; 1 = a drift (or a missing local surface); 2 = usage.

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: $0 [--root <checkout>] [--manifest <path>] [--self-test]" >&2; exit 2; }

manifest=""; root=""; self_test=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) [[ $# -ge 2 ]] || usage; root="$2"; shift 2 ;;
    --manifest) [[ $# -ge 2 ]] || usage; manifest="$2"; shift 2 ;;
    --self-test) self_test=1; shift ;;
    *) usage ;;
  esac
done
[[ -n "$manifest" ]] || manifest="$HERE/governance-claims.tsv"

# A path is LOCAL to the .github repo when the manifest names it with the `dotgithub/`
# repo prefix (e.g. `dotgithub/.github/workflows/pr-validator.yml`). Such a surface MUST
# exist — its absence is a structural error, never a skip. Every other path names a
# surface that lives elsewhere in the UMBRELLA (the umbrella's own `AGENTS.md` and
# `.agents/skills/…` trees, the `marketplace/…` corpus) — absent in a standalone .github
# checkout, so it SKIPS cleanly; but in an UMBRELLA checkout, where the owner IS
# materialized, its absence is a STALE POINTER and FAILS (see owner_present).
is_local() { case "$1" in dotgithub/*) return 0;; *) return 1;; esac; }

# resolve_path <root> <manifest-path> — the file for a row, or empty if absent.
#
# A `dotgithub/`-prefixed path is the .github repo's OWN surface: it resolves at
# <root>/dotgithub/<p> in the umbrella and at <root>/<p> in a standalone .github
# checkout (where the repo IS the root).
#
# Every other (bare) path names a surface relative to the UMBRELLA root
# (`AGENTS.md`, `.agents/skills/…`, `marketplace/…`). Those resolve
# ONLY when <root> is the umbrella — i.e. it mounts the .github repo as
# `dotgithub/`. A standalone .github checkout is NOT the umbrella, so a bare path
# SKIPS cleanly EVEN WHEN a file of the same name exists at the repo root (e.g. the
# repo's own AGENTS.md signpost, which is NOT the umbrella rulebook the bare
# `AGENTS.md` rows assert). The `dotgithub/` mount is the discriminator: without
# it, the root is not the umbrella.
resolve_path() {
  local rt="$1" p="$2" a b
  case "$p" in
    dotgithub/*)
      a="$rt/$p"; [[ -f "$a" ]] && { printf '%s\n' "$a"; return; }
      b="$rt/${p#dotgithub/}"; [[ -f "$b" ]] && { printf '%s\n' "$b"; return; }
      ;;
    *)
      [[ -d "$rt/dotgithub" ]] || { printf ''; return; }
      a="$rt/$p"; [[ -f "$a" ]] && { printf '%s\n' "$a"; return; }
      ;;
  esac
  printf ''
}

# owner_present <root> <manifest-path> — is the surface's OWNER REPO materialized in
# this checkout?
#
# A bare path names a surface that lives elsewhere in the UMBRELLA: `marketplace/…` is
# owned by the `marketplace` repo, `.agents/skills/…` by the umbrella's own `.agents`
# tree. The FIRST path segment is the owner. A TOP-LEVEL file (the umbrella's own
# AGENTS.md) is owned by the ROOT itself, which is present by construction.
#
# "Materialized" means the owner path is a DIRECTORY that is not empty. Three
# filesystem states are NOT a materialized owner, and each of them is one the
# control below must skip rather than turn into a false red:
#
#   - the owner dir does NOT EXIST at all — this checkout does not carry that repo;
#   - the owner dir is EMPTY — an uninitialized submodule path in a light checkout;
#   - the owner path is NOT A DIRECTORY — a stray file that happens to share a
#     sibling repo's name (`ls -A` on a FILE prints the file's name, so without the
#     directory guard the owner would look materialized and the checker would raise
#     a false stale-pointer red).
#
# The first two share a verdict, and so they share a mechanism — but the third is
# why the directory guard exists at all, and it is the only one of the three that a
# test can tell apart: remove the `-d` guard and the absent-owner and empty-owner
# cases skip either way, while the non-directory case turns red. The self-test
# asserts that case for exactly that reason.
#
# A bare path is judged only where a bare path is RESOLVED at all: the UMBRELLA
# root, where the .github repo is mounted as `dotgithub/` — the same discriminator
# resolve_path uses. In a standalone .github checkout a directory that merely shares
# a sibling repo's name is a coincidence, not a mount, so it must never become a
# false red.
owner_present() {
  local rt="$1" p="$2" owner
  [[ -d "$rt/dotgithub" ]] || return 1
  owner="${p%%/*}"
  if [[ "$owner" == "$p" ]]; then
    # A top-level file: the root owns it, and the root is present by construction.
    return 0
  fi
  [[ -d "$rt/$owner" ]] || return 1
  [[ -n "$(ls -A "$rt/$owner" 2>/dev/null)" ]] || return 1
  return 0
}

# unanchored_surfaces <manifest> — the paths the manifest names that NO 'require' row
# pins, one line each: claim<TAB>surface<TAB>path.
#
# The claim and the surface are the FIRST row that names the path, so the finding names
# the row a reader would edit. The path is the whole verdict: a 'forbid' row alone
# asserts that a phrase is ABSENT, which is vacuously true of any file at that path.
unanchored_surfaces() {
  awk -F'\t' '
    /^#/ { next }
    NF < 5 { next }
    $1 == "claim" { next }
    {
      if (!($3 in first)) first[$3] = $1 "\t" $2
      if ($4 == "require") anchored[$3] = 1
    }
    END {
      for (p in first) if (!(p in anchored)) print first[p] "\t" p
    }' "$1" | sort
}

# check_manifest <manifest> <root> — the checker. 0 = reconciled, 1 = drift.
check_manifest() {
  local mf="$1" rt="$2" fail=0 checked=0 skipped=0 lineno=0
  [[ -f "$mf" ]] || { echo "FATAL: manifest not found: $mf" >&2; return 1; }
  local claim surface path kind pattern target
  # The ANCHOR control (opencharly/.github#250). A path that no 'require' row pins is
  # UNANCHORED: the only rows that name it are 'forbid' rows, whose assertion ("this
  # phrase is ABSENT") is vacuously true of ANY file at that path — including a file
  # that holds no rule at all. So the table could not say "this path IS the surface",
  # and the row could never go red. The verdict is about the TABLE, not about this
  # checkout, so it is reported before the rows and it FAILS in every root.
  local uclaim usurface upath
  while IFS=$'\t' read -r uclaim usurface upath; do
    [[ -n "${upath:-}" ]] || continue
    echo "FAIL  $uclaim/$usurface — UNANCHORED surface: $upath is named by a 'forbid' row only, so nothing pins that the path IS the surface (opencharly/.github#250)" >&2
    fail=1
  done < <(unanchored_surfaces "$mf")
  # TSV fields: claim, surface, path, kind (require|forbid), pattern (an ERE, may have spaces).
  while IFS=$'\t' read -r claim surface path kind pattern || [[ -n "${claim:-}" ]]; do
    lineno=$((lineno+1))
    [[ -n "${claim:-}" ]] || continue
    [[ "$claim" == \#* ]] && continue
    [[ "$claim" == "claim" ]] && continue   # the header row
    if [[ -z "${surface:-}" || -z "${path:-}" || -z "${kind:-}" || -z "${pattern:-}" ]]; then
      echo "FAIL  $claim/${surface:-?} — malformed manifest row (line $lineno: need 5 TAB fields)" >&2
      fail=1; continue
    fi
    if [[ "$kind" != require && "$kind" != forbid ]]; then
      echo "FAIL  $claim/$surface — unknown kind '$kind' (want require|forbid)" >&2
      fail=1; continue
    fi
    target="$(resolve_path "$rt" "$path")"
    if [[ -z "$target" ]]; then
      if is_local "$path"; then
        # A LOCAL surface must exist — its absence is a structural error, never a skip.
        echo "FAIL  $claim/$surface — local surface missing: $path" >&2
        fail=1
      elif owner_present "$rt" "$path"; then
        # A NAMED surface whose OWNER REPO is materialized in this checkout, but
        # whose FILE is absent: that is a STALE POINTER, not an uncarried surface
        # (opencharly/.github#246). The manifest exists to answer "is this claim
        # still stated in the surface it names?" — so a surface that is not there
        # cannot answer it, and silently downgrading it to "not checked" is how 19
        # of 81 rows protected nothing while the gate looked green. A skip is
        # right ONLY for a surface this checkout does not carry at all.
        echo "FAIL  $claim/$surface — the named surface is ABSENT: $path (its owner repo IS present in this checkout, so this is a stale pointer, not an uncarried surface)" >&2
        fail=1
      else
        echo "skip  $claim/$surface — $path not in this checkout"
        skipped=$((skipped+1))
      fi
      continue
    fi
    checked=$((checked+1))
    # WRAP-ROBUST matching. Prose in these surfaces wraps at a fixed column, so a
    # multi-word canonical phrase can straddle a line break and a naive line-based
    # `grep` would MISS it — a false red on a correct tree. Match against a
    # whitespace-NORMALIZED copy of the file: runs of whitespace (including the
    # newline) collapse to one space, so a phrase spans a wrap. The manifest keeps
    # its specific, full phrases (never shortened to a loose fragment).
    norm="$(tr '\n' ' ' < "$target" | tr -s '[:space:]' ' ')"
    if [[ "$kind" == require ]]; then
      if printf '%s' "$norm" | grep -Eq -- "$pattern"; then
        echo "ok    $claim/$surface — required phrase present in ${target#"$rt"/}"
      else
        echo "FAIL  $claim/$surface — required phrase ABSENT from $path (/$pattern/)" >&2
        fail=1
      fi
    else
      if printf '%s' "$norm" | grep -Eq -- "$pattern"; then
        echo "FAIL  $claim/$surface — forbidden phrase PRESENT in $path (/$pattern/)" >&2
        fail=1
      else
        echo "ok    $claim/$surface — forbidden phrase absent from ${target#"$rt"/}"
      fi
    fi
  done < "$mf"
  echo "governance-reconcile: checked=$checked skipped=$skipped fail=$fail"
  [[ "$fail" == 0 ]]
}

if [[ "$self_test" == 1 ]]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  # Mirrors the real layout: a `dotgithub/`-prefixed local surface + a sibling surface.
  mkdir -p "$tmp/dotgithub" "$tmp/sibling"
  printf 'the canonical phrase lives here\n' > "$tmp/dotgithub/one.txt"
  printf 'the modern phrase is here\n'       > "$tmp/sibling/two.txt"
  cat > "$tmp/pass.tsv" <<TSV
# claim	surface	path	kind	pattern
canon	a	dotgithub/one.txt	require	canonical phrase
modern	b	sibling/two.txt	require	modern phrase
legacy	b	sibling/two.txt	forbid	old legacy phrase
TSV
  cat > "$tmp/fail-absent.tsv" <<TSV
# claim	surface	path	kind	pattern
canon	a	dotgithub/one.txt	require	a phrase that is ABSENT
TSV
  cat > "$tmp/fail-forbid.tsv" <<TSV
# claim	surface	path	kind	pattern
modern	b	sibling/two.txt	require	modern phrase is here
legacy	b	sibling/two.txt	forbid	modern phrase
TSV
  cat > "$tmp/fail-local-missing.tsv" <<TSV
# claim	surface	path	kind	pattern
canon	a	dotgithub/ghost.txt	require	anything
TSV
  printf 'x\ty\tz\trequire\n' > "$tmp/fail-malformed.tsv"
  # A sibling-only manifest against a root WITHOUT the sibling must SKIP, not fail.
  cat > "$tmp/skip.tsv" <<TSV
# claim	surface	path	kind	pattern
modern	b	sibling/two.txt	require	modern phrase
legacy	b	sibling/two.txt	forbid	legacy phrase
TSV
  check_manifest "$tmp/pass.tsv" "$tmp" >/dev/null \
    || { echo "SELF-TEST FAIL: a compliant tree was reported as drifted" >&2; exit 1; }
  check_manifest "$tmp/fail-absent.tsv" "$tmp" >/dev/null 2>&1 \
    && { echo "SELF-TEST FAIL: a missing required phrase was accepted" >&2; exit 1; }
  check_manifest "$tmp/fail-forbid.tsv" "$tmp" >/dev/null 2>&1 \
    && { echo "SELF-TEST FAIL: a forbidden phrase was accepted" >&2; exit 1; }
  check_manifest "$tmp/fail-local-missing.tsv" "$tmp" >/dev/null 2>&1 \
    && { echo "SELF-TEST FAIL: a missing LOCAL surface was accepted" >&2; exit 1; }
  check_manifest "$tmp/fail-malformed.tsv" "$tmp" >/dev/null 2>&1 \
    && { echo "SELF-TEST FAIL: a malformed manifest row was accepted" >&2; exit 1; }
  # Standalone .github checkout: the dotgithub/ prefix strips to the root; absent siblings skip.
  check_manifest "$tmp/pass.tsv" "$tmp/dotgithub" >/dev/null 2>&1 \
    || { echo "SELF-TEST FAIL: a dotgithub-prefixed path did not resolve in its own checkout" >&2; exit 1; }
  out="$(check_manifest "$tmp/skip.tsv" "$tmp/dotgithub" 2>&1)" \
    || { echo "SELF-TEST FAIL: an absent sibling surface was not skipped cleanly" >&2; exit 1; }
  grep -q 'skipped=2' <<<"$out" || { echo "SELF-TEST FAIL: skip not reported (silent pass)" >&2; exit 1; }
  # A bare (sibling) path must SKIP in a standalone .github checkout EVEN WHEN a file of the
  # same name exists at the repo root — the repo's own AGENTS.md signpost is not the umbrella
  # rulebook. Only a root that MOUNTS the .github repo as `dotgithub/` is the umbrella.
  mkdir -p "$tmp/standalone"
  printf 'a repo-local signpost, not the umbrella rulebook\n' > "$tmp/standalone/AGENTS.md"
  cat > "$tmp/bare.tsv" <<TSV
# claim	surface	path	kind	pattern
canon	umbrella AGENTS.md	AGENTS.md	require	Agent:. FIRST
TSV
  out3="$(check_manifest "$tmp/bare.tsv" "$tmp/standalone" 2>&1)" \
    || { echo "SELF-TEST FAIL: a bare sibling path did not skip in a standalone checkout" >&2; exit 1; }
  grep -q 'skipped=1' <<<"$out3" || { echo "SELF-TEST FAIL: a same-named root file was not skipped (false red)" >&2; exit 1; }
  # The same bare path MUST resolve when the root mounts the .github repo as `dotgithub/`.
  mkdir -p "$tmp/umbrella/dotgithub"
  printf 'the umbrella rulebook: Agent:. FIRST\n' > "$tmp/umbrella/AGENTS.md"
  check_manifest "$tmp/bare.tsv" "$tmp/umbrella" >/dev/null 2>&1 \
    || { echo "SELF-TEST FAIL: a bare sibling path did not resolve in an umbrella root" >&2; exit 1; }
  # ---- the STALE-POINTER control (opencharly/.github#246) ---------------------------
  # A NAMED surface whose OWNER REPO is materialized in this checkout, but whose FILE
  # is absent, is a STALE POINTER and must FAIL — never a skip. A skip means "this
  # checkout does not carry that surface"; a materialized owner with a missing file
  # means the manifest points at a file that moved, and the claim it protects is
  # silently unasserted. That is how 19 of 81 rows protected nothing while the gate
  # looked green.
  #
  # The blocks below are TWO kinds of assertion, and they are not interchangeable:
  #
  #   FAIL assertions (the control must be loud):
  #     out4  a stale pointer — a materialized owner with an absent file — FAILS
  #     out7  an absent TOP-LEVEL surface, owned by the root, FAILS
  #
  #   SKIP assertions (the control must not be paid for with a false red):
  #     out3  a same-named root FILE in a standalone checkout skips  (pre-existing)
  #     out5  an ABSENT owner dir skips
  #     out6  an EMPTY owner dir (an uninitialized submodule path) skips
  #     out8  a name-collision DIRECTORY in a standalone checkout skips
  #     out9  a NON-DIRECTORY owner path skips — the only one of the skip
  #           assertions that can tell the directory guard apart from the
  #           emptiness guard, and therefore the one that fails if either is
  #           removed. See the note at out9.
  mkdir -p "$tmp/stale/dotgithub" "$tmp/stale/owner-repo"
  printf 'a materialized owner repo, with a different file in it\n' > "$tmp/stale/owner-repo/README.md"
  cat > "$tmp/stale-pointer.tsv" <<TSV
# claim	surface	path	kind	pattern
canon	x	owner-repo/moved.md	require	anything
TSV
  out4="$(check_manifest "$tmp/stale-pointer.tsv" "$tmp/stale" 2>&1)" \
    && { echo "SELF-TEST FAIL: a stale pointer (materialized owner, absent file) was accepted" >&2; exit 1; }
  grep -q 'stale pointer' <<<"$out4" \
    || { echo "SELF-TEST FAIL: a stale pointer was not reported as one" >&2; exit 1; }
  # A surface whose owner repo is NOT in this checkout at all — the owner directory
  # does NOT EXIST — SKIPS cleanly: the one legitimate skip, and it stays visible
  # (never a silent pass). The owner dir is deliberately NOT created here: an
  # ABSENT owner and an EMPTY owner are different filesystem states, and the
  # empty one is asserted on its own below.
  mkdir -p "$tmp/unmaterialized/dotgithub"
  cat > "$tmp/uncarried.tsv" <<TSV
# claim	surface	path	kind	pattern
canon	x	absent-repo/some.md	require	anything
TSV
  out5="$(check_manifest "$tmp/uncarried.tsv" "$tmp/unmaterialized" 2>&1)" \
    || { echo "SELF-TEST FAIL: an uncarried surface was not skipped cleanly" >&2; exit 1; }
  grep -q 'skipped=1' <<<"$out5" \
    || { echo "SELF-TEST FAIL: the uncarried-surface skip was not reported" >&2; exit 1; }
  # An EMPTY owner directory is an uninitialized submodule path, NOT a materialized
  # repo: it must SKIP, not fail. This is what keeps the control from turning a
  # light (working-set) checkout into a false red. (Distinct from out5 above: here
  # the owner dir EXISTS and is empty; there it does not exist at all.)
  mkdir -p "$tmp/light/dotgithub" "$tmp/light/empty-owner"
  cat > "$tmp/light.tsv" <<TSV
# claim	surface	path	kind	pattern
canon	x	empty-owner/some.md	require	anything
TSV
  out6="$(check_manifest "$tmp/light.tsv" "$tmp/light" 2>&1)" \
    || { echo "SELF-TEST FAIL: an uninitialized submodule path was reported as a stale pointer" >&2; exit 1; }
  grep -q 'skipped=1' <<<"$out6" \
    || { echo "SELF-TEST FAIL: an uninitialized submodule path did not skip" >&2; exit 1; }
  # A TOP-LEVEL file (the umbrella's own AGENTS.md) is owned by the ROOT, which is
  # present by construction: absent there, it is a stale pointer and must FAIL.
  mkdir -p "$tmp/noag/dotgithub"
  cat > "$tmp/top-level.tsv" <<TSV
# claim	surface	path	kind	pattern
canon	x	AGENTS.md	require	anything
TSV
  out7="$(check_manifest "$tmp/top-level.tsv" "$tmp/noag" 2>&1)" \
    && { echo "SELF-TEST FAIL: an absent top-level surface was accepted" >&2; exit 1; }
  grep -q 'stale pointer' <<<"$out7" \
    || { echo "SELF-TEST FAIL: an absent top-level surface was not reported as a stale pointer" >&2; exit 1; }
  # A STANDALONE .github checkout that happens to carry a directory named like a
  # SIBLING repo must SKIP, not FAIL: a bare path is judged only in an umbrella
  # root (the `dotgithub/` mount), so a name collision there is a coincidence, not
  # a stale pointer. Without this the control would turn a coincidental directory
  # into a false red.
  mkdir -p "$tmp/coincide/marketplace"
  printf 'a local directory that merely shares a sibling repo name\n' > "$tmp/coincide/marketplace/README.md"
  cat > "$tmp/coincide.tsv" <<TSV
# claim	surface	path	kind	pattern
canon	x	marketplace/internals/skills/x/SKILL.md	require	anything
TSV
  out8="$(check_manifest "$tmp/coincide.tsv" "$tmp/coincide" 2>&1)" \
    || { echo "SELF-TEST FAIL: a name collision in a standalone checkout was reported as a stale pointer" >&2; exit 1; }
  grep -q 'skipped=1' <<<"$out8" \
    || { echo "SELF-TEST FAIL: the name-collision skip was not reported" >&2; exit 1; }
  # A NON-DIRECTORY owner path — a stray FILE that happens to share a sibling
  # repo's name — must SKIP, not FAIL. This is the assertion that DISCRIMINATES
  # the two owner guards: `ls -A` on a FILE prints the file's name, so with the
  # `[[ -d "$rt/$owner" ]]` guard removed the owner would look materialized and
  # the checker would raise a false stale-pointer red. The absent-owner (out5)
  # and empty-owner (out6) cases cannot do this job — they skip with or without
  # the guard — so without this assertion the directory guard has no coverage
  # that can fail (opencharly/.github#253).
  mkdir -p "$tmp/filed/dotgithub"
  printf 'a stray file that merely shares a sibling repo name\n' > "$tmp/filed/marketplace"
  cat > "$tmp/filed-owner.tsv" <<TSV
# claim	surface	path	kind	pattern
canon	x	marketplace/internals/skills/x/SKILL.md	require	anything
TSV
  out9="$(check_manifest "$tmp/filed-owner.tsv" "$tmp/filed" 2>&1)" \
    || { echo "SELF-TEST FAIL: a non-directory owner path was reported as a stale pointer" >&2; exit 1; }
  grep -q 'skipped=1' <<<"$out9" \
    || { echo "SELF-TEST FAIL: the non-directory-owner skip was not reported" >&2; exit 1; }
  # ---- the ANCHOR control (opencharly/.github#250) ----------------------------------
  # A path that NO 'require' row pins is UNANCHORED: the only rows that name it are
  # 'forbid' rows, and a forbid row asserts that a phrase is ABSENT — vacuously true of
  # ANY file at that path, including a file that holds no rule at all. So the table could
  # not say "this path IS the surface", and the row could never go red.
  #
  # The control is about the TABLE, not about the checkout, so the verdict does not
  # depend on whether the surface is carried here: out11 asserts it in a checkout that
  # does not carry the surface at all.
  cat > "$tmp/unanchored.tsv" <<TSV
# claim	surface	path	kind	pattern
canon	a	dotgithub/one.txt	require	canonical phrase
legacy	b	sibling/two.txt	forbid	old legacy phrase
TSV
  out10="$(check_manifest "$tmp/unanchored.tsv" "$tmp" 2>&1)" \
    && { echo "SELF-TEST FAIL: an unanchored surface was accepted" >&2; exit 1; }
  grep -q 'UNANCHORED' <<<"$out10" \
    || { echo "SELF-TEST FAIL: the unanchored surface was not reported as one" >&2; exit 1; }
  out11="$(check_manifest "$tmp/unanchored.tsv" "$tmp/dotgithub" 2>&1)" \
    && { echo "SELF-TEST FAIL: an unanchored surface was accepted in a checkout that does not carry it" >&2; exit 1; }
  grep -q 'UNANCHORED' <<<"$out11" \
    || { echo "SELF-TEST FAIL: the unanchored surface was not reported in a checkout that does not carry it" >&2; exit 1; }
  # The SHIPPED manifest must have no unanchored surface: every path it names is pinned
  # by at least one 'require' row. (The rows themselves are judged against the real
  # umbrella by the CI form and by the strong form; this asserts the TABLE's shape.)
  out12="$(check_manifest "$HERE/governance-claims.tsv" "$tmp" 2>&1)" || true
  grep -q 'UNANCHORED' <<<"$out12" \
    && { echo "SELF-TEST FAIL: the shipped manifest holds an unanchored surface" >&2; exit 1; }
  # The real manifest's header row must be ignored, never reported as a bad kind.
  out2="$(check_manifest "$HERE/governance-claims.tsv" "$tmp" 2>&1)" || true
  grep -q "unknown kind 'kind'" <<<"$out2" && { echo "SELF-TEST FAIL: the manifest header row was parsed as a claim" >&2; exit 1; }
  echo "governance-reconcile --self-test: all assertions passed"
  exit 0
fi

# Default root: THIS repo's checkout root (…/dotgithub == the .github repo root), which is
# what the wired CI step (validator-harness.yml) sees. In that standalone layout only this
# repo's own `dotgithub/`-prefixed surfaces exist; the sibling-repo rows SKIP visibly. Pass
# `--root <umbrella checkout>` to assert every row (the umbrella holds the sibling repos).
[[ -n "$root" ]] || root="$(cd "$HERE/.." && pwd)"

echo "governance-reconcile: root=$root manifest=$manifest"
check_manifest "$manifest" "$root"
