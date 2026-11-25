#!/usr/bin/env bash
# sync-forks_test.sh — the App-token mirror sync, against a mock `gh`.
#
# Proves: a fast-forward is READ BACK to the upstream head; a merge-type sync is accepted
# when the upstream is an ancestor; a conflict is REPORTED and fails the run (never forced);
# and the allow-list selects a subset.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

gh() {
  [[ "$1" == api ]] || return 90
  shift
  local method=GET path="" jqexpr=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --method) method="$2"; shift 2 ;;
      --jq) jqexpr="$2"; shift 2 ;;
      --paginate|--include) shift ;;
      --) shift ;;
      -f) shift 2 ;;
      --*) shift ;;
      *) [[ -z "$path" ]] && path="$1"; shift ;;
    esac
  done
  case "$path" in
    orgs/fixture/repos?per_page=*)
      printf 'fork-a\tfalse\ttrue\tstable\nfork-b\tfalse\ttrue\tmain\nfork-c\tfalse\ttrue\tmain\n'; return 0 ;;
    orgs/fixture) printf '3\n'; return 0 ;;
    repos/fixture/fork-a|repos/fixture/fork-b|repos/fixture/fork-c)
      printf 'upstream/%s\n' "${path##*/}"; return 0 ;;
    repos/upstream/*/branches/*)
      local r="${path#repos/upstream/}"; r="${r%%/*}"
      printf 'u-%s\n' "$r"; return 0 ;;
    repos/fixture/fork-c/merge-upstream)
      echo "HTTP 409: Merge conflict" >&2; return 1 ;;
    repos/fixture/fork-a/merge-upstream)
      printf '{"merge_type":"fast-forward"}\n'; return 0 ;;
    repos/fixture/fork-b/merge-upstream)
      printf '{"merge_type":"merge"}\n'; return 0 ;;
    repos/fixture/fork-a/branches/*)
      printf 'u-fork-a\n'; return 0 ;;
    repos/fixture/fork-b/branches/*)
      printf 'm-fork-b\n'; return 0 ;;
    repos/fixture/fork-b/compare/*)
      printf 'ahead\n'; return 0 ;;
  esac
  echo "mock gh: unhandled: $path" >&2; return 97
}
export -f gh
export STATE

run() { SYNC_REPOS="${1:-}" OPENCHARLY_ORG=fixture GH_TOKEN=mock \
  bash "$root/scripts/sync-forks.sh"; }

# 1. the whole set: two sync, one conflicts -> exit 1, both success lines present.
if run "" >"$STATE/out" 2>"$STATE/err"; then
  fail "a conflicted fork must fail the run"
fi
grep -q 'fork-a: synced stable (fast-forward' "$STATE/out" || { cat "$STATE/out" >&2; fail "fork-a must fast-forward on stable"; }
grep -q 'fork-b: synced main (merge' "$STATE/out" || { cat "$STATE/out" >&2; fail "fork-b must accept a merge-type sync"; }
grep -q 'fork-c: NOT synced on main' "$STATE/err" || { cat "$STATE/err" >&2; fail "the conflict must be REPORTED, not forced"; }
grep -q 'sync-forks: synced=2 failed=1' "$STATE/out" || { cat "$STATE/out" >&2; fail "the summary must count both outcomes"; }

# 2. the allow-list selects one fork.
run 'fork-a' >"$STATE/out2" 2>"$STATE/err2" || { cat "$STATE/err2" >&2; fail "the fork-a allow-list must succeed"; }
grep -q 'fork-b' "$STATE/out2" && { cat "$STATE/out2" >&2; fail "the allow-list must exclude fork-b"; }
grep -q 'sync-forks: synced=1 failed=0' "$STATE/out2" || { cat "$STATE/out2" >&2; fail "the allow-list must sync exactly one"; }

echo "PASS: sync-forks — fast-forward read-back, merge accepted, conflict reported, allow-list"
