#!/usr/bin/env bash
set -euo pipefail

# org-ruleset.sh — the SINGLE OWNER of the org-wide PR-validator configuration AND
# the main-branch protection, applied to every opencharly repo from ONE ruleset.
#
# THE ONE ORG-LEVEL CONFIG. On GitHub Team an organization branch ruleset can carry
# BOTH the `workflows` rule ("Require workflows to pass", naming a workflow in
# ANOTHER repo at a pinned ref) AND the ordinary branch rules (required status
# checks, no force-push, no deletion, no creation). GitHub then, for every targeted
# repo:
#   * runs the named required workflow on its PRs (here
#     `opencharly/.github/.github/workflows/org-wide-pr-validator-required.yml@main`,
#     which calls the one reusable validator `pr-validator.yml@main`), producing the
#     `validate / validate` check run; and
#   * enforces the branch rules that require exactly that check.
#
# So ONE org ruleset replaces BOTH of the old per-repo mechanisms:
#   * the per-repo branch RULESET (previously applied one-by-one by the now-deleted
#     per-repo ruleset owner script), and
#   * the per-repo `.github/workflows/pr-validator.yml` DISPATCHER stub — which only
#     ever existed because org required-workflows need GitHub Team (the org was on
#     the free plan when the per-repo pattern began). The stub FILES are retired by
#     `.github/workflows/retire-per-repo-dispatchers.yml` (they need an app-token
#     commit on a protected `main`, which this operator-run script cannot make), and
#     `apply` here REFUSES until that retirement has run.
# Nothing is copied into any repo; there is no per-repo validator config to drift.
#
# THE ONE SETTING THAT CANNOT MOVE: `allow_auto_merge` is a per-repository setting
# with no org-level default (the org endpoint exposes none). The validator enables
# GitHub native auto-merge on a PASS, which fails and leaves the check red when the
# repo setting is off — so this script still enforces it per repo.
#
# THE RULESET CARRIES ONLY THE SAME BYPASS THE OLD PER-REPO RULESETS DID: the
# `charly-auto-merge` app, whose protected-main CHANGELOG writes must land. It
# deliberately adds NO human bypass, so main protection is not loosened.
#
# usage: $0 {apply|verify}
#   apply  — enable the org ruleset, delete the now-redundant per-repo rulesets, and
#            enforce the per-repo `allow_auto_merge` setting. Idempotent.
#   verify — read-only; assert the whole end state.

readonly RULESET_NAME="org-wide required workflow & main protection"
readonly REPO_RULESET_NAME="main branch protection"
readonly REQUIRED_PATH=".github/workflows/org-wide-pr-validator-required.yml"
readonly REQUIRED_REF="${REQUIRED_REF:-refs/heads/main}"
readonly CONTEXT="validate / validate"
readonly APP_SLUG="charly-auto-merge"

# shellcheck source=lib-org.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-org.sh"

