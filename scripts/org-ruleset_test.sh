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
  [[ "$1" == api ]] || return 90
  shift
  local raw="$*"

  # DISCOVERY (opencharly/.github#290). Each filter issues its OWN paged REST read, so
  # the mock answers every call and the counter below can fail the SECOND one. The
  # fixture is synthesised from the knobs the cases already use:
  #   alpha, beta            two clean targets (`main`, neither fork nor archived)
  #   MEMBERSHIP_LIST        `<name>\t<default>` rows, active and non-fork
  #   EXCLUDE_LIST           names served as ARCHIVED rows (real exclude content)
  #   DISCOVERY_TRUNCATE=1   the listing omits a row while the org still counts it — the
  #                          silent-understatement control this change adds
  #   FORCE_DISCOVERY_FAIL=1 the listing itself fails
  if [[ "$raw" == *"/repos?per_page="* ]]; then
    [[ "${FORCE_DISCOVERY_FAIL:-}" == 1 ]] && return 1
    # Each filter issues its OWN read (lib-org.sh does not memoise), so a failure can
    # land on the SECOND one after the first succeeded. FORCE_SECOND_DISCOVERY_FAIL
    # exercises exactly that: the targets read passes and the excludes read does not,
    # which is the only way to reach org-ruleset.sh's excludes abort.
    local calls=0
    [[ -f "$STATE/discovery_calls" ]] && calls="$(cat "$STATE/discovery_calls")"
    calls=$((calls + 1))
    printf '%s\n' "$calls" >"$STATE/discovery_calls"
    [[ "${FORCE_SECOND_DISCOVERY_FAIL:-}" == 1 && "$calls" -ge 2 ]] && return 1
    local rows
    rows=$'alpha\tfalse\tfalse\tmain\nbeta\tfalse\tfalse\tmain'
    if [[ -n "${MEMBERSHIP_LIST:-}" ]]; then
      rows+=$'\n'"$(printf '%s\n' "$MEMBERSHIP_LIST" | awk -F'\t' 'NF { printf "%s\tfalse\tfalse\t%s\n", $1, $2 }')"
    fi
    if [[ -n "${EXCLUDE_LIST:-}" ]]; then
      rows+=$'\n'"$(printf '%s\n' "$EXCLUDE_LIST" | awk -F'\t' 'NF { printf "%s\ttrue\tfalse\tmain\n", $1 }')"
    fi
    local n; n="$(printf '%s\n' "$rows" | sed '/^$/d' | wc -l)"
    [[ "${DISCOVERY_TRUNCATE:-}" == 1 ]] && n=$((n + 1))
    printf '%s\n' "$n" >"$STATE/orgcount"
    printf '%s\n' "$rows" | sed '/^$/d'
    return 0
  fi
  if [[ "$raw" =~ ^orgs/test([[:space:]]|$) ]]; then
    if [[ -f "$STATE/orgcount" ]]; then cat "$STATE/orgcount"; else printf '0\n'; fi
    return 0
  fi
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
      [[ "$method" == PUT ]] && { [[ -n "$input" ]] && cat "$input" >"$STATE/payload.json"; printf '55\n'; return; }
      if [[ -f "$STATE/scope_mismatch" ]]; then
        # A drifted scope (wrong exclude) — verify must detect it.
        cat <<JSON
{"id":55,"enforcement":"active","conditions":{"repository_name":{"include":["~ALL"],"exclude":["some-other-repo"],"protected":false},"ref_name":{"include":["refs/heads/main"],"exclude":[]}},"rules":[{"type":"workflows","parameters":{"workflows":[{"path":".github/workflows/org-wide-pr-validator-required.yml"}]}},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"validate / validate"}]}},{"type":"non_fast_forward"},{"type":"deletion"},{"type":"creation"}],"bypass_actors":[{"actor_id":123,"actor_type":"Integration"}]}
JSON
        return
      fi
      # The LIVE ruleset mirrors what `apply` posted: discovery now serves the exclude
      # set as well (opencharly/.github#290), so a population with a non-target row
      # legitimately posts a non-empty exclude set and verify must see THAT.
      live_exclude='[]'
      [[ -f "$STATE/payload.json" ]] && live_exclude="$(jq -c '.conditions.repository_name.exclude // []' "$STATE/payload.json" 2>/dev/null || echo '[]')"
      cat <<JSON | jq --argjson e "$live_exclude" '.conditions.repository_name.exclude = $e'
{"id":55,"enforcement":"active","conditions":{"repository_name":{"include":["~ALL"],"exclude":[],"protected":false},"ref_name":{"include":["refs/heads/main"],"exclude":[]}},"rules":[{"type":"workflows","parameters":{"workflows":[{"path":".github/workflows/org-wide-pr-validator-required.yml"}]}},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"validate / validate"}]}},{"type":"non_fast_forward"},{"type":"deletion"},{"type":"creation"}],"bypass_actors":[{"actor_id":123,"actor_type":"Integration"}]}
JSON
      return
    fi

  local repo=""
  [[ "$path" =~ ^repos/test/(alpha|beta|has-main|no-main)(/|$) ]] && repo="${BASH_REMATCH[1]}"

  if [[ -n "$repo" ]]; then
    # The membership arm's remedy branches on whether a `main` ref exists at all (#180):
    # `has-main` has one, `no-main` does not.
    if [[ "$path" == "repos/test/$repo/git/ref/heads/main" ]]; then
      [[ "$repo" == has-main ]] && { printf 'c0ffee\n'; return 0; }
      return 1
    fi
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

