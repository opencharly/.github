#!/usr/bin/env bash
set -euo pipefail

# sweep-rerun.sh — the org-wide `rerun` channel (ONE source, no per-repo files).
#
# WHY A SWEEP, NOT A PER-REPO LISTENER. The org ships a plain per-repo `rerun-listener`
# (scripts/distribute-rerun-listener.sh) that re-runs the validator the instant a `rerun` label
# is added. It is the FAST path, but installing it org-wide needs a GitHub App with
# `workflows: write` (a PUT to `.github/workflows/*`). This sweep is the FALLBACK that needs
# NO per-repo file and NO `workflows: write`: it runs from THIS repo on a schedule, searches
# the org for open `rerun`-labeled PRs, and re-runs each one's failed validator run with the
# token's `actions: write`.
#
# WHAT IT DOES per matching PR: find the newest FAILED `charly/pr-validator` run whose head is
# the PR's current head, POST /actions/runs/<id>/rerun (a re-run reuses the SAME GITHUB_SHA and
# updates THAT run's check run IN PLACE — no duplicate same-name check run, clears POISON), then
# REMOVE the `rerun` label so the PR is not re-processed on the next tick (idempotent).
#
# CAPABILITY-FREE: needs only `actions: write` + `pull-requests: write` + `contents: read`
# (all already granted to the charly-auto-merge App). No `checks: write`, no workflow-file write.
#
# usage: GH_TOKEN=<app with actions:write + pull_requests:write> [OPENCHARLY_ORG=opencharly] $0

readonly LABEL="rerun"
readonly REQUIRED_WORKFLOW_NAME="charly/pr-validator"

# shellcheck source=lib-org.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-org.sh"

command -v gh >/dev/null
[[ -n "${GH_TOKEN:-}" ]] || { echo "GH_TOKEN is required (an App/PAT with actions:write + pull_requests:write)" >&2; exit 1; }

# Labeled PRs across the org: "owner/repo number".
labeled="$(gh search prs --owner "$ORG" --label "$LABEL" --state open --limit 1000 \
  --json number,repository --jq '.[] | "\(.repository.nameWithOwner) \(.number)"' 2>/dev/null || true)"

if [[ -z "$labeled" ]]; then
  echo "sweep-rerun: no open '$LABEL'-labeled PRs"
  exit 0
fi

rerun=0 no_run=0 failed=0
while read -r repo number; do
  [[ -n "$repo" && -n "$number" ]] || continue
  head="$(gh api "repos/$repo/pulls/$number" --jq .head.sha 2>/dev/null || true)"
  if [[ -z "$head" ]]; then
    echo "ERROR: $repo#$number head SHA unavailable" >&2; failed=$((failed+1)); continue
  fi
  # The newest FAILED validator run whose head is exactly this PR head.
  id="$(gh run list --repo "$repo" --limit 100 \
    --json databaseId,headSha,name,conclusion \
    --jq '.[] | select(.headSha=="'"$head"'") | select(.name=="'"$REQUIRED_WORKFLOW_NAME"'") | select(.conclusion=="failure") | .databaseId' \
    2>/dev/null | head -1 || true)"
  if [[ -z "$id" ]]; then
    echo "$repo#$number: no failed $REQUIRED_WORKFLOW_NAME run on head ${head:0:9} — removing label"
    no_run=$((no_run+1))
  else
    if gh api -X POST "repos/$repo/actions/runs/$id/rerun" >/dev/null 2>&1; then
      echo "$repo#$number: re-ran validator run $id (head ${head:0:9})"
      rerun=$((rerun+1))
    else
      echo "ERROR: $repo#$number: rerun of run $id failed" >&2; failed=$((failed+1)); continue
    fi
  fi
  # Remove the label so this PR is not re-processed next tick (idempotent). Best-effort: a
  # label-remove failure does not undo the rerun.
  gh pr edit "$number" --repo "$repo" --remove-label "$LABEL" >/dev/null 2>&1 \
    || echo "warning: $repo#$number: could not remove the '$LABEL' label" >&2
done <<<"$labeled"

echo "sweep-rerun: reran=$rerun no_failed_run=$no_run failed=$failed"
[[ "$failed" == 0 ]]
