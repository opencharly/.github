#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
: > "$STATE/transcript"

# Mock gh. Search returns three labeled PRs:
#   acme/one   -> a FAILED validator run on its head -> RERUN + label removed
#   acme/two   -> no failed run                       -> label removed, no rerun
#   acme/three -> head lookup fails (500)             -> counted failed
# Calls arrive as: `gh search prs ...`, `gh api <path>`, `gh api -X POST <path>`,
# `gh run list ...`, `gh pr edit ...`.
gh() {
  local a="$1" b="${2:-}"
  case "$a $b" in
    "search prs") printf 'acme/one 11\nacme/two 22\nacme/three 33\n'; return 0 ;;
    "run list")
      if [[ "$*" == *"acme/one"* ]]; then
        # Honor the --jq pipeline the script relies on: emit the run id only.
        printf '901\n'
      fi
      return 0 ;;
    "pr edit") printf '%s\n' "label-removed $*" >>"$STATE/transcript"; return 0 ;;
    "api "*)
      # Normalize: skip `-X POST` if present.
      local method=GET path=""
      shift
      if [[ "${1:-}" == "-X" ]]; then method="$2"; shift 2; fi
      [[ "${1:-}" == "--jq" ]] && shift 2
      path="${1:-}"
      case "$method $path" in
        "GET repos/acme/one/pulls/11")   printf 'aaa111\n'; return 0 ;;
        "GET repos/acme/two/pulls/22")   printf 'bbb222\n'; return 0 ;;
        "GET repos/acme/three/pulls/33") printf 'gh: Server Error (HTTP 500)\n' >&2; return 1 ;;
        "POST repos/acme/one/actions/runs/901/rerun") printf '{}\n' >>"$STATE/transcript"; return 0 ;;
      esac
      return 1 ;;
  esac
  return 1
}
export -f gh
export STATE

rc=0
out="$(GH_TOKEN=x OPENCHARLY_ORG=acme "$root/scripts/sweep-rerun.sh" 2>&1)" || rc=$?
echo "$out"

grep -q "re-ran validator run 901" <<<"$out" || { echo "FAIL: acme/one must be rerun (got: $out)" >&2; exit 1; }
grep -q "reran=1" <<<"$out" || { echo "FAIL: expected reran=1 (got: $out)" >&2; exit 1; }
grep -q "failed=1" <<<"$out" || { echo "FAIL: expected failed=1 for acme/three (got: $out)" >&2; exit 1; }
[[ "$rc" != 0 ]] || { echo "FAIL: a failed row must fail the run" >&2; exit 1; }
[[ "$(grep -c 'rerun\|label-removed' "$STATE/transcript")" -ge 1 ]] \
  || { echo "FAIL: the label must be removed after the rerun" >&2; exit 1; }

# Idempotent: no labeled PRs -> clean, reran=0.
gh() { if [[ "$1 $2" == "search prs" ]]; then return 0; fi; return 1; }
export -f gh
out="$(GH_TOKEN=x OPENCHARLY_ORG=acme "$root/scripts/sweep-rerun.sh" 2>&1)"
grep -q "no open 'rerun'-labeled PRs" <<<"$out" || { echo "FAIL: empty search must report no PRs (got: $out)" >&2; exit 1; }

echo "sweep-rerun_test: all assertions passed"
