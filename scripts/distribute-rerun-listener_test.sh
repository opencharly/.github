#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT

want_b64="$(base64 -w0 < "$root/org-wide-rerun-listener.yml")"
export want_b64 root
: > "$STATE/transcript"

# Mock `gh api`. Two call shapes matter:
#   - api_status: `gh api --include <path>`  -> prints "HTTP/... <code> ..." then body on 200.
#   - content read: `gh api <path>`          -> prints the JSON body.
#   - PUT: `gh api --method PUT <path> -f ... -f content=...` -> records content, prints sha.
# Repos: alpha absent (404) -> CREATED; beta identical -> SKIPPED; gamma differs -> UPDATED;
# delta PUT 403 -> ABORT; echo_probe 500 on the probe -> ABORT (non-404 probe failure).
gh() {
  if [[ "$1 $2" == "repo list" ]]; then printf 'alpha\nbeta\ngamma\ndelta\nomega\n'; return; fi
  [[ "$1" == api ]] || return 90
  shift
  local method=GET content="" path="" include=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --method) method="$2"; shift 2 ;;
      --include) include=1; shift ;;
      --jq) shift 2 ;;
      -f) case "$2" in content=*) content="${2#content=}";; esac; shift 2 ;;
      repos/*) path="$1"; shift ;;
      *) shift ;;
    esac
  done
  [[ "$path" =~ ^repos/test/(alpha|beta|gamma|delta|omega)/contents/\.github/workflows/rerun-listener\.yml$ ]] || return 91
  local repo="${BASH_REMATCH[1]}"

  if [[ "$method" == PUT ]]; then
    [[ "$repo" == delta && "${FORCE_PERM_FAIL:-}" == 1 ]] && { printf 'gh: Resource not accessible by integration (HTTP 403)\n' >&2; return 1; }
    printf '%s' "$content" > "$STATE/written_$repo"
    printf 'written %s\n' "$repo" >> "$STATE/transcript"
    printf 'commit-%s\n' "$repo"; return 0
  fi

  # omega: the probe returns 500 (a non-404 failure) -> must ABORT via api_status.
  if [[ "$repo" == omega && "${FORCE_PROBE_FAIL:-}" == 1 ]]; then
    [[ $include == 1 ]] && printf 'HTTP/2.0 500 Server Error\r\n\r\n'
    printf 'gh: Server Error (HTTP 500)\n' >&2; return 1
  fi

  case "$repo" in
    alpha) [[ $include == 1 ]] && printf 'HTTP/2.0 404 Not Found\r\n\r\n'; return 1 ;;
    beta)  [[ $include == 1 ]] && printf 'HTTP/2.0 200 OK\r\n\r\n'; printf '{"sha":"bsha","content":"%s"}\n' "$want_b64"; return 0 ;;
    gamma) [[ $include == 1 ]] && printf 'HTTP/2.0 200 OK\r\n\r\n'; printf '{"sha":"gsha","content":"%s"}\n' "T0RMRVIK"; return 0 ;;
    delta) [[ $include == 1 ]] && printf 'HTTP/2.0 200 OK\r\n\r\n'; printf '{"sha":"dsha","content":"%s"}\n' "T0RMRVIK"; return 0 ;;
    omega) [[ $include == 1 ]] && printf 'HTTP/2.0 200 OK\r\n\r\n'; printf '{"sha":"osha","content":"%s"}\n' "$want_b64"; return 0 ;;
  esac
  return 1
}
export -f gh
export STATE

# 1. Happy path: create alpha, skip beta, update gamma + delta.
out="$(GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/distribute-rerun-listener.sh" 2>&1)"
[[ -f "$STATE/written_alpha" ]] || { echo "FAIL: alpha must be CREATED" >&2; exit 1; }
[[ -f "$STATE/written_gamma" ]] || { echo "FAIL: gamma (differing) must be UPDATED" >&2; exit 1; }
[[ -f "$STATE/written_beta"  ]] && { echo "FAIL: beta (identical) must be SKIPPED, no churn" >&2; exit 1; }
grep -q "created=1 updated=2 unchanged=2 failed=0" <<<"$out" \
  || { echo "FAIL: counters wrong (got: $out)" >&2; exit 1; }
[[ "$(cat "$STATE/written_alpha")" == "$want_b64" ]] \
  || { echo "FAIL: installed content must equal the template verbatim" >&2; exit 1; }

# 2. A 403 on a workflow-file write must ABORT with the remediation (delta).
out="$(FORCE_PERM_FAIL=1 GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/distribute-rerun-listener.sh" 2>&1)" && {
  echo "FAIL: must abort on a 403 workflow-file write" >&2; exit 1; }
grep -q "workflows: write" <<<"$out" || { echo "FAIL: 403 abort must name the missing permission" >&2; exit 1; }

# 3. A non-404 probe failure (500) must ABORT — never be read as "absent" (omega).
out="$(FORCE_PROBE_FAIL=1 GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/distribute-rerun-listener.sh" 2>&1)" && {
  echo "FAIL: must abort on a non-404 probe failure" >&2; exit 1; }
grep -q "HTTP 500" <<<"$out" || { echo "FAIL: non-404 probe abort must name the HTTP code (got: $out)" >&2; exit 1; }

echo "distribute-rerun-listener_test: all assertions passed"
