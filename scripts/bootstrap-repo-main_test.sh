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
        *) return 92 ;;
      esac ;;
    *) return 93 ;;
  esac
}
export -f gh
export STATE

# happy path: empty (from feat/x) + seeded (from dev) created; hasmain + bare skipped.
GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/bootstrap-repo-main.sh" >/dev/null
grep -qx 'created refs/heads/main -> f3atsha' "$STATE/transcript" \
  || { echo "FAIL: empty repo main must be seeded from the default feat branch" >&2; exit 1; }
grep -qx 'created refs/heads/main -> d3vsha' "$STATE/transcript" \
  || { echo "FAIL: seeded repo main must be seeded from dev" >&2; exit 1; }
grep -q 'hasmain' "$STATE/transcript" && { echo "FAIL: a repo that already has main must not be touched" >&2; exit 1; }

# idempotent: a second run creates nothing new (all now have main or nothing to seed).
: >"$STATE/transcript"
GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/bootstrap-repo-main.sh" >/dev/null
[[ -s "$STATE/transcript" ]] && { echo "FAIL: second run must be a no-op" >&2; exit 1; }

# explicit repo arguments restrict the target set (reset `empty` first).
rm -f "$STATE/main_empty"
: >"$STATE/transcript"
GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/bootstrap-repo-main.sh" empty >/dev/null
grep -qx 'created refs/heads/main -> f3atsha' "$STATE/transcript" \
  || { echo "FAIL: explicit repo arg must bootstrap only that repo" >&2; exit 1; }
grep -q 'd3vsha' "$STATE/transcript" && { echo "FAIL: explicit repo arg must not touch other repos" >&2; exit 1; }

# a repo discovery failure must ABORT, never read as "nothing to do".
if FORCE_TARGETS_FAIL=1 GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/bootstrap-repo-main.sh" >/dev/null 2>&1; then
  echo "FAIL: must abort when repo discovery fails" >&2; exit 1
fi

# GH_TOKEN is required.
if OPENCHARLY_ORG=test "$root/scripts/bootstrap-repo-main.sh" >/dev/null 2>&1; then
  echo "FAIL: must require GH_TOKEN" >&2; exit 1
fi

echo "bootstrap-repo-main_test: all assertions passed"