# MEMBERSHIP INTEGRITY (opencharly/.github#180). The target set is DEFINED by
# `defaultBranchRef == main`, so an active, non-fork repo that keeps another default is
# silently outside the org gate — no required check, no CalVer tag — and the loop over
# the target set can never notice. verify must fail, name the repo and its default, and
# print the exact remedy.
if MEMBERSHIP_LIST=$'has-main\tseed\nno-main\tfeat/x\n' OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" verify >/dev/null 2>"$STATE/mem.err"; then
  echo "FAIL: verify must fail on an active non-fork repo whose default branch is not main" >&2; exit 1
fi
grep -q "has-main: default branch is 'seed' but a 'main' ref exists" "$STATE/mem.err" \
  || { echo "FAIL: verify must name the repo, its default and the existing main ref" >&2; exit 1; }
grep -q 'PATCH repos/test/has-main -f default_branch=main' "$STATE/mem.err" \
  || { echo "FAIL: verify must print the exact PATCH remedy when a main ref exists" >&2; exit 1; }
grep -q "no-main: default branch is 'feat/x' and there is NO 'main' ref" "$STATE/mem.err" \
  || { echo "FAIL: verify must distinguish a repo that was never bootstrapped" >&2; exit 1; }
grep -q 'run scripts/bootstrap-repo-main.sh' "$STATE/mem.err" \
  || { echo "FAIL: the never-bootstrapped remedy must name the bootstrap script" >&2; exit 1; }

# The two NON-failures, both named rather than silently skipped: a by-design non-main
# default declared in lib-org.sh's declared_non_main_defaults(), and an EMPTY repo (no
# default branch yet — it cannot merge anything until it has one, and the moment it does
# this arm fails).
# apply FIRST with this same population: discovery now serves the exclude set too
# (opencharly/.github#290), so a repo with no default branch is a non-target and belongs
# in the ruleset's exclude set. Under the old two-read mock this case compared a live
# ruleset built from an EMPTY exclude set against a population that has one row more —
# a fixture artefact, not a behaviour. Applying makes the stored ruleset and the
# population consistent, which is the state verify is meant to judge.
MEMBERSHIP_LIST=$'pixelflux\tav1\nfresh\t\n' OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" apply \
  >"$STATE/mem2apply.out" 2>"$STATE/mem2apply.err" \
  || { echo "FAIL: the mem2 fixture setup apply failed: $(cat "$STATE/mem2apply.err")" >&2; exit 1; }
