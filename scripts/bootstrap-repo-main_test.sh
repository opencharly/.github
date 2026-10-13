#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT

# Mock state:
#   empty  — no main ref, has a feat branch (must create main from that SHA)
#   seeded — no main ref, default branch is `dev` (must seed from `dev`)
#   hasmain— already has main (must skip, never move it)
#   bare   — no main and no other ref (must skip, nothing to seed from)
: >"$STATE/transcript"

gh() {
  if [[ "$1 $2" == "repo list" ]]; then
    [[ "${FORCE_TARGETS_FAIL:-}" == 1 ]] && return 1
    printf 'bare\nempty\nhasmain\nseeded\n'; return 0
  fi
  [[ "$1" == api ]] || return 90
  shift
  local method=GET path="" jqexpr=""
  local -a fargs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --method) method="$2"; shift 2 ;;
      --jq) jqexpr="$2"; shift 2 ;;
      --include) shift ;;
      -f) fargs+=("$2"); shift 2 ;;
      --*) shift ;;
      *) [[ -z "$path" ]] && path="$1"; shift ;;
    esac
  done
  [[ -n "$path" ]] || return 90

  case "$path" in
    repos/test/*)
      local repo="${path#repos/test/}"; repo="${repo%%/*}"; local rest="${path#repos/test/$repo}"
      case "$rest" in
        "") # repos/test/<repo> -> default branch
          case "$repo" in
            seeded) printf 'dev\n'; return 0 ;;
            bare)   printf 'main\n'; return 0 ;;
            *)      printf 'feat/x\n'; return 0 ;;
          esac ;;
        /git/ref/heads/main)
          # stateful: a main created earlier in this test run now exists.
          if [[ -f "$STATE/main_$repo" ]] || [[ "$repo" == "hasmain" ]]; then
            printf 'c0ffee\n'; return 0
          fi
          return 1 ;;  # no main ref -> 404
        /git/ref/heads/*)
          local br="${rest#/git/ref/heads/}"
          case "$repo:$br" in
            seeded:dev) printf 'd3vsha\n'; return 0 ;;
            empty:feat/x) printf 'f3atsha\n'; return 0 ;;
            *) return 1 ;;
          esac ;;
        /git/matching-refs/heads)
          case "$repo" in
            bare) printf '[]\n'; return 0 ;;
            seeded) printf '["refs/heads/dev"]\n'; return 0 ;;
            *) printf '["refs/heads/feat/x"]\n'; return 0 ;;
          esac ;;
        /git/refs)
          [[ "$method" == POST ]] || return 91
          local ref="" sha=""
          local kv
          for kv in "${fargs[@]}"; do
            case "$kv" in
              ref=*) ref="${kv#ref=}" ;;
              sha=*) sha="${kv#sha=}" ;;
            esac
          done
          printf 'created %s -> %s\n' "$ref" "$sha" >>"$STATE/transcript"
          printf 'main\n' >>"$STATE/main_$repo"
          printf '"%s"\n' "$ref"; return 0 ;;
        /contents/*)
          # The tag-on-merge caller install + its read-back assertion
          # (opencharly/.github#180). PUT writes it; GET reports it only once written,
          # so a "reported success but nothing on main" path is detectable.
          if [[ "$method" == PUT ]]; then
            printf 'PUT %s\n' "${rest%%\?*}" >>"$STATE/transcript"
            printf 'installed\n' >"$STATE/caller_$repo"
            printf '"commitsha"\n'; return 0
          fi
          if [[ -f "$STATE/caller_$repo" ]]; then printf '"blobsha"\n'; return 0; fi
          return 1 ;;
        *) return 92 ;;
      esac ;;
    *) return 93 ;;
  esac
}
export -f gh
export STATE

# happy path: empty (from feat/x) + seeded (from dev) created; hasmain + bare skipped.
GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/bootstrap-repo-main.sh" >"$STATE/out" 2>"$STATE/err"
grep -qx 'created refs/heads/main -> f3atsha' "$STATE/transcript" \
  || { echo "FAIL: empty repo main must be seeded from the default feat branch" >&2; exit 1; }
grep -qx 'created refs/heads/main -> d3vsha' "$STATE/transcript" \
  || { echo "FAIL: seeded repo main must be seeded from dev" >&2; exit 1; }
grep -q 'hasmain' "$STATE/transcript" && { echo "FAIL: a repo that already has main must not be touched" >&2; exit 1; }

# The ref alone leaves the repo's FIRST merge untagged: the tag-on-merge caller must be
# INSTALLED on the created main and READ BACK (opencharly/.github#180).
grep -qx 'PUT /contents/.github/workflows/tag-on-merge.yml' "$STATE/transcript" \
  || { echo "FAIL: the tag-on-merge caller must be installed on a created main" >&2; exit 1; }
[[ -f "$STATE/caller_empty" && -f "$STATE/caller_seeded" ]] \
  || { echo "FAIL: the caller must be installed for every created main" >&2; exit 1; }

# The three settings the App token CANNOT set are named for the operator, and counted in
# the machine-readable summary — the omission must not be silent in either surface.
grep -q 'default_branch=main' "$STATE/err" \
  || { echo "FAIL: the operator remedy must name the default-branch PATCH" >&2; exit 1; }
grep -q 'allow_auto_merge=true' "$STATE/err" \
  || { echo "FAIL: the operator remedy must name the auto-merge PATCH" >&2; exit 1; }
grep -q 'needs_operator_settings=2' "$STATE/out" \
  || { echo "FAIL: the summary must count the repos awaiting operator settings" >&2; exit 1; }

# idempotent: a second run creates nothing new (all now have main or nothing to seed).
: >"$STATE/transcript"
GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/bootstrap-repo-main.sh" >/dev/null
[[ -s "$STATE/transcript" ]] && { echo "FAIL: second run must be a no-op" >&2; exit 1; }

# explicit repo arguments restrict the target set (reset `empty` first).
rm -f "$STATE/main_empty"
: >"$STATE/transcript"
GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/bootstrap-repo-main.sh" empty >"$STATE/out3" 2>"$STATE/err3"
grep -qx 'created refs/heads/main -> f3atsha' "$STATE/transcript" \
  || { echo "FAIL: explicit repo arg must bootstrap only that repo" >&2; exit 1; }
grep -q 'd3vsha' "$STATE/transcript" && { echo "FAIL: explicit repo arg must not touch other repos" >&2; exit 1; }
# the operator remedy is per-RUN: exactly the repos this run bootstrapped.
grep -q 'needs_operator_settings=1' "$STATE/out3" \
  || { echo "FAIL: the summary must count only this run's bootstrapped repos" >&2; exit 1; }
grep -q 'PATCH repos/test/empty -f default_branch=main' "$STATE/err3" \
  || { echo "FAIL: the remedy block must name the repo this run bootstrapped" >&2; exit 1; }

# a repo discovery failure must ABORT, never read as "nothing to do".
if FORCE_TARGETS_FAIL=1 GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/bootstrap-repo-main.sh" >/dev/null 2>&1; then
  echo "FAIL: must abort when repo discovery fails" >&2; exit 1
fi

# GH_TOKEN is required.
if OPENCHARLY_ORG=test "$root/scripts/bootstrap-repo-main.sh" >/dev/null 2>&1; then
  echo "FAIL: must require GH_TOKEN" >&2; exit 1
fi

echo "bootstrap-repo-main_test: all assertions passed"
