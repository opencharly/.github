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
# `absent` is REPORTED, never installed IN THE DEFAULT (targets) SCOPE: a non-fork repo with
# no caller has not drifted — it never had one, and installing a dispatcher there changes
# that repo's behaviour. SCOPE=forks is the ONE scope that INSTALLS an absent caller, because
# the operator's rollout decision (opencharly/.github#320) is that every first-party fork
# mints CalVer. The two scopes are separate call sites, never one policy. A fork write
# targets the fork's DEFAULT branch (`stable`/`master` included), and a copy that pins the
# reusable to a 40-hex SHA keeps that policy: the reconciler substitutes the CURRENT
# opencharly/.github `main` SHA, read at run time, never a hand-bumped literal.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-org.sh
source "$HERE/lib-org.sh"

TEMPLATE="$HERE/../.github/workflows/tag-on-merge-dispatcher.yml"
CALLER_PATH=".github/workflows/tag-on-merge.yml"
USES_RE='^[[:space:]]*- uses: actions/github-script@.*$'
REUSABLE_RE='^[[:space:]]*uses: opencharly/\.github/\.github/workflows/tag-on-merge\.yml@[^[:space:]]+.*$'
SHA_RE='^[0-9a-f]{40}$'

# norm — blank the github-script line AND the reusable's ref, so the prose comparison is
# about PROSE. Whether a SHA-pinned ref is CURRENT is a separate question (ref_state).
norm() { printf '%s\n' "$1" | sed -E "s#$USES_RE#  - uses: PIN#; s#$REUSABLE_RE#  - uses: REUSABLE#"; }

# pin_state — PURE. mutable | pinned | no-uses | absent
pin_state() {
  local c="$1" pin
  [[ -z "$c" ]] && { echo absent; return 0; }
  pin="$(printf '%s\n' "$c" | grep -m1 -oE 'actions/github-script@[^ ]*' || true)"
  [[ -z "$pin" ]] && { echo no-uses; return 0; }
  if printf '%s' "$pin" | grep -qE '@[0-9a-f]{40}'; then echo pinned; else echo mutable; fi
}

# prose_state — PURE. identical | drifted | absent
prose_state() {
  local can="$1" inst="$2"
  [[ -z "$inst" ]] && { echo absent; return 0; }
  if [[ "$(norm "$can")" == "$(norm "$inst")" ]]; then echo identical; else echo drifted; fi
}

# reusable_ref — the ref on the line `uses: opencharly/.github/.../tag-on-merge.yml@<ref>`.
# Empty when there is no such line. awk scans the WHOLE text (no early `exit`, which would
# SIGPIPE the printf feeding it under `set -o pipefail`).
reusable_ref() {
  printf '%s\n' "$1" | awk '/uses: opencharly\/\.github\/\.github\/workflows\/tag-on-merge\.yml@/ {
    sub(/.*tag-on-merge\.yml@/, ""); sub(/[[:space:]].*/, ""); ref=$0
  } END { print ref }'
}

# ref_state <content> <current-dotgithub-sha> — main | sha-current | sha-stale | other | absent
ref_state() {
  local c="$1" sha="$2" ref
  [[ -z "$c" ]] && { echo absent; return 0; }
  ref="$(reusable_ref "$c")"
  case "$ref" in
    "")   echo other ;;
    main) echo main ;;
    *) if [[ "$ref" =~ $SHA_RE ]]; then
         [[ -n "$sha" && "$ref" == "$sha" ]] && echo sha-current || echo sha-stale
       else echo other; fi ;;
  esac
}

# render_canonical <canonical> <sha> — the canonical caller with a policy repo's SHA pin.
# An empty <sha> leaves the canonical `@main` (the safe, mutable form).
render_canonical() {
  local can="$1" sha="$2"
  if [[ -z "$sha" ]]; then printf '%s\n' "$can"; return 0; fi
  printf '%s\n' "$can" | sed -E "s#(uses: opencharly/\.github/\.github/workflows/tag-on-merge\.yml)@[^[:space:]]+#\1@$sha#"
}

# filter_fork_rows lives in lib-org.sh (shared with sync-forks.sh, R2).

fetch_caller() {
  local repo="$1" ref="${2:-main}" b64
  if ! b64="$(gh api "repos/$ORG/$repo/contents/$CALLER_PATH?ref=$ref" --jq .content 2>/dev/null)"; then
    echo ""; return 0
  fi
  printf '%s' "$b64" | base64 -d 2>/dev/null || echo ""
}

show_how() { diff <(norm "$1") <(norm "$2") | grep -E '^[<>]' | head -4 | sed 's/^/        /' || true; }

