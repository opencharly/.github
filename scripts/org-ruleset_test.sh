#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT

# Mock state: two target repos. `alpha` carries the per-repo ruleset + dispatcher;
# `beta` is clean. `allow_auto_merge` is false on beta (the regression the script
# must fix) and true on alpha. `api_broken` forces a non-404 API failure on the
# dispatcher probe, so the script must ABORT rather than read it as "absent".
printf 'true\n'  >"$STATE/auto_alpha"
printf 'false\n' >"$STATE/auto_beta"
printf 'present\n' >"$STATE/ruleset_alpha"
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
      --input) shift ;;
      *) shift ;;
    esac
  done
  [[ -n "${1:-}" ]] || return 90
  local path="$1"; shift
  local query=""; [[ "${1:-}" == *\?* ]] && query="$1"

  emit() { # emit <status> <body>
    [[ $include == 1 ]] && printf 'HTTP/2.0 %s X\r\n\r\n' "$1"
    printf '%s' "$2"
    [[ "$1" == 404 ]] && return 1 || true
  }

  [[ "$path" == "apps/charly-auto-merge" ]] && { printf '123\n'; return; }
  [[ "$path" == "repos/test/.github" ]] && { printf '777\n'; return; }
  if [[ "$path" == "repos/test/.github/contents/.github/workflows/org-wide-pr-validator-required.yml"* ]]; then
    printf 'wfsha\n'; return
  fi
  if [[ "$path" == "orgs/test/rulesets" ]]; then
    if [[ "$method" == POST ]]; then printf '55\n' >"$STATE/org_ruleset_id"; printf '55\n'; return; fi
    cat "$STATE/org_ruleset_id" 2>/dev/null || true; return
  fi
  if [[ "$path" == "orgs/test/rulesets/"* ]]; then
    [[ "$method" == DELETE ]] && { rm -f "$STATE/org_ruleset_id"; return; }
    [[ "$method" == PUT ]] && { printf '55\n'; return; }
    cat <<JSON
{"id":55,"enforcement":"active","rules":[{"type":"workflows","parameters":{"workflows":[{"path":".github/workflows/org-wide-pr-validator-required.yml"}]}},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"validate / validate"}]}},{"type":"non_fast_forward"},{"type":"deletion"},{"type":"creation"}],"bypass_actors":[{"actor_id":123,"actor_type":"Integration"}]}
JSON
    return
  fi

  local repo=""
  [[ "$path" =~ ^repos/test/(alpha|beta)(/|$) ]] && repo="${BASH_REMATCH[1]}"

  if [[ -n "$repo" ]]; then
    if [[ "$path" == "repos/test/$repo" && "$method" == GET ]]; then cat "$STATE/auto_$repo"; return; fi
    if [[ "$path" == "repos/test/$repo" && "$method" == PATCH ]]; then
      printf 'true\n' >"$STATE/auto_$repo"; printf 'PATCH %s auto\n' "$repo" >>"$STATE/transcript"; printf 'true\n'; return
    fi
    if [[ "$path" == "repos/test/$repo/rulesets" && "$method" == GET ]]; then
      if [[ "$(cat "$STATE/ruleset_$repo" 2>/dev/null)" == present ]]; then printf '99\n'; fi
      return 0
    fi
    if [[ "$path" == "repos/test/$repo/rulesets/99" && "$method" == DELETE ]]; then
      rm -f "$STATE/ruleset_$repo"; printf 'deleted %s ruleset\n' "$repo" >>"$STATE/transcript"; return
    fi
    if [[ "$path" == "repos/test/$repo/contents/.github/workflows/pr-validator.yml"* ]]; then
      if [[ "$repo" == alpha && "${FORCE_API_FAIL:-}" == 1 ]]; then emit 500 '{}'; return; fi
      if [[ "$(cat "$STATE/disp_$repo" 2>/dev/null)" == present ]]; then emit 200 '{"sha":"sha"}'; return; fi
      emit 404 '{}'; return
    fi
  fi
  return 91
}
export -f gh
export STATE

# apply: creates the org ruleset, deletes alpha's legacy ruleset, and flips beta's
# allow_auto_merge on. It does NOT retire dispatchers (that needs the app-token
# workflow) — verify therefore fails while alpha's dispatcher remains.
OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" apply >/dev/null
grep -q 'deleted alpha ruleset' "$STATE/transcript" || { echo "FAIL: alpha ruleset not deleted" >&2; exit 1; }
grep -q 'PATCH beta auto'       "$STATE/transcript" || { echo "FAIL: beta auto-merge not enabled" >&2; exit 1; }
[[ "$(cat "$STATE/auto_beta")" == true ]] || { echo "FAIL: beta auto-merge state not true" >&2; exit 1; }
grep -q 'PATCH alpha' "$STATE/transcript" && { echo "FAIL: alpha auto-merge must not be re-patched" >&2; exit 1; }

# verify must fail while a dispatcher survives (it would be a duplicate producer).
if OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" verify >/dev/null 2>&1; then
  echo "FAIL: verify must fail while a per-repo dispatcher survives" >&2; exit 1
fi

# Simulate retire-per-repo-dispatchers.yml deleting the stub, then verify passes.
rm -f "$STATE/disp_alpha"
OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" verify >/dev/null

# A real API failure on the dispatcher probe must ABORT verify (never read as
# "absent" — that would hide a surviving duplicate producer).
if FORCE_API_FAIL=1 OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" verify >/dev/null 2>&1; then
  echo "FAIL: verify must abort on a non-404 dispatcher-probe failure" >&2; exit 1
fi

# A regression — a per-repo ruleset reappears — must fail verify.
printf 'present\n' >"$STATE/ruleset_beta"
if OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" verify >/dev/null 2>&1; then
  echo "FAIL: verify must fail when a per-repo ruleset reappears" >&2; exit 1
fi

echo "org-ruleset_test: all assertions passed (apply/verify/abort)"
