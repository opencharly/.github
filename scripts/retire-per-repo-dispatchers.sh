#!/usr/bin/env bash
set -euo pipefail

# retire-per-repo-dispatchers.sh — delete every repo's redundant per-repo validator
# dispatcher stub, in ONE org-wide pass.
#
# WHY THIS EXISTS SEPARATELY FROM scripts/org-ruleset.sh: the deletion writes to a
# protected `main`, so the commit must be authored by a ruleset BYPASS actor — the
# `charly-auto-merge` App. This script is invoked by
# `.github/workflows/retire-per-repo-dispatchers.yml`, which mints the App token and
# exports it as `GH_TOKEN`; `gh api` then acts as that App. It is a shell script (not
# inline github-script) so it is covered by the same offline mock-`gh` test pattern
# as the owner script.
#
# The org required workflow becomes the sole producer of the required
# `validate / validate` check, so every repo's stub is redundant — and while it
# remains, a PR carries TWO same-name check runs, which keeps mergeability BLOCKED
# despite PASS (the measured #38 lesson). Run this BEFORE scripts/org-ruleset.sh
# apply, which refuses while any dispatcher survives.
#
# Idempotent: an already-absent stub is skipped. A non-404 API error is FATAL — it
# must never read as "absent" and silently leave a duplicate producer.
#
# usage: GH_TOKEN=<app|pat> $0

readonly ORG="${OPENCHARLY_ORG:-opencharly}"
readonly SOURCE_REPO=".github"
readonly DISPATCHER_PATH=".github/workflows/pr-validator.yml"
readonly SOURCE_DISPATCHER_PATH=".github/workflows/pr-validator-dispatcher.yml"
readonly MAX_FAILURES="${RETIRE_MAX_FAILURES:-20}"

command -v gh >/dev/null
[[ -n "${GH_TOKEN:-}" ]] || { echo "GH_TOKEN is required (the bypass-actor App/PAT)" >&2; exit 1; }

dispatcher_path_for() {
  [[ "$1" == "$SOURCE_REPO" ]] && echo "$SOURCE_DISPATCHER_PATH" || echo "$DISPATCHER_PATH"
}

api_status() {
  local resp
  resp="$(gh api --include "$1" 2>&1 || true)"
  printf '%s\n' "$resp" | awk 'NR==1 { print $2; exit }'
}

mapfile -t repos < <(
  gh repo list "$ORG" --limit 1000 \
    --json name,isArchived,isFork,defaultBranchRef \
    --jq '.[] | select(.isArchived == false and .isFork == false and .defaultBranchRef.name == "main") | .name' |
    sort
)
[[ ${#repos[@]} -gt 0 ]] || { echo "no active repositories discovered for $ORG" >&2; exit 1; }

deleted=0 skipped=0 failed=0
for repo in "${repos[@]}"; do
  path="$(dispatcher_path_for "$repo")"
  code="$(api_status "repos/$ORG/$repo/contents/$path")"
  case "$code" in
    404) skipped=$((skipped+1)); continue ;;
    200) ;;
    *) echo "FATAL: $repo contents probe -> HTTP $code" >&2; exit 1 ;;
  esac
  # The blob SHA is the delete target's concurrency guard.
  sha="$(gh api "repos/$ORG/$repo/contents/$path" --jq .sha)"
  if gh api --method DELETE "repos/$ORG/$repo/contents/$path" \
      -f message="chore: retire the per-repo validator dispatcher (org-wide required workflow)" \
      -f sha="$sha" -f branch=main --jq '.commit.sha' >/dev/null; then
    echo "$repo: retired $path"; deleted=$((deleted+1))
  else
    echo "ERROR: $repo deleteFile failed" >&2; failed=$((failed+1))
    [[ "$failed" -gt "$MAX_FAILURES" ]] && { echo "too many failures — aborting" >&2; exit 1; }
  fi
done
echo "retired=$deleted absent=$skipped failed=$failed"
[[ "$failed" == 0 ]]