# write_caller <repo> <default> <body> <existing-sha|""> <birth:0|1> <pin> <prose>
# ONE commit via the contents API, then a read-back. A BIRTH (the file did not exist) is
# design-pintag's `pre-release-process`, so it is NOT tagged; an UPDATE is tagged, because a
# head left untagged fails the pin-tag control for every pin that advances to it (#294).
write_caller() {
  local repo="$1" default="$2" body="$3" sha="$4" birth="$5" pin="$6" prose="$7" resp commit_sha tag
  if [[ -n "$sha" ]]; then
    resp="$(gh api --method PUT "repos/$ORG/$repo/contents/$CALLER_PATH" \
      -f message="ci: reconcile the tag-on-merge caller with the canonical template (opencharly/.github#192)" \
      -f content="$(printf '%s' "$body" | base64 -w0)" -f sha="$sha" -f branch="$default")"
  else
    resp="$(gh api --method PUT "repos/$ORG/$repo/contents/$CALLER_PATH" \
      -f message="ci: install the canonical tag-on-merge caller (opencharly/.github#320)" \
      -f content="$(printf '%s' "$body" | base64 -w0)" -f branch="$default")"
  fi
  commit_sha="$(printf '%s' "$resp" | jq -r '.commit.sha // empty')"
  [[ -n "$commit_sha" ]] || { echo "  NO COMMIT SHA RETURNED — cannot tag it: $repo" >&2; exit 1; }
  [[ "$(fetch_caller "$repo" "$default")" == "$body" ]] || { echo "  READ-BACK FAILED: $repo" >&2; exit 1; }
  if [[ "$birth" == 1 ]]; then
    echo "  installed on $default (birth commit — design-pintag pre-release-process): $repo"
    return 0
  fi
  tag="$(calver_at "$ORG" "$repo" "$commit_sha")" || { echo "  CANNOT DERIVE A CALVER: $repo" >&2; exit 1; }
  if ! gh api "repos/$ORG/$repo/git/ref/tags/$tag" >/dev/null 2>&1; then
    gh api --method POST "repos/$ORG/$repo/git/refs" \
      -f ref="refs/tags/$tag" -f sha="$commit_sha" >/dev/null \
      || { echo "  TAG CREATE FAILED ($tag): $repo" >&2; exit 1; }
  fi
  echo "  reconciled (pin=$pin prose=$prose) at $tag on $default: $repo"
}