if ! MEMBERSHIP_LIST=$'pixelflux\tav1\nfresh\t\n' OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" verify >"$STATE/mem2.out" 2>"$STATE/mem2.err"; then
  echo "FAIL: a declared by-design default and an empty repo must not fail verify — stderr: $(cat "$STATE/mem2.err")" >&2; exit 1
fi
grep -q 'pixelflux: default branch .av1. — declared by design' "$STATE/mem2.out" \
  || { echo "FAIL: a declared by-design default must be reported as declared" >&2; exit 1; }
grep -q 'fresh: no default branch yet (empty repo)' "$STATE/mem2.out" \
  || { echo "FAIL: an empty repo must be named, not silently skipped" >&2; exit 1; }
[[ -s "$STATE/mem2.err" ]] && { echo "FAIL: an undeclared failure must not appear for a declared/empty population: $(cat "$STATE/mem2.err")" >&2; exit 1; }

# A failed MEMBERSHIP read must ABORT the verify — a failed read can never read as a
# clean membership. It shares lib-org.sh's ONE discovery with the target and exclude
# sets now, so the knob is FORCE_DISCOVERY_FAIL; the arm still fails independently at
# THIS call site (verify), which is what the case asserts.
if FORCE_DISCOVERY_FAIL=1 OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" verify >/dev/null 2>&1; then
  echo "FAIL: verify must refuse a clean membership from a failed read" >&2; exit 1
fi

# A TRUNCATED discovery must ABORT (opencharly/.github#290). The listing returns one
# row fewer than the org's own count — the shape a dropped page takes when it does NOT
# raise: every caller would silently see a smaller org. The count check inside
# discover_all is the control, and this case is the one that fails without it.
if DISCOVERY_TRUNCATE=1 OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" apply >/dev/null 2>&1; then
  echo "FAIL: apply must abort when the discovery is TRUNCATED, not understate the org" >&2; exit 1
fi

# A non-404 legacy-protection probe failure must ABORT (a transient error must never
# read as "absent" and silently skip the removal).
printf 'present\n' >"$STATE/legacy_alpha"
if FORCE_LEGACY_API_FAIL=1 OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" apply >/dev/null 2>&1; then
  echo "FAIL: apply must abort on a non-404 legacy-protection probe failure" >&2; exit 1
fi

# A failed DISCOVERY must ABORT apply at the targets call site.
if FORCE_DISCOVERY_FAIL=1 OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" apply >/dev/null 2>&1; then
  echo "FAIL: apply must abort when the targets read fails" >&2; exit 1
fi

# The EXCLUDES read is its OWN discovery, so it can fail AFTER the targets read
# succeeded — and then `exclude` would be `[]`, applying the ruleset to forks and
# archived repos too. This case fails only the second discovery; without the abort at
# that call site, apply would proceed on a partial picture. (It is a separate case, not
# a variant of the one above: the knob makes the FIRST call pass, so only the excludes
# path is exercised.)
rm -f "$STATE/discovery_calls"
if FORCE_SECOND_DISCOVERY_FAIL=1 OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" apply >/dev/null 2>&1; then
  echo "FAIL: apply must abort when the EXCLUDES read fails after a successful targets read" >&2; exit 1
fi
rm -f "$STATE/discovery_calls"

# exclude_json with REAL content: a non-empty exclude set must round-trip verbatim.
rm -f "$STATE/legacy_alpha"; rm -f "$STATE/disp_alpha"; rm -f "$STATE/org_ruleset_id"
EXCLUDE_LIST=$'fork-a\narchived-b' OPENCHARLY_ORG=test "$root/scripts/org-ruleset.sh" apply >/dev/null
jq -e '.conditions.repository_name.exclude == ["archived-b","fork-a"]' "$STATE/payload.json" >/dev/null \
  || { echo "FAIL: non-empty exclude set must round-trip (got: $(jq -c '.conditions.repository_name.exclude' "$STATE/payload.json"))" >&2; exit 1; }

echo "org-ruleset_test: all assertions passed (apply/verify/abort)"
