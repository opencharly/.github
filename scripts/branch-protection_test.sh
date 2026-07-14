#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK_GH_STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$MOCK_GH_STATE_DIR"' EXIT

printf '%s\n' charly/claude-validation >"$MOCK_GH_STATE_DIR/alpha"
printf '%s\n' charly/claude-validation >"$MOCK_GH_STATE_DIR/beta"
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
  if [[ "$1" == --method ]]; then
    method="$2"
    shift 2
  fi
  local path="$1"
  shift
  local repo="${path#repos/test/}"
  repo="${repo%%/*}"
  [[ "$path" == "repos/test/$repo/branches/main/protection/required_status_checks" ]] || return 91

  if [[ "$method" == GET ]]; then
    printf 'GET %s\n' "$repo" >>"$MOCK_GH_STATE_DIR/transcript"
    printf 'true\t1\t%s\n' "$(<"$MOCK_GH_STATE_DIR/$repo")"
    return
  fi

  [[ "$method" == PATCH ]] || return 92
  [[ $# -eq 4 ]] || return 93
  [[ "$1" == -F && "$2" == strict=true ]] || return 94
  [[ "$3" == -f && "$4" == 'contexts[]=charly/pr-validator' ]] || return 95
  printf 'PATCH %s %s %s %s %s\n' "$repo" "$1" "$2" "$3" "$4" \
    >>"$MOCK_GH_STATE_DIR/transcript"
  printf '%s\n' "${4#contexts[]=}" >"$MOCK_GH_STATE_DIR/$repo"
}
export -f gh
export MOCK_GH_STATE_DIR

OPENCHARLY_ORG='test' "$root/scripts/branch-protection.sh" apply

[[ "$(<"$MOCK_GH_STATE_DIR/alpha")" == charly/pr-validator ]]
[[ "$(<"$MOCK_GH_STATE_DIR/beta")" == charly/pr-validator ]]
expected=$'repo list\nGET alpha\nGET beta\nPATCH alpha -F strict=true -f contexts[]=charly/pr-validator\nPATCH beta -F strict=true -f contexts[]=charly/pr-validator\nGET alpha\nGET beta'
[[ "$(<"$MOCK_GH_STATE_DIR/transcript")" == "$expected" ]]
echo "branch-protection contract: PASS"
