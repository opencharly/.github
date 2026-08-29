#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK_GH_STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$MOCK_GH_STATE_DIR"' EXIT

# Per-repo allow_auto_merge: alpha already true, beta false — the regression the
# script now applies and verifies (the org-wide pr-validator's PASS enables native
# auto-merge; with the repo setting off the GraphQL call fails and the check run
# stays red even after a PASS verdict).
printf 'true\n'  >"$MOCK_GH_STATE_DIR/alpha"
printf 'false\n' >"$MOCK_GH_STATE_DIR/beta"
: >"$MOCK_GH_STATE_DIR/transcript"

gh() {
  if [[ "$1 $2" == "repo list" ]]; then
    printf '%s\n' 'repo list' >>"$MOCK_GH_STATE_DIR/transcript"
    printf '%s\n' alpha beta
    return
  fi

  [[ "$1" == api ]] || return 90
  shift
  local method=GET
  if [[ "${1:-}" == --method ]]; then
    method="$2"
    shift 2
  fi
  [[ -n "${1:-}" ]] || return 90
  local path="$1"
  shift

  # The GitHub App id (script resolves the bypass actor).
  if [[ "$path" == "apps/charly-auto-merge" ]]; then
    printf '123\n'
    return
  fi

  local repo=""
  [[ "$path" =~ ^repos/test/(alpha|beta)(/|$) ]] && repo="${BASH_REMATCH[1]}"
  [[ -n "$repo" ]] || return 91

  # Repo settings — GET reads the per-repo state, PATCH enforces true.
  # (The script always projects with --jq '.allow_auto_merge', so echo the VALUE.)
  if [[ "$path" == "repos/test/$repo" && "$method" == GET ]]; then
    printf '%s\n' "$(<"$MOCK_GH_STATE_DIR/$repo")"
    return
  fi
  if [[ "$path" == "repos/test/$repo" && "$method" == PATCH ]]; then
    printf 'true\n' >"$MOCK_GH_STATE_DIR/$repo"
    printf 'PATCH %s allow_auto_merge\n' "$repo" >>"$MOCK_GH_STATE_DIR/transcript"
    printf 'true\n'
    return
  fi

  # Rulesets — apply-mode "existing" probe (GET, no query) reports none so the
  # script POSTs; verify-mode list (?includes_parents=true) reports the id.
  if [[ "$path" == "repos/test/$repo/rulesets" && "$method" == GET ]]; then
    return 0
  fi
  if [[ "$path" == "repos/test/$repo/rulesets?includes_parents=true" ]]; then
    printf '99\n'
    return
  fi
  if [[ "$path" == "repos/test/$repo/rulesets" && "$method" == POST ]]; then
    printf '99\n'
    return
  fi
  if [[ "$path" == "repos/test/$repo/rulesets/99" ]]; then
    # Canonical ruleset detail the verify mode asserts against: exactly one
    # required check ("validate / validate"), strict, no pull-request review,
    # non_fast_forward + deletion blocked, and the app as bypass actor.
    cat <<JSON
{"id":99,"rules":["required_status_checks","non_fast_forward","deletion","creation"],"strict":true,"checks":["validate / validate"],"bypass":[123]}
JSON
    return
  fi

  # Legacy branch protection probe — absent (HTTP error surfaces as exit 1).
  if [[ "$path" == "repos/test/$repo/branches/main/protection" ]]; then
    return 1
  fi

  return 91
}
export -f gh
export MOCK_GH_STATE_DIR

# apply: beta (false) must be PATCHed to true; alpha (already true) untouched.
OPENCHARLY_ORG='test' "$root/scripts/branch-protection.sh" apply >/dev/null
grep -qx 'PATCH beta allow_auto_merge' "$MOCK_GH_STATE_DIR/transcript" \
  || { echo "FAIL: apply did not enable auto-merge on beta" >&2; exit 1; }
grep -q 'PATCH alpha' "$MOCK_GH_STATE_DIR/transcript" \
  && { echo "FAIL: apply must not PATCH alpha (already true)" >&2; exit 1; }
[[ "$(<"$MOCK_GH_STATE_DIR/beta")" == "true" ]] \
  || { echo "FAIL: beta state not patched to true" >&2; exit 1; }

# verify passes on the now-clean state (beta was fixed by apply).
OPENCHARLY_ORG='test' "$root/scripts/branch-protection.sh" verify >/dev/null

# A regression — auto-merge flipped back off — must fail verify.
printf 'false\n' >"$MOCK_GH_STATE_DIR/alpha"
if OPENCHARLY_ORG='test' "$root/scripts/branch-protection.sh" verify >/dev/null 2>&1; then
  echo "FAIL: verify must fail when allow_auto_merge is false" >&2
  exit 1
fi

echo "branch-protection_test: all assertions passed (apply enables, verify enforces)"