# The allow-list exists because a distribution is one commit on each repo's default branch:
# it can be PILOTED on a named few and read back before it reaches the rest.
# `.github/workflows/reconcile-tag-on-merge-callers.yml` exposes it as its `repos` input.
main() {
  local mode="${1:-verify}"
  case "$mode" in verify|--apply) ;; *) echo "usage: $0 [verify|--apply]" >&2; exit 2 ;; esac
  [[ -f "$TEMPLATE" ]] || { echo "missing canonical template: $TEMPLATE" >&2; exit 1; }
  local canonical; canonical="$(cat "$TEMPLATE")"
  local blob; blob="$(git -C "$HERE/.." rev-parse HEAD:.github/workflows/tag-on-merge-dispatcher.yml 2>/dev/null || true)"
  SCOPE="${SCOPE:-targets}"
  case "$SCOPE" in targets|forks) ;; *) echo "SCOPE must be targets|forks" >&2; exit 2 ;; esac

  local rows raw
  if [[ "$SCOPE" == forks ]]; then
    rows="$(discover_forks)" || { echo "FATAL: discover_forks failed" >&2; exit 1; }
    rows="$(filter_fork_rows "$rows" "${RECONCILE_REPOS:-}")"
  else
    raw="$(discover_repos)" || { echo "FATAL: discover_repos failed" >&2; exit 1; }
    raw="$(printf '%s\n' "$raw" | select_repos "${RECONCILE_REPOS:-}")"
    rows="$(printf '%s\n' "$raw" | awk 'NF { print $0 "\tmain" }')"
  fi

  # The CURRENT reusable ref, for a fork whose copy pins it to a SHA. Read once; a failed
  # read leaves it empty (the copy is then rendered @main) and is REPORTED, never hidden.
  local dotgithub_sha=""
  if [[ "$SCOPE" == forks ]]; then
    dotgithub_sha="$(gh api "repos/$ORG/${SOURCE_REPO:-.github}/commits/main" --jq .sha 2>/dev/null || true)"
    [[ -n "$dotgithub_sha" ]] || echo "  WARNING: could not read ${SOURCE_REPO:-.github} main — a SHA-pinned fork copy will be rendered @main" >&2
  fi

  local m_pin=0 p_pin=0 n_pin=0 a_caller=0 prose_ok=0 prose_drift=0 both=0 neither=0 installed=0
  local -a L_MUT=() L_DRIFT=() L_BOTH=() L_ABSENT=()
  local -A DEFAULTS=()
  local repo default content pin prose refk want sha
  while IFS=$'\t' read -r repo default; do
    [[ -z "$repo" ]] && continue
    default="${default:-main}"
    DEFAULTS["$repo"]="$default"
    # NEVER touch the SOURCE repo. Its `.github/workflows/tag-on-merge.yml` is the
    # REUSABLE workflow every caller invokes, not a copy of the caller template; writing
    # the template there replaces the reusable with a caller and breaks every
    # `uses: opencharly/.github/...@main` in the org (measured: opencharly/.github#294).
    if [[ "$repo" == "${SOURCE_REPO:-.github}" ]]; then
      echo "  skipped (the source repo holds the REUSABLE, not a caller): $repo"
      continue
    fi
    content="$(fetch_caller "$repo" "$default")"
    pin="$(pin_state "$content")"; prose="$(prose_state "$canonical" "$content")"
    refk="$(ref_state "$content" "$dotgithub_sha")"
    want="$canonical"
    if [[ "$SCOPE" == forks && ( "$refk" == sha-current || "$refk" == sha-stale ) ]]; then
      want="$(render_canonical "$canonical" "$dotgithub_sha")"
    fi
    case "$pin"  in mutable) m_pin=$((m_pin+1)); L_MUT+=("$repo") ;; pinned) p_pin=$((p_pin+1)) ;; no-uses) n_pin=$((n_pin+1)) ;; absent) a_caller=$((a_caller+1)); L_ABSENT+=("$repo") ;; esac
    case "$prose" in identical) prose_ok=$((prose_ok+1)) ;; drifted) prose_drift=$((prose_drift+1)); L_DRIFT+=("$repo") ;; esac
    [[ "$pin" == mutable && "$prose" == drifted ]] && { both=$((both+1)); L_BOTH+=("$repo"); }
    [[ "$pin" == pinned  && "$prose" == identical ]] && neither=$((neither+1))
    if [[ "$mode" == "--apply" ]]; then
      if [[ -z "$content" ]]; then
        if [[ "$SCOPE" == forks ]]; then
          write_caller "$repo" "$default" "$want" "" 1 "" ""
          installed=$((installed+1))
        fi
      elif [[ "$content" != "$want" ]]; then
        sha="$(gh api "repos/$ORG/$repo/contents/$CALLER_PATH?ref=$default" --jq .sha)"
        write_caller "$repo" "$default" "$want" "$sha" 0 "$pin" "$prose"
      fi
    fi
  done <<<"$rows"

  echo "reconcile-tag-on-merge-callers: mode=$mode scope=$SCOPE"
  echo "  canonical template : ${TEMPLATE#"$HERE/../"}  (blob ${blob:0:12})"
  echo "  canonical pin      : $(grep -m1 -oE 'actions/github-script@[^ ]*' "$TEMPLATE")"
  echo "  repos examined     : $(printf '%s\n' "$rows" | sed '/^$/d' | wc -l)"
  echo "  repos allow-list   : ${RECONCILE_REPOS:-<all discovered>}"
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
  echo "  installed on a fork (birth)  : $installed"
  echo
  if [[ "$SCOPE" == forks ]]; then
    local arch
    arch="$(discover_archived_forks)" || { echo "FATAL: discover_archived_forks failed" >&2; exit 1; }
    echo "  could-not-see (archived forks) : $(printf '%s\n' "$arch" | sed '/^$/d' | wc -l)"
    while IFS= read -r repo; do [[ -n "$repo" ]] && echo "    [archived-fork] $repo"; done <<<"$arch"
  else
    local excludes_raw
    excludes_raw="$(discover_excludes)" || { echo "FATAL: discover_excludes failed" >&2; exit 1; }
    echo "  could-not-see (excluded by discover_repos — archived, fork, non-main default): $(printf '%s\n' "$excludes_raw" | sed '/^$/d' | wc -l)"
    while IFS= read -r repo; do [[ -n "$repo" ]] && echo "    [could-not-see] $repo"; done <<<"$excludes_raw"
  fi
  echo
  for repo in "${L_MUT[@]+"${L_MUT[@]}"}"; do echo "  [pin-mutable]  $repo"; done
  for repo in "${L_BOTH[@]+"${L_BOTH[@]}"}"; do echo "  [both]         $repo"; done
  for repo in "${L_DRIFT[@]+"${L_DRIFT[@]}"}"; do
    echo "  [prose-drifted] $repo"
    show_how "$canonical" "$(fetch_caller "$repo" "${DEFAULTS[$repo]:-main}")"
  done
  for repo in "${L_ABSENT[@]+"${L_ABSENT[@]}"}"; do echo "  [caller-absent] $repo"; done
  if [[ "$mode" != "--apply" && $((m_pin+prose_drift+a_caller)) -gt 0 ]]; then
    echo
    echo "  (read-only run — nothing written. --apply brings every DIFFERING caller to canonical;"
    echo "   in the targets scope caller-absent and could-not-see are reported only, by design;"
    echo "   in the forks scope an absent caller is INSTALLED, on the fork's default branch.)"
  fi
}
if [[ "${1:-}" == "--source-only" ]]; then return 0 2>/dev/null || exit 0; fi
main "$@"
