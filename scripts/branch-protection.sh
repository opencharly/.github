#!/usr/bin/env bash
set -euo pipefail

readonly ORG="${OPENCHARLY_ORG:-opencharly}"
readonly OLD_CONTEXT="charly/claude-validation"
readonly NEW_CONTEXT="charly/pr-validator"

usage() {
  echo "usage: $0 {apply|verify}" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
mode="$1"
[[ "$mode" == apply || "$mode" == verify ]] || usage

command -v gh >/dev/null

mapfile -t repos < <(
  gh repo list "$ORG" --limit 1000 \
    --json name,isArchived,isFork,defaultBranchRef \
    --jq '.[] | select(.isArchived == false and .isFork == false and .defaultBranchRef.name == "main") | .name' |
    sort
)
[[ ${#repos[@]} -gt 0 ]] || {
  echo "no active repositories discovered for $ORG" >&2
  exit 1
}

read_context() {
  local repo="$1"
  gh api "repos/$ORG/$repo/branches/main/protection/required_status_checks" \
    --jq '[.strict, (.contexts | length), .contexts[0]] | @tsv'
}

declare -A current
for repo in "${repos[@]}"; do
  current["$repo"]="$(read_context "$repo")"
  IFS=$'\t' read -r strict count context <<<"${current[$repo]}"
  [[ "$strict" == true && "$count" == 1 ]] || {
    echo "$repo: expected strict=true with exactly one required context; got ${current[$repo]}" >&2
    exit 1
  }
  [[ "$context" == "$OLD_CONTEXT" || "$context" == "$NEW_CONTEXT" ]] || {
    echo "$repo: unexpected required context $context" >&2
    exit 1
  }
done

if [[ "$mode" == apply ]]; then
  for repo in "${repos[@]}"; do
    IFS=$'\t' read -r _ _ context <<<"${current[$repo]}"
    if [[ "$context" == "$OLD_CONTEXT" ]]; then
      gh api --method PUT \
        "repos/$ORG/$repo/branches/main/protection/required_status_checks" \
        -F strict=true -f "contexts[]=$NEW_CONTEXT" >/dev/null
      echo "$repo: $OLD_CONTEXT -> $NEW_CONTEXT"
    else
      echo "$repo: already $NEW_CONTEXT"
    fi
  done
fi

fail=0
for repo in "${repos[@]}"; do
  state="$(read_context "$repo")"
  IFS=$'\t' read -r strict count context <<<"$state"
  if [[ "$strict" == true && "$count" == 1 && "$context" == "$NEW_CONTEXT" ]]; then
    echo "$repo: verified $NEW_CONTEXT"
  else
    echo "$repo: verification failed: $state" >&2
    fail=1
  fi
done
exit "$fail"
