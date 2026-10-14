#!/usr/bin/env bash
# reconcile-tag-on-merge-callers.sh — the UPDATE half of retire-per-repo-dispatchers.sh.
#
# Every repo's `.github/workflows/tag-on-merge.yml` is a COPY of this repo's canonical
# template, installed at bootstrap. `install_tag_caller()` (bootstrap-repo-main.sh) returns
# early when the file exists ("already present — untouched"), so the bootstrap installs into
# NEW repos and structurally cannot update an existing one. PR #189 pinned the template to an
# immutable Node 24 commit; the distributed copies were never swept. Nothing bound a copy to
# the template. This script is that binding.  See opencharly/.github#192.
#
#   verify  (default, READ-ONLY, idempotent) — report every repo's caller state.
#   --apply                                  — PUT canonical content where it DIFFERS.
#
# TWO ORTHOGONAL QUESTIONS, reported as two columns (one merged number read as `0` on the
# question that matters):
#   pin   — is the copy still running the MUTABLE action pin (`@v7`)?  (T3 / Node 20)
#   prose — does it differ from the canonical template otherwise?      (template revision)
# A copy can be both, either or neither.  Measured: the norm is BOTH, because every copy
# froze at whatever template revision existed at its bootstrap.
#
# `absent` is REPORTED, never installed: a repo with no caller has not drifted — it never
# had one, and installing a dispatcher there changes that repo's behaviour (it would start
# minting CalVer tags and CHANGELOGs it never had). That decision belongs to the rollout issue.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-org.sh
source "$HERE/lib-org.sh"

TEMPLATE="$HERE/../.github/workflows/tag-on-merge-dispatcher.yml"
CALLER_PATH=".github/workflows/tag-on-merge.yml"
USES_RE='^[[:space:]]*- uses: actions/github-script@.*$'
SHA_RE='@[0-9a-f]{40}'

# norm — blank the whole `- uses: actions/github-script@…` line (it carries a trailing
# comment in the canonical form), so the prose comparison is about PROSE.
norm() { printf '%s\n' "$1" | sed -E "s#$USES_RE#  - uses: PIN#"; }

# pin_state — PURE. mutable | pinned | no-uses | absent
pin_state() {
  local c="$1" pin
  [[ -z "$c" ]] && { echo absent; return 0; }
  pin="$(printf '%s\n' "$c" | grep -m1 -oE 'actions/github-script@[^ ]*' || true)"
  [[ -z "$pin" ]] && { echo no-uses; return 0; }
  if printf '%s' "$pin" | grep -qE "$SHA_RE"; then echo pinned; else echo mutable; fi
}

# prose_state — PURE. identical | drifted | absent
prose_state() {
  local can="$1" inst="$2"
  [[ -z "$inst" ]] && { echo absent; return 0; }
  if [[ "$(norm "$can")" == "$(norm "$inst")" ]]; then echo identical; else echo drifted; fi
}

fetch_caller() {
  local repo="$1" b64
  if ! b64="$(gh api "repos/$ORG/$repo/contents/$CALLER_PATH?ref=main" --jq .content 2>/dev/null)"; then
    echo ""; return 0
  fi
  printf '%s' "$b64" | base64 -d 2>/dev/null || echo ""
}

show_how() { diff <(norm "$1") <(norm "$2") | grep -E '^[<>]' | head -4 | sed 's/^/        /' || true; }

