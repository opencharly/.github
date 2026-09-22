#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT

# alpha carries a dispatcher (must be deleted), beta does not (must be skipped).
printf 'present\n' >"$STATE/disp_alpha"
: >"$STATE/transcript"

gh() {
  if [[ "$1 $2" == "repo list" ]]; then printf 'alpha\nbeta\n'; return; fi
  [[ "$1" == api ]] || return 90
  shift
  local method=GET include=0
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --method) method="$2"; shift 2 ;;
      --include) include=1; shift ;;
      --jq) shift 2 ;;
      *) shift ;;
    esac
  done
  local path="$1"; shift

  [[ "$path" =~ ^repos/test/(alpha|beta)/contents/ ]] || return 91
  local repo="${BASH_REMATCH[1]}"
  local present=0
  [[ "$(cat "$STATE/disp_$repo" 2>/dev/null)" == present ]] && present=1

  if [[ "$method" == DELETE ]]; then
    # a real delete failure (e.g. transient 5xx) must count as a failure
    if [[ "${FORCE_DELETE_FAIL:-}" == 1 ]]; then
      printf 'HTTP/2.0 500 X\r\n\r\n'; return 1
    fi
    rm -f "$STATE/disp_$repo"
    printf 'deleted %s\n' "$repo" >>"$STATE/transcript"
    printf 'commit\n'; return 0
  fi

  # GET (existence / blob sha)
  if [[ "${FORCE_API_FAIL:-}" == 1 ]]; then
    [[ $include == 1 ]] && printf 'HTTP/2.0 500 X\r\n\r\n'
    return 1
  fi
  if [[ $present == 1 ]]; then
    [[ $include == 1 ]] && printf 'HTTP/2.0 200 OK\r\n\r\n'
    printf 'sha\n'; return 0
  fi
  [[ $include == 1 ]] && printf 'HTTP/2.0 404 Not Found\r\n\r\n'
  return 1
}
export -f gh
export STATE

# happy path: alpha deleted, beta skipped.
GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/retire-per-repo-dispatchers.sh" >/dev/null
grep -qx 'deleted alpha' "$STATE/transcript" || { echo "FAIL: alpha dispatcher not deleted" >&2; exit 1; }
grep -q 'deleted beta' "$STATE/transcript" && { echo "FAIL: beta had no dispatcher — must be skipped" >&2; exit 1; }

# idempotent: a second run deletes nothing (alpha now absent).
: >"$STATE/transcript"
GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/retire-per-repo-dispatchers.sh" >/dev/null
[[ -s "$STATE/transcript" ]] && { echo "FAIL: second run must be a no-op" >&2; exit 1; }

# a real API error must ABORT, never read as "absent".
if FORCE_API_FAIL=1 GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/retire-per-repo-dispatchers.sh" >/dev/null 2>&1; then
  echo "FAIL: must abort on a non-404 probe failure" >&2; exit 1
fi

# a delete failure must fail the run.
printf 'present\n' >"$STATE/disp_alpha"
if FORCE_DELETE_FAIL=1 GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/retire-per-repo-dispatchers.sh" >/dev/null 2>&1; then
  echo "FAIL: must fail when a delete fails" >&2; exit 1
fi

echo "retire-per-repo-dispatchers_test: all assertions passed"
