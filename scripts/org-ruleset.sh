#!/usr/bin/env bash
set -euo pipefail

# org-ruleset.sh — the SINGLE OWNER of the org-wide PR-validator REQUIRED WORKFLOW.
#
# THE ONE ORG-LEVEL CONFIG. On GitHub Team, an organization branch ruleset can
# carry the `workflows` rule ("Require workflows to pass"), which names a
# workflow in ANOTHER repo (here `opencharly/.github`) at a pinned ref. GitHub
# then runs that workflow on every PR in every targeted repo — the workflow is
# defined ONCE, in `.github`, and NO repo carries validator config of its own.
#
# This replaces the per-repo `.github/workflows/pr-validator.yml` dispatcher
# stub. The stub was only ever needed because the org was on the free plan
# (org required-workflows need GitHub Team).
#
# SPIKE-PROVEN (RDD): with the rule active, a PR gained a `validate / validate`
# check-run sourced from `.github/workflows/org-wide-pr-validator-required.yml`
# — the exact context the repo branch rulesets require.
#
# RETIREMENT HAZARD: while BOTH the org required workflow AND a repo's local
# dispatcher exist, the PR gets TWO `validate / validate` check-runs, and
# duplicate same-name check-runs keep mergeability BLOCKED despite PASS (#38).
# Enable the org rule only AFTER (or in lockstep with) retiring the dispatchers.
#
# usage: $0 {apply|verify|worklist}
#   apply    — create/update the org ruleset (enable the required workflow)
#   verify   — read-only; assert the ruleset is correct
#   worklist — list the repos still carrying a local dispatcher (to retire)

readonly ORG="${OPENCHARLY_ORG:-opencharly}"
readonly RULESET_NAME="org-wide pr-validator required workflow"
readonly SOURCE_REPO=".github"
readonly REQUIRED_PATH=".github/workflows/org-wide-pr-validator-required.yml"
readonly REQUIRED_REF="${REQUIRED_REF:-refs/heads/main}"
readonly DISPATCHER_PATH=".github/workflows/pr-validator.yml"

usage() { echo "usage: $0 {apply|verify|worklist}" >&2; exit 2; }
[[ $# -eq 1 ]] || usage
mode="$1"
[[ "$mode" == apply || "$mode" == verify || "$mode" == worklist ]] || usage
command -v gh >/dev/null

SOURCE_ID="$(gh api "repos/$ORG/$SOURCE_REPO" --jq .id)"

mapfile -t repos < <(
  gh repo list "$ORG" --limit 1000 \
    --json name,isArchived,isFork,defaultBranchRef \
    --jq '.[] | select(.isArchived == false and .isFork == false and .defaultBranchRef.name == "main") | .name' |
    sort
)
[[ ${#repos[@]} -gt 0 ]] || { echo "no active repositories discovered for $ORG" >&2; exit 1; }

ruleset_payload() {
  cat <<JSON
{
  "name": "$RULESET_NAME",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "repository_name": {"include": ["~ALL"], "exclude": [], "protected": false},
    "ref_name": {"include": ["refs/heads/main"], "exclude": []}
  },
  "rules": [
    {"type": "workflows", "parameters": {"workflows": [
      {"repository_id": $SOURCE_ID, "path": "$REQUIRED_PATH", "ref": "$REQUIRED_REF"}
    ]}}
  ]
}
JSON
}

existing_id() {
  gh api "orgs/$ORG/rulesets" \
    --jq ".[] | select(.name == \"$RULESET_NAME\") | .id" 2>/dev/null || true
}

has_dispatcher() {
  gh api "repos/$ORG/$1/contents/$DISPATCHER_PATH" --jq '.sha' >/dev/null 2>&1
}

case "$mode" in
  apply)
    [[ -f "$(dirname "${BASH_SOURCE[0]}")/../$REQUIRED_PATH" || true ]]
    gh api "repos/$ORG/$SOURCE_REPO/contents/$REQUIRED_PATH?ref=${REQUIRED_REF#refs/heads/}" --jq '.sha' >/dev/null \
      || { echo "required workflow missing on $REQUIRED_REF in $SOURCE_REPO — merge it first" >&2; exit 1; }
    id="$(existing_id)"
    if [[ -n "$id" ]]; then
      gh api --method PUT "orgs/$ORG/rulesets/$id" --input <(ruleset_payload) --jq .id >/dev/null
      echo "org ruleset updated ($id)"
    else
      id="$(gh api --method POST "orgs/$ORG/rulesets" --input <(ruleset_payload) --jq .id)"
      echo "org ruleset created ($id)"
    fi
    echo "required workflow: $SOURCE_REPO/$REQUIRED_PATH@$REQUIRED_REF"
    echo "REMINDER: retire any remaining per-repo dispatcher — run '$0 worklist'."
    ;;
  verify)
    fail=0
    id="$(existing_id)"
    [[ -n "$id" ]] || { echo "no org ruleset named '$RULESET_NAME'" >&2; fail=1; }
    if [[ -n "$id" ]]; then
      state="$(gh api "orgs/$ORG/rulesets/$id")"
      echo "$state" | jq -e '.enforcement == "active"' >/dev/null || { echo "ruleset not active" >&2; fail=1; }
      echo "$state" | jq -e --arg p "$REQUIRED_PATH" \
        '[.rules[]|select(.type=="workflows")|.parameters.workflows[].path] | index($p) != null' >/dev/null \
        || { echo "ruleset does not require $REQUIRED_PATH" >&2; fail=1; }
    fi
    [[ "$fail" == 0 ]] && echo "org required workflow verified"
    exit "$fail"
    ;;
  worklist)
    n=0
    for repo in "${repos[@]}"; do
      if has_dispatcher "$repo"; then echo "$repo"; n=$((n+1)); fi
    done
    echo "--- $n repos still carry $DISPATCHER_PATH (retire each via a PR or a bypassed file delete)" >&2
    ;;
esac