main() {
  local mode="${1:-verify}"
  case "$mode" in verify|--apply) ;; *) echo "usage: $0 [verify|--apply]" >&2; exit 2 ;; esac
  [[ -f "$TEMPLATE" ]] || { echo "missing canonical template: $TEMPLATE" >&2; exit 1; }
  local canonical; canonical="$(cat "$TEMPLATE")"
  local blob; blob="$(git -C "$HERE/.." rev-parse HEAD:.github/workflows/tag-on-merge-dispatcher.yml 2>/dev/null || true)"

  local -a REPOS=() EXCLUDED=()
  local repos_raw excludes_raw
  if ! repos_raw="$(discover_repos)"; then echo "FATAL: discover_repos failed" >&2; exit 1; fi
  mapfile -t REPOS <<<"$repos_raw"
  if ! excludes_raw="$(discover_excludes)"; then echo "FATAL: discover_excludes failed" >&2; exit 1; fi
  mapfile -t EXCLUDED <<<"$excludes_raw"

  local m_pin=0 p_pin=0 n_pin=0 a_caller=0 prose_ok=0 prose_drift=0 both=0 neither=0
  local -a L_MUT=() L_DRIFT=() L_BOTH=() L_ABSENT=()
  local repo pin prose content
  for repo in "${REPOS[@]}"; do
    [[ -z "$repo" ]] && continue
    content="$(fetch_caller "$repo")"
    pin="$(pin_state "$content")"; prose="$(prose_state "$canonical" "$content")"
    case "$pin"  in mutable) m_pin=$((m_pin+1)); L_MUT+=("$repo") ;; pinned) p_pin=$((p_pin+1)) ;; no-uses) n_pin=$((n_pin+1)) ;; absent) a_caller=$((a_caller+1)); L_ABSENT+=("$repo") ;; esac
    case "$prose" in identical) prose_ok=$((prose_ok+1)) ;; drifted) prose_drift=$((prose_drift+1)); L_DRIFT+=("$repo") ;; esac
    [[ "$pin" == mutable && "$prose" == drifted ]] && { both=$((both+1)); L_BOTH+=("$repo"); }
    [[ "$pin" == pinned  && "$prose" == identical ]] && neither=$((neither+1))
    if [[ "$mode" == "--apply" && "$content" != "$canonical" && -n "$content" ]]; then
      local sha; sha="$(gh api "repos/$ORG/$repo/contents/$CALLER_PATH?ref=main" --jq .sha)"
      gh api --method PUT "repos/$ORG/$repo/contents/$CALLER_PATH" \
        -f message="ci: reconcile the tag-on-merge caller with the canonical template (opencharly/.github#192)" \
        -f content="$(printf '%s' "$canonical" | base64 -w0)" -f sha="$sha" >/dev/null
      [[ "$(fetch_caller "$repo")" == "$canonical" ]] || { echo "  READ-BACK FAILED: $repo" >&2; exit 1; }
      echo "  reconciled (pin=$pin prose=$prose): $repo"
    fi
  done

  echo "reconcile-tag-on-merge-callers: mode=$mode"
  echo "  canonical template : ${TEMPLATE#"$HERE/../"}  (blob ${blob:0:12})"
  echo "  canonical pin      : $(grep -m1 -oE 'actions/github-script@[^ ]*' "$TEMPLATE")"
  echo "  repos examined     : ${#REPOS[@]}"
  echo
  echo "  COLUMN 1 — pin (the T3 / Node-20 question)"
  echo "    pin-mutable (still unpinned)  : $m_pin"
  echo "    pin-pinned  (immutable)       : $p_pin"
  echo "    pin-no-uses (no such step)    : $n_pin"
  echo "    caller-absent                 : $a_caller"
  echo "  COLUMN 2 — prose (the template-revision question)"
  echo "    prose-canonical               : $prose_ok"
  echo "    prose-drifted                 : $prose_drift"
  echo "  BOTH (mutable pin AND drifted prose) : $both"
  echo "  NEITHER (pinned pin AND canonical prose) : $neither"
  echo
  echo "  could-not-see (excluded by discover_repos — archived, fork, non-main default): ${#EXCLUDED[@]}"
  for repo in "${EXCLUDED[@]}"; do [[ -n "$repo" ]] && echo "    [could-not-see] $repo"; done
  echo
  for repo in "${L_MUT[@]+"${L_MUT[@]}"}"; do echo "  [pin-mutable]  $repo"; done
  for repo in "${L_BOTH[@]+"${L_BOTH[@]}"}"; do echo "  [both]         $repo"; done
  for repo in "${L_DRIFT[@]+"${L_DRIFT[@]}"}"; do
    echo "  [prose-drifted] $repo"
    show_how "$canonical" "$(fetch_caller "$repo")"
  done
  for repo in "${L_ABSENT[@]+"${L_ABSENT[@]}"}"; do echo "  [caller-absent] $repo"; done
  if [[ "$mode" != "--apply" && $((m_pin+prose_drift)) -gt 0 ]]; then
    echo
    echo "  (read-only run — nothing written. --apply brings every DIFFERING caller to canonical;"
    echo "   caller-absent and could-not-see are reported only, by design.)"
  fi
}
if [[ "${1:-}" == "--source-only" ]]; then return 0 2>/dev/null || exit 0; fi
main "$@"
