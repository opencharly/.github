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
# sibling-repo surface (the umbrella `AGENTS.md`, `layer-charly-internals/…`,
# `marketplace/…`) — absent in a standalone .github checkout, so it SKIPS cleanly.
is_local() { case "$1" in dotgithub/*) return 0;; *) return 1;; esac; }

# resolve_path <root> <manifest-path> — the file for a row, or empty if absent.
#
# A `dotgithub/`-prefixed path is the .github repo's OWN surface: it resolves at
# <root>/dotgithub/<p> in the umbrella and at <root>/<p> in a standalone .github
# checkout (where the repo IS the root).
#
# Every other (bare) path names a SIBLING-repo surface relative to the UMBRELLA
# root (`AGENTS.md`, `layer-charly-internals/…`, `marketplace/…`). Those resolve
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

# check_manifest <manifest> <root> — the checker. 0 = reconciled, 1 = drift.
check_manifest() {
  local mf="$1" rt="$2" fail=0 checked=0 skipped=0 lineno=0
  [[ -f "$mf" ]] || { echo "FATAL: manifest not found: $mf" >&2; return 1; }
  local claim surface path kind pattern target
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
legacy	b	sibling/two.txt	forbid	old legacy phrase
TSV
  cat > "$tmp/fail-absent.tsv" <<TSV
# claim	surface	path	kind	pattern
canon	a	dotgithub/one.txt	require	a phrase that is ABSENT
TSV
  cat > "$tmp/fail-forbid.tsv" <<TSV
# claim	surface	path	kind	pattern
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
  grep -q 'skipped=1' <<<"$out" || { echo "SELF-TEST FAIL: skip not reported (silent pass)" >&2; exit 1; }
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