usage() { echo "usage: $0 {apply|verify}" >&2; exit 2; }
[[ $# -eq 1 ]] || usage
mode="$1"
[[ "$mode" == apply || "$mode" == verify ]] || usage
command -v gh >/dev/null

SOURCE_ID="$(gh api "repos/$ORG/$SOURCE_REPO" --jq .id)"

# The GitHub App that runs the org's tag-on-merge changelog writes and the
# validator's bot pushes. It is a scoped BYPASS actor of the org ruleset so its
# protected-main writes can land (the legacy branch-protection API dropped bypass
# fields; the ruleset API carries them).
app_id() {
  if [[ -n "${OPENCHARLY_APP_ID:-}" ]]; then
    echo "$OPENCHARLY_APP_ID"
    return
  fi
  gh api "apps/$APP_SLUG" --jq .id
}
APP_ID="$(app_id)"

# TARGET repos: active, non-fork, default branch `main` — the exact set the old
# per-repo ruleset owner applied to. Discovered, never hand-listed.
mapfile -t repos < <(discover_repos)
[[ ${#repos[@]} -gt 0 ]] || { echo "no active repositories discovered for $ORG" >&2; exit 1; }

# EXCLUDE set for the org ruleset's `repository_name` condition: everything that is
# NOT a target (archived, fork, or a non-`main` default branch). `~ALL` targets every
# repo, so the non-targets must be named out explicitly to mirror the old scope.
mapfile -t excludes < <(discover_excludes)
exclude_json() {
  local out="[" first=1 n
  for n in "${excludes[@]}"; do
    [[ $first == 1 ]] || out+=","
    out+="\"$n\""
    first=0
  done
  echo "$out]"
}

ruleset_payload() {
  cat <<JSON
{
  "name": "$RULESET_NAME",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "repository_name": {"include": ["~ALL"], "exclude": $(exclude_json), "protected": false},
    "ref_name": {"include": ["refs/heads/main"], "exclude": []}
  },
  "bypass_actors": [
    {"actor_id": $APP_ID, "actor_type": "Integration", "bypass_mode": "always"}
  ],
  "rules": [
    {"type": "workflows", "parameters": {"workflows": [
      {"repository_id": $SOURCE_ID, "path": "$REQUIRED_PATH", "ref": "$REQUIRED_REF"}
    ]}},
    {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": true, "required_status_checks": [{"context": "$CONTEXT"}]}},
    {"type": "non_fast_forward", "parameters": {}},
    {"type": "deletion", "parameters": {}},
    {"type": "creation", "parameters": {}}
  ]
}
JSON
}

# All reads below run under `set -e`: a 401/403/rate-limit/network failure ABORTS the
# script rather than being silently mistaken for an empty result. Only the dispatcher
# existence check has to tell a real 404 (absent) from an API failure, so it alone
# inspects the HTTP status.

existing_id() {
  gh api "orgs/$ORG/rulesets" \
    --jq ".[] | select(.name == \"$RULESET_NAME\") | .id"
}

repo_ruleset_id() {
  gh api "repos/$ORG/$1/rulesets" \
    --jq ".[] | select(.name == \"$REPO_RULESET_NAME\") | .id"
}

# has_dispatcher <repo> — 0 if the per-repo dispatcher file exists, 1 if it is a real
# 404, and a hard abort on any other status (a transient error must never read as
# "absent" and silently skip retirement, which would leave a duplicate producer).
has_dispatcher() {
  local code
  code="$(api_status "repos/$ORG/$1/contents/$(dispatcher_path_for "$1")")"
  case "$code" in
    200) return 0 ;;
    404) return 1 ;;
    *) echo "FATAL: gh api contents for $1 -> HTTP $code" >&2; exit 1 ;;
  esac
}

case "$mode" in
  apply)
    # The required workflow must exist on the pinned ref the ruleset names.
    gh api "repos/$ORG/$SOURCE_REPO/contents/$REQUIRED_PATH?ref=${REQUIRED_REF#refs/heads/}" --jq .sha >/dev/null \
      || { echo "required workflow missing on $REQUIRED_REF in $SOURCE_REPO — merge it first" >&2; exit 1; }

    # apply order (idempotent; safe to re-run):
    #   1. refuse while any repo still carries a dispatcher — enabling the org
    #      required workflow with a surviving dispatcher yields TWO producers of
    #      `validate / validate`, which keeps mergeability BLOCKED despite PASS (the
    #      measured #38 hazard). The dispatchers are retired first by
    #      retire-per-repo-dispatchers.yml, so step 2 is the sole producer.
    #   2. create/update the org ruleset — protection is enabled so main is never
    #      unprotected; the required workflow is now the only producer of the check.
    #   3. delete the per-repo rulesets (now redundant — the org ruleset carries the
    #      same required check + branch rules).
    #   4. enforce the per-repo `allow_auto_merge` setting.
    stragglers=0
    for repo in "${repos[@]}"; do
      has_dispatcher "$repo" && { echo "REFUSING: $repo still carries a dispatcher" >&2; stragglers=$((stragglers+1)); }
    done
    if [[ "$stragglers" != 0 ]]; then
      echo "retire them first: gh workflow run retire-per-repo-dispatchers.yml" >&2
      exit 1
    fi
    id="$(existing_id)"
    if [[ -n "$id" ]]; then
      gh api --method PUT "orgs/$ORG/rulesets/$id" --input <(ruleset_payload) --jq .id >/dev/null
      echo "org ruleset updated ($id)"
    else
      id="$(gh api --method POST "orgs/$ORG/rulesets" --input <(ruleset_payload) --jq .id)"
      echo "org ruleset created ($id)"
    fi
    echo "required workflow: $SOURCE_REPO/$REQUIRED_PATH@$REQUIRED_REF"

    for repo in "${repos[@]}"; do
      rid="$(repo_ruleset_id "$repo")"
      [[ -n "$rid" ]] || continue
      gh api --method DELETE "repos/$ORG/$repo/rulesets/$rid" >/dev/null
      echo "$repo: removed redundant per-repo ruleset"
    done

    for repo in "${repos[@]}"; do
      auto="$(gh api "repos/$ORG/$repo" --jq '.allow_auto_merge')"
      if [[ "$auto" != "true" ]]; then
        gh api --method PATCH "repos/$ORG/$repo" -f allow_auto_merge=true --jq .allow_auto_merge >/dev/null
        echo "$repo: enabled repo-level allow_auto_merge"
      fi
    done
    ;;
  verify)
    fail=0
    id="$(existing_id)"
    [[ -n "$id" ]] || { echo "no org ruleset named '$RULESET_NAME'" >&2; fail=1; }
    if [[ -n "$id" ]]; then
      state="$(gh api "orgs/$ORG/rulesets/$id")"
      echo "$state" | jq -e '.enforcement == "active"' >/dev/null || { echo "org ruleset not active" >&2; fail=1; }
      echo "$state" | jq -e --arg p "$REQUIRED_PATH" \
        '[.rules[]|select(.type=="workflows")|.parameters.workflows[].path] | index($p) != null' >/dev/null \
        || { echo "org ruleset does not require $REQUIRED_PATH" >&2; fail=1; }
      echo "$state" | jq -e --arg ctx "$CONTEXT" \
        '[.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context] | index($ctx) != null' >/dev/null \
        || { echo "org ruleset does not require the '$CONTEXT' check" >&2; fail=1; }
      echo "$state" | jq -e '[.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks] | first | length == 1' >/dev/null \
        || { echo "org ruleset must require EXACTLY ONE check" >&2; fail=1; }
      echo "$state" | jq -e '[.rules[]|select(.type=="required_status_checks")|.parameters.strict_required_status_checks_policy] | first == true' >/dev/null \
        || { echo "org ruleset must be strict (head up-to-date before merge)" >&2; fail=1; }
      echo "$state" | jq -e '[.rules[].type] | index("non_fast_forward") != null and index("deletion") != null and index("creation") != null' >/dev/null \
        || { echo "org ruleset is missing a branch-protection rule" >&2; fail=1; }
      echo "$state" | jq -e '[.rules[].type] | index("pull_request") == null' >/dev/null \
        || { echo "org ruleset must NOT require pull-request reviews (the validator is the gate)" >&2; fail=1; }
      echo "$state" | jq -e --argjson app "$APP_ID" \
        '[.bypass_actors[]|select(.actor_id==$app)] | length > 0' >/dev/null \
        || { echo "org ruleset is missing the $APP_SLUG app bypass" >&2; fail=1; }
      echo "$state" | jq -e '[.bypass_actors[]|select(.actor_type=="OrganizationAdmin")] | length == 0' >/dev/null \
        || { echo "org ruleset must not add a human bypass" >&2; fail=1; }
    fi
    for repo in "${repos[@]}"; do
      rid="$(repo_ruleset_id "$repo")"
      [[ -z "$rid" ]] || { echo "$repo: redundant per-repo ruleset still present" >&2; fail=1; }
      if has_dispatcher "$repo"; then
        echo "$repo: per-repo dispatcher still present" >&2; fail=1
      fi
      auto="$(gh api "repos/$ORG/$repo" --jq '.allow_auto_merge')"
      [[ "$auto" == "true" ]] || { echo "$repo: allow_auto_merge must be true" >&2; fail=1; }
    done
    [[ "$fail" == 0 ]] && echo "org-wide required workflow + main protection verified"
    exit "$fail"
    ;;
esac
