#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT

# Mock state: two target repos. `alpha` carries the per-repo ruleset + dispatcher;
# `beta` is clean. `allow_auto_merge` and `delete_branch_on_merge` are false on beta
# (the regressions the script must fix) and true on alpha. `alpha` also carries
# legacy branch protection (the script must remove it; verify must assert its
# absence).
printf 'true\n'  >"$STATE/auto_alpha"
printf 'false\n' >"$STATE/auto_beta"
printf 'true\n'  >"$STATE/dbom_alpha"
printf 'false\n' >"$STATE/dbom_beta"
printf 'present\n' >"$STATE/ruleset_alpha"
printf 'present\n' >"$STATE/disp_alpha"
printf 'present\n' >"$STATE/legacy_alpha"
: >"$STATE/transcript"

gh() {
  if [[ "$1 $2" == "repo list" ]]; then
    # Target discovery is the `main`-default filter; exclude discovery is the `!=`
    # filter. FORCE_TARGETS_FAIL / FORCE_EXCLUDES_FAIL fail the respective read so the
    # call-site abort on each is exercised independently.
    local jqfilter="${*: -1}"
    if [[ "$jqfilter" == *"!="* ]]; then
      [[ "${FORCE_EXCLUDES_FAIL:-}" == 1 ]] && return 1
      # EXCLUDE_LIST lets a case exercise exclude_json with real content.
      printf '%s\n' "${EXCLUDE_LIST:-}"
      return 0
    fi
    [[ "${FORCE_TARGETS_FAIL:-}" == 1 ]] && return 1
    printf 'alpha\nbeta\n'; return
  fi
  [[ "$1" == api ]] || return 90
  shift
  local raw="$*"
  local method=GET include=0 input="" path="" jqexpr=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --method) method="$2"; shift 2 ;;
      --include) include=1; shift ;;
      --input) input="$2"; shift 2 ;;
      --jq) jqexpr="$2"; shift 2 ;;
      --) shift ;;
      --*) shift ;;
      *) [[ -z "$path" ]] && path="$1"; shift ;;
    esac
  done
  [[ -n "$path" ]] || return 90

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
    if [[ "$method" == POST ]]; then
      # Capture the payload so the test can assert the exclude set renders as []
      # (not [""]) when there are no forks/archived repos.
      [[ -n "$input" ]] && cat "$input" >"$STATE/payload.json"
      printf '55\n' >"$STATE/org_ruleset_id"; printf '55\n'; return
    fi
    cat "$STATE/org_ruleset_id" 2>/dev/null || true; return
  fi
    if [[ "$path" == "orgs/test/rulesets/"* ]]; then
      [[ "$method" == DELETE ]] && { rm -f "$STATE/org_ruleset_id"; return; }
      [[ "$method" == PUT ]] && { printf '55\n'; return; }
      if [[ -f "$STATE/scope_mismatch" ]]; then
        # A drifted scope (wrong exclude) — verify must detect it.
        cat <<JSON
{"id":55,"enforcement":"active","conditions":{"repository_name":{"include":["~ALL"],"exclude":["some-other-repo"],"protected":false},"ref_name":{"include":["refs/heads/main"],"exclude":[]}},"rules":[{"type":"workflows","parameters":{"workflows":[{"path":".github/workflows/org-wide-pr-validator-required.yml"}]}},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"validate / validate"}]}},{"type":"non_fast_forward"},{"type":"deletion"},{"type":"creation"}],"bypass_actors":[{"actor_id":123,"actor_type":"Integration"}]}
JSON
        return
      fi
      cat <<JSON
{"id":55,"enforcement":"active","conditions":{"repository_name":{"include":["~ALL"],"exclude":[],"protected":false},"ref_name":{"include":["refs/heads/main"],"exclude":[]}},"rules":[{"type":"workflows","parameters":{"workflows":[{"path":".github/workflows/org-wide-pr-validator-required.yml"}]}},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"validate / validate"}]}},{"type":"non_fast_forward"},{"type":"deletion"},{"type":"creation"}],"bypass_actors":[{"actor_id":123,"actor_type":"Integration"}]}
JSON
      return
    fi

  local repo=""
  [[ "$path" =~ ^repos/test/(alpha|beta)(/|$) ]] && repo="${BASH_REMATCH[1]}"

  if [[ -n "$repo" ]]; then
    if [[ "$path" == "repos/test/$repo" && "$method" == GET ]]; then
      # The two per-repo settings are read by their own `--jq`. Return the setting the
      # caller asked for (default = allow_auto_merge) so a single mock endpoint serves
      # both probes.
      if [[ "$jqexpr" == *delete_branch_on_merge* ]]; then cat "$STATE/dbom_$repo"; else cat "$STATE/auto_$repo"; fi
      return
    fi
    if [[ "$path" == "repos/test/$repo" && "$method" == PATCH ]]; then
      if [[ "$raw" == *delete_branch_on_merge* ]]; then
        printf 'true\n' >"$STATE/dbom_$repo"; printf 'PATCH %s dbom\n' "$repo" >>"$STATE/transcript"; printf 'true\n'
      else
        printf 'true\n' >"$STATE/auto_$repo"; printf 'PATCH %s auto\n' "$repo" >>"$STATE/transcript"; printf 'true\n'
      fi
      return
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
    if [[ "$path" == "repos/test/$repo/branches/main/protection" ]]; then
      if [[ "$method" == DELETE ]]; then
        rm -f "$STATE/legacy_$repo"; printf 'deleted %s legacy\n' "$repo" >>"$STATE/transcript"; return 0
      fi
      if [[ "$repo" == alpha && "${FORCE_LEGACY_API_FAIL:-}" == 1 ]]; then emit 500 '{}'; return; fi
      if [[ "$(cat "$STATE/legacy_$repo" 2>/dev/null)" == present ]]; then emit 200 '{}'; return; fi
      emit 404 '{}'; return
    fi
  fi
  return 91
}
export -f gh
export STATE

