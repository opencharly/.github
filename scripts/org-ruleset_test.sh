#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT

# Mock state: two target repos. `alpha` carries the per-repo ruleset + dispatcher;
# `beta` is clean. `allow_auto_merge` is false on beta (the regression the script
# must fix) and true on alpha.
printf 'true\n'  >"$STATE/auto_alpha"
printf 'false\n' >"$STATE/auto_beta"
printf 'present\n' >"$STATE/ruleset_alpha"   # alpha has the legacy per-repo ruleset
printf 'present\n' >"$STATE/disp_alpha"      # alpha has the legacy dispatcher
: >"$STATE/transcript"

gh() {
  if [[ "$1 $2" == "repo list" ]]; then
    printf 'alpha\nbeta\n'
    return
  fi
  [[ "$1" == api ]] || return 90
  shift
  local method=GET
  if [[ "${1:-}" == --method ]]; then method="$2"; shift 2; fi
  [[ -n "${1:-}" ]] || return 90
  local path="$1"; shift

  if [[ "$path" == "apps/charly-auto-merge" ]]; then printf '123\n'; return; fi
  if [[ "$path" == "repos/test/.github" ]]; then printf '777\n'; return; fi
  if [[ "$path" == "repos/test/.github/contents/.github/workflows/org-wide-pr-validator-required.yml"* ]]; then
    printf 'wfsha\n'; return
  fi
  if [[ "$path" == "orgs/test/rulesets" ]]; then
    if [[ "$method" == POST ]]; then printf '55\n' >"$STATE/org_ruleset_id"; printf '55\n'; return; fi
    cat "$STATE/org_ruleset_id" 2>/dev/null || true; return
  fi
  if [[ "$path" == "orgs/test/rulesets/"* ]]; then
    if [[ "$method" == DELETE ]]; then rm -f "$STATE/org_ruleset_id"; return; fi
    if [[ "$method" == PUT ]]; then printf '55\n'; return; fi
    # detail read for verify
    cat <<JSON
{"id":55,"enforcement":"active","rules":[{"type":"workflows","parameters":{"workflows":[{"path":".github/workflows/org-wide-pr-validator-required.yml"}]}},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"validate / validate"}]}},{"type":"non_fast_forward"},{"type":"deletion"},{"type":"creation"}],"bypass_actors":[{"actor_id":123,"actor_type":"Integration"},{"actor_id":null,"actor_type":"OrganizationAdmin"}]}
JSON
    return
  fi

  local repo=""
  [[ "$path" =~ ^repos/test/(alpha|beta)(/|$|\?) ]] && repo="${BASH_REMATCH[1]}"
  [[ -n "$repo" ]] || { [[ "$path" == repos/test/.*contents/* ]] || return 91; }

  if [[ "$path" == "repos/test/$repo" && "$method" == GET ]]; then cat "$STATE/auto_$repo"; return; fi
  if [[ "$path" == "repos/test/$repo" && "$method" == PATCH ]]; then
    printf 'true\n' >"$STATE/auto_$repo"; printf 'PATCH %s auto\n' "$repo" >>"$STATE/transcript"; printf 'true\n'; return
  fi
  if [[ "$path" == "repos/test/$repo/rulesets" && "$method" == GET ]]; then
    [[ "$(cat "$STATE/ruleset_$repo" 2>/dev/null)" == present ]] && printf '99\n'; return
  fi
  if [[ "$path" == "repos/test/$repo/rulesets/99" && "$method" == DELETE ]]; then
    rm -f "$STATE/ruleset_$repo"; printf 'deleted %s ruleset\n' "$repo" >>"$STATE/transcript"; return
  fi
  if [[ "$path" == "repos/test/$repo/contents/.github/workflows/pr-validator.yml"* ]]; then
    if [[ "$method" == DELETE ]]; then
      rm -f "$STATE/disp_$repo"; printf 'deleted %s dispatcher\n' "$repo" >>"$STATE/transcript"; printf 'commit\n'; return
    fi
    [[ "$(cat "$STATE/disp_$repo" 2>/dev/null)" == present ]] && printf 'sha\n'; return
  fi
  return 91
}
export -f gh
export STATE

# apply: creates the org ruleset, deletes alpha's legacy ruleset + dispatcher, and
# flips beta's allow_auto_merge on.
OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" apply >/dev/null
grep -q 'deleted alpha ruleset'   "$STATE/transcript" || { echo "FAIL: alpha ruleset not deleted" >&2; exit 1; }
grep -q 'deleted alpha dispatcher' "$STATE/transcript" || { echo "FAIL: alpha dispatcher not deleted" >&2; exit 1; }
grep -q 'PATCH beta auto'          "$STATE/transcript" || { echo "FAIL: beta auto-merge not enabled" >&2; exit 1; }
[[ "$(cat "$STATE/auto_beta")" == true ]] || { echo "FAIL: beta auto-merge state not true" >&2; exit 1; }
grep -q 'PATCH alpha' "$STATE/transcript" && { echo "FAIL: alpha auto-merge must not be re-patched" >&2; exit 1; }

# verify: passes on the fully-migrated state.
OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" verify >/dev/null

# A regression — a per-repo ruleset reappears — must fail verify.
printf 'present\n' >"$STATE/ruleset_beta"
if OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" verify >/dev/null 2>&1; then
  echo "FAIL: verify must fail when a per-repo ruleset reappears" >&2; exit 1
fi

echo "org-ruleset_test: all assertions passed (apply/verify)"
