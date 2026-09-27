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
# THE SETTINGS THAT CANNOT MOVE TO THE ORG: `allow_auto_merge` and
# `delete_branch_on_merge` are per-repository settings with no org-level default
# (the org endpoint exposes neither). `allow_auto_merge` is load-bearing: the
# validator enables GitHub native auto-merge on a PASS, which fails and leaves the
# check red when the repo setting is off. `delete_branch_on_merge` keeps `feat/`
# branches from accumulating after their squash merge (the git-workflow contract:
# `feat/` is deleted at merge). Both are enforced per repo — there is no org-wide
# toggle for either, so this script is their single owner.
#
# THE RULESET CARRIES ONLY THE SAME BYPASS THE OLD PER-REPO RULESETS DID: the
# `charly-auto-merge` app, whose protected-main CHANGELOG writes must land. It
# deliberately adds NO human bypass, so main protection is not loosened.
#
# usage: $0 {apply|verify}
#   apply  — enable the org ruleset, delete the now-redundant per-repo rulesets, and
#            enforce the per-repo `allow_auto_merge` AND `delete_branch_on_merge`
#            settings. Idempotent.
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
# per-repo ruleset owner applied to. Discovered, never hand-listed. The discovery
# status is checked at the CALL SITE (a `mapfile ... < <(fn)` guard would be dead —
# see lib-org.sh).
repos_out="$(discover_repos)" || { echo "FATAL: gh repo list (targets) failed" >&2; exit 1; }
[[ -n "$repos_out" ]] || { echo "no active repositories discovered for $ORG" >&2; exit 1; }
mapfile -t repos <<<"$repos_out"

# EXCLUDE set for the org ruleset's `repository_name` condition: everything that is
# NOT a target (archived, fork, or a non-`main` default branch). `~ALL` targets every
# repo, so the non-targets must be named out explicitly to mirror the old scope. An
# API failure here (an empty result is legitimate, so emptiness is NOT the signal) is
# fatal — otherwise `exclude` would be `[]` and the ruleset would target forks and
# archived repos too.
excludes_out="$(discover_excludes)" || { echo "FATAL: gh repo list (excludes) failed" >&2; exit 1; }
# An empty exclude set is LEGITIMATE (no forks/archived repos), so it must produce an
# EMPTY array — not `mapfile <<<"$empty"`, which yields one empty element and would
# emit `[""]` (targeting a repo named "") instead of `[]`.
excludes=()
if [[ -n "$excludes_out" ]]; then mapfile -t excludes <<<"$excludes_out"; fi
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

# Read-failure policy: a 401/403/rate-limit/network failure must ABORT, never read as
# an empty/absent result. The plain list reads below (`existing_id`, `repo_ruleset_id`,
# the allow_auto_merge GET) run under `set -e`, so a non-zero exit aborts the script.
# The two reads that must distinguish a REAL 404 (legitimately absent) from an API
# failure — the dispatcher existence check (`has_dispatcher`) and the legacy-protection
# probe in `apply` — are exempt from that reasoning (a probe inside `if`/`case` is
# ignored by `set -e`), so they inspect the HTTP status explicitly via `api_status` and
# abort on anything that is neither 200 nor 404.

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
    #   4. remove any surviving LEGACY branch protection (repos/…/branches/main/
    #      protection). Org rulesets are additive and do NOT remove it, and the
    #      classic protection has no bypass slot for `charly-auto-merge`, so it would
    #      block the App's protected-main CHANGELOG writes.
    #   5. enforce the per-repo `allow_auto_merge` and `delete_branch_on_merge`
    #      settings (neither has an org-level default).
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
      # The classic protection blocks the app's changelog write (no bypass) — remove
      # it wherever it survives. This must classify the HTTP status exactly like
      # has_dispatcher: a plain `if gh api …` is exempt from `set -e`, so a 401/403/5xx
      # would read as "absent" and silently skip the removal. 404 = absent (no-op);
      # 200 = present (remove); anything else = FATAL.
      legacy="$(api_status "repos/$ORG/$repo/branches/main/protection")"
      case "$legacy" in
        404) ;;
        200)
          gh api --method DELETE "repos/$ORG/$repo/branches/main/protection" >/dev/null
          echo "$repo: removed legacy branch protection" ;;
        *) echo "FATAL: $repo legacy-protection probe -> HTTP $legacy" >&2; exit 1 ;;
      esac
    done

    for repo in "${repos[@]}"; do
      auto="$(gh api "repos/$ORG/$repo" --jq '.allow_auto_merge')"
      if [[ "$auto" != "true" ]]; then
        gh api --method PATCH "repos/$ORG/$repo" -f allow_auto_merge=true --jq .allow_auto_merge >/dev/null
        echo "$repo: enabled repo-level allow_auto_merge"
      fi
      dbom="$(gh api "repos/$ORG/$repo" --jq '.delete_branch_on_merge')"
      if [[ "$dbom" != "true" ]]; then
        gh api --method PATCH "repos/$ORG/$repo" -f delete_branch_on_merge=true --jq .delete_branch_on_merge >/dev/null
        echo "$repo: enabled repo-level delete_branch_on_merge"
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
      # TARGET SCOPE: the ruleset must target `~ALL` (minus the excluded non-target
      # repos) on `refs/heads/main` — a silently narrowed/widened scope would still
      # otherwise pass. The expected exclude set is re-derived and compared exactly.
      echo "$state" | jq -e '.conditions.repository_name.include == ["~ALL"]' >/dev/null \
        || { echo "org ruleset must target ~ALL repositories" >&2; fail=1; }
      echo "$state" | jq -e '.conditions.repository_name.protected == false' >/dev/null \
        || { echo "org ruleset repository_name.protected must be false" >&2; fail=1; }
      echo "$state" | jq -e --argjson exp "$(exclude_json)" \
        '.conditions.repository_name.exclude == $exp' >/dev/null \
        || { echo "org ruleset exclude set does not match the non-target repos" >&2; fail=1; }
      echo "$state" | jq -e '.conditions.ref_name.include == ["refs/heads/main"] and .conditions.ref_name.exclude == []' >/dev/null \
        || { echo "org ruleset must target exactly refs/heads/main" >&2; fail=1; }
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
      legacy="$(api_status "repos/$ORG/$repo/branches/main/protection")"
      [[ "$legacy" == "404" ]] || { echo "$repo: legacy branch protection still present (HTTP $legacy)" >&2; fail=1; }
      auto="$(gh api "repos/$ORG/$repo" --jq '.allow_auto_merge')"
      [[ "$auto" == "true" ]] || { echo "$repo: allow_auto_merge must be true" >&2; fail=1; }
      dbom="$(gh api "repos/$ORG/$repo" --jq '.delete_branch_on_merge')"
      [[ "$dbom" == "true" ]] || { echo "$repo: delete_branch_on_merge must be true" >&2; fail=1; }
    done
    [[ "$fail" == 0 ]] && echo "org-wide required workflow + main protection verified"
    exit "$fail"
    ;;
esac
