#!/usr/bin/env bash
set -euo pipefail

# ensure-rerun-label.sh — create the `rerun` label in every active non-fork repo (ONE org-wide
# pass), so an operator can add it to a PR. A label is repo-scoped in GitHub, so the sweep's
# `rerun` channel needs it present in each repo. This needs only `issues: write` (the
# charly-auto-merge App already has it) — NO `workflows: write`, NO per-repo file.
#
# IDEMPOTENT: a repo that already has the label (HTTP 422 already_exists) is skipped.
#
# usage: GH_TOKEN=<app with issues:write> [OPENCHARLY_ORG=opencharly] $0

readonly LABEL_NAME="rerun"
readonly LABEL_COLOR="0e8a16"
readonly LABEL_DESC="Re-run the failed validator on this PR head (body-only fix; no empty commit)"

# shellcheck source=lib-org.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-org.sh"

command -v gh >/dev/null
[[ -n "${GH_TOKEN:-}" ]] || { echo "GH_TOKEN is required (an App/PAT with issues:write)" >&2; exit 1; }

repos_out="$(discover_repos)" || { echo "FATAL: gh repo list (targets) failed" >&2; exit 1; }
[[ -n "$repos_out" ]] || { echo "no active repositories discovered for $ORG" >&2; exit 1; }
mapfile -t repos <<<"$repos_out"

created=0 existed=0 failed=0
for repo in "${repos[@]}"; do
  if resp="$(gh api -X POST "repos/$ORG/$repo/labels" \
      -f name="$LABEL_NAME" -f color="$LABEL_COLOR" -f description="$LABEL_DESC" 2>&1)"; then
    created=$((created+1))
  elif [[ "$resp" == *"already_exists"* ]]; then
    existed=$((existed+1))
  else
    echo "ERROR: $repo label create failed: $resp" >&2; failed=$((failed+1))
  fi
done
echo "ensure-rerun-label: created=$created existed=$existed failed=$failed"
[[ "$failed" == 0 ]]
