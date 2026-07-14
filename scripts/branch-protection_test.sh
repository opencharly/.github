#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK_GH_STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$MOCK_GH_STATE_DIR"' EXIT

printf '%s\n' charly/claude-validation >"$MOCK_GH_STATE_DIR/alpha"
printf '%s\n' charly/claude-validation >"$MOCK_GH_STATE_DIR/beta"
printf '0\n' >"$MOCK_GH_STATE_DIR/reads"
printf '0\n' >"$MOCK_GH_STATE_DIR/patches"

gh() {
  if [[ "$1 $2" == "repo list" ]]; then
    printf '%s\n' alpha beta
    return
  fi

  [[ "$1" == api ]] || return 90
  shift
  method=GET
  if [[ "$1" == --method ]]; then
    method="$2"
    shift 2
  fi
  path="$1"
  shift
  repo="${path#repos/test/}"
  repo="${repo%%/*}"
  [[ "$path" == "repos/test/$repo/branches/main/protection/required_status_checks" ]] || return 91

  if [[ "$method" == GET ]]; then
    reads="$(<"$MOCK_GH_STATE_DIR/reads")"
    printf '%s\n' "$((reads + 1))" >"$MOCK_GH_STATE_DIR/reads"
    printf 'true\t1\t%s\n' "$(<"$MOCK_GH_STATE_DIR/$repo")"
    return
  fi

  [[ "$method" == PATCH ]] || return 92
  [[ "$(<"$MOCK_GH_STATE_DIR/reads")" -ge 2 ]] || return 93
  [[ "$*" == *'-F strict=true'* ]] || return 94
  [[ "$*" == *'-f contexts[]=charly/pr-validator'* ]] || return 95
  printf '%s\n' charly/pr-validator >"$MOCK_GH_STATE_DIR/$repo"
  patches="$(<"$MOCK_GH_STATE_DIR/patches")"
  printf '%s\n' "$((patches + 1))" >"$MOCK_GH_STATE_DIR/patches"
}
export -f gh
export MOCK_GH_STATE_DIR

OPENCHARLY_ORG='test' "$root/scripts/branch-protection.sh" apply

[[ "$(<"$MOCK_GH_STATE_DIR/alpha")" == charly/pr-validator ]]
[[ "$(<"$MOCK_GH_STATE_DIR/beta")" == charly/pr-validator ]]
[[ "$(<"$MOCK_GH_STATE_DIR/patches")" == 2 ]]
echo "branch-protection contract: PASS"