# apply REFUSES while alpha's dispatcher survives (it would be a duplicate producer).
if OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" apply >/dev/null 2>&1; then
  echo "FAIL: apply must refuse while a per-repo dispatcher survives" >&2; exit 1
fi

# Simulate retire-per-repo-dispatchers.yml deleting the stub, then apply succeeds.
rm -f "$STATE/disp_alpha"
OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" apply >/dev/null
grep -q 'deleted alpha ruleset' "$STATE/transcript" || { echo "FAIL: alpha ruleset not deleted" >&2; exit 1; }
grep -q 'deleted alpha legacy'  "$STATE/transcript" || { echo "FAIL: alpha legacy protection not removed" >&2; exit 1; }
grep -q 'PATCH beta auto'       "$STATE/transcript" || { echo "FAIL: beta auto-merge not enabled" >&2; exit 1; }
[[ "$(cat "$STATE/auto_beta")" == true ]] || { echo "FAIL: beta auto-merge state not true" >&2; exit 1; }
grep -q 'PATCH beta dbom'       "$STATE/transcript" || { echo "FAIL: beta delete-branch-on-merge not enabled" >&2; exit 1; }
[[ "$(cat "$STATE/dbom_beta")" == true ]] || { echo "FAIL: beta delete-branch-on-merge state not true" >&2; exit 1; }
grep -q 'PATCH alpha' "$STATE/transcript" && { echo "FAIL: alpha auto-merge must not be re-patched" >&2; exit 1; }

# The posted payload must render the `repository_name.exclude` set as `[]`, not
# `[""]` (the mapfile-on-empty bug). A plain `grep '"exclude": []'` is INSUFFICIENT —
# the hardcoded `ref_name` line also contains `"exclude": []`, so it would pass even
# when repository_name.exclude were `[""]`. Assert the SPECIFIC field via jq.
jq -e '.conditions.repository_name.exclude == []' "$STATE/payload.json" >/dev/null \
  || { echo "FAIL: empty exclude set must render repository_name.exclude == [] (got: $(jq -c '.conditions.repository_name.exclude' "$STATE/payload.json"))" >&2; exit 1; }
jq -e '.conditions.repository_name.include == ["~ALL"]' "$STATE/payload.json" >/dev/null \
  || { echo "FAIL: ruleset must include ~ALL" >&2; exit 1; }

# verify passes on the fully-migrated state.
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
rm -f "$STATE/ruleset_beta"

# A regression — legacy branch protection reappears — must fail verify.
printf 'present\n' >"$STATE/legacy_beta"
if OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" verify >/dev/null 2>&1; then
  echo "FAIL: verify must fail when legacy branch protection reappears" >&2; exit 1
fi
rm -f "$STATE/legacy_beta"

# A regression — delete_branch_on_merge drifts false — must fail verify.
printf 'false\n' >"$STATE/dbom_beta"
if OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" verify >/dev/null 2>&1; then
  echo "FAIL: verify must fail when delete_branch_on_merge is not true" >&2; exit 1
fi
printf 'true\n' >"$STATE/dbom_beta"

# A scope regression — the ruleset's exclude set drifts — must fail verify.
printf 'true\n' >"$STATE/scope_mismatch"
if OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" verify >/dev/null 2>&1; then
  echo "FAIL: verify must fail when the ruleset's target scope drifts" >&2; exit 1
fi
rm -f "$STATE/scope_mismatch"

# A failed EXCLUDES read must ABORT (an empty exclude set would apply the ruleset to
# forks/archived repos too). This is the path the targets count-guard cannot catch.
if FORCE_EXCLUDES_FAIL=1 OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" apply >/dev/null 2>&1; then
  echo "FAIL: apply must abort when the excludes read fails" >&2; exit 1
fi

# A non-404 legacy-protection probe failure must ABORT (a transient error must never
# read as "absent" and silently skip the removal).
printf 'present\n' >"$STATE/legacy_alpha"
if FORCE_LEGACY_API_FAIL=1 OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" apply >/dev/null 2>&1; then
  echo "FAIL: apply must abort on a non-404 legacy-protection probe failure" >&2; exit 1
fi

# A failed TARGETS read must ABORT too (the other discovery call site).
if FORCE_TARGETS_FAIL=1 OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" apply >/dev/null 2>&1; then
  echo "FAIL: apply must abort when the targets read fails" >&2; exit 1
fi

# exclude_json with REAL content: a non-empty exclude set must round-trip verbatim.
rm -f "$STATE/legacy_alpha"; rm -f "$STATE/disp_alpha"; rm -f "$STATE/org_ruleset_id"
EXCLUDE_LIST=$'fork-a\narchived-b' OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" apply >/dev/null
jq -e '.conditions.repository_name.exclude == ["archived-b","fork-a"]' "$STATE/payload.json" >/dev/null \
  || { echo "FAIL: non-empty exclude set must round-trip (got: $(jq -c '.conditions.repository_name.exclude' "$STATE/payload.json"))" >&2; exit 1; }

echo "org-ruleset_test: all assertions passed (apply/verify/abort)"
