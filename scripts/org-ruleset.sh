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
#   * the per-repo branch RULESET (previously applied one-by-one by the deleted
#     scripts/branch-protection.sh), and
#   * the per-repo `.github/workflows/pr-validator.yml` DISPATCHER stub — which only
#     ever existed because org required-workflows need GitHub Team (the org was on
#     the free plan when the per-repo pattern began).
# Nothing is copied into any repo; there is no per-repo validator config to drift.
#
# THE ONE SETTING THAT CANNOT MOVE: `allow_auto_merge` is a per-repository setting
# with no org-level default (the org endpoint does not expose one). The validator
# enables GitHub native auto-merge on a PASS, which fails and leaves the check red
# when the repo setting is off — so this script still enforces it per repo.
#
# usage: $0 {apply|verify}
#   apply  — the one-shot, idempotent cutover: enable the org ruleset, delete the
#            now-redundant per-repo rulesets, retire the per-repo dispatcher files,
#            and enforce the per-repo `allow_auto_merge` setting.
#   verify — read-only; assert the whole end state.

readonly ORG="${OPENCHARLY_ORG:-opencharly}"
readonly RULESET_NAME="org-wide required workflow & main protection"
readonly REPO_RULESET_NAME="main branch protection"
readonly SOURCE_REPO=".github"
readonly REQUIRED_PATH=".github/workflows/org-wide-pr-validator-required.yml"
readonly REQUIRED_REF="${REQUIRED_REF:-refs/heads/main}"
readonly DISPATCHER_PATH=".github/workflows/pr-validator.yml"
# The SOURCE repo's dispatcher lives at a DIFFERENT path: its `pr-validator.yml` is
# the REUSABLE, so its own dispatcher stub is the `-dispatcher.yml` file. The org
# ruleset still targets `.github` (it is in `~ALL`), so that stub must be retired too
# or `.github` PRs would get duplicate `validate / validate` producers.
readonly SOURCE_DISPATCHER_PATH=".github/workflows/pr-validator-dispatcher.yml"
readonly CONTEXT="validate / validate"
readonly APP_SLUG="charly-auto-merge"

usage() { echo "usage: $0 {apply|verify}" >&2; exit 2; }
[[ $# -eq 1 ]] || usage
mode="$1"
[[ "$mode" == apply || "$mode" == verify ]] || usage
command -v gh >/dev/null

SOURCE_ID="$(gh api "repos/$ORG/$SOURCE_REPO" --jq .id)"

# The GitHub App that runs the org's tag-on-merge changelog writes and the
# validator's bot pushes. It is a scoped BYPASS actor of the org ruleset so its
# protected-main writes can land (the legacy branch-protection API drops bypass
# fields; the ruleset API carries them). `OrganizationAdmin` is ALSO a bypass actor
# so this cutover's operator can retarget the per-repo dispatchers directly.
app_id() {
  if [[ -n "${OPENCHARLY_APP_ID:-}" ]]; then
    echo "$OPENCHARLY_APP_ID"
    return
  fi
  gh api "apps/$APP_SLUG" --jq .id
}
APP_ID="$(app_id)"

# TARGET repos: active, non-fork, default branch `main` — the exact set the deleted
# branch-protection.sh applied to. Discovered, never hand-listed.
mapfile -t repos < <(
  gh repo list "$ORG" --limit 1000 \
    --json name,isArchived,isFork,defaultBranchRef \
    --jq '.[] | select(.isArchived == false and .isFork == false and .defaultBranchRef.name == "main") | .name' |
    sort
)
[[ ${#repos[@]} -gt 0 ]] || { echo "no active repositories discovered for $ORG" >&2; exit 1; }

# EXCLUDE set for the org ruleset's `repository_name` condition: everything that is
# NOT a target (archived, fork, or a non-`main` default branch). `~ALL` targets every
# repo, so the non-targets must be named out explicitly to mirror the old scope.
mapfile -t excludes < <(
  gh repo list "$ORG" --limit 1000 \
    --json name,isArchived,isFork,defaultBranchRef \
    --jq '.[] | select((.isArchived == true) or (.isFork == true) or (.defaultBranchRef.name != "main")) | .name' |
    sort
)
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
    {"actor_id": null, "actor_type": "OrganizationAdmin", "bypass_mode": "always"},
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

existing_id() {
  gh api "orgs/$ORG/rulesets" \
    --jq ".[] | select(.name == \"$RULESET_NAME\") | .id" 2>/dev/null || true
}

has_dispatcher() {
  gh api "repos/$ORG/$1/contents/$(dispatcher_path_for "$1")" --jq '.sha' >/dev/null 2>&1
}

# dispatcher_path_for returns the repo-appropriate dispatcher path: the SOURCE repo
# uses the `-dispatcher.yml` stub (its `pr-validator.yml` is the reusable).
dispatcher_path_for() {
  [[ "$1" == "$SOURCE_REPO" ]] && echo "$SOURCE_DISPATCHER_PATH" || echo "$DISPATCHER_PATH"
}

# retire_dispatcher deletes the per-repo dispatcher file on `main`. The org ruleset's
# OrganizationAdmin bypass lets the operator's token land the commit directly.
retire_dispatcher() {
  local repo="$1" path sha
  path="$(dispatcher_path_for "$repo")"
  sha="$(gh api "repos/$ORG/$repo/contents/$path?ref=main" --jq .sha)"
  gh api --method DELETE "repos/$ORG/$repo/contents/$path" \
    -f message="chore: retire the per-repo validator dispatcher (org-wide required workflow)" \
    -f sha="$sha" -f branch=main --jq '.commit.sha' >/dev/null
}

ensure_auto_merge() {
  local repo="$1" auto
  auto="$(gh api "repos/$ORG/$repo" --jq '.allow_auto_merge' 2>/dev/null || true)"
  if [[ "$auto" != "true" ]]; then
    gh api --method PATCH "repos/$ORG/$repo" -f allow_auto_merge=true --jq .allow_auto_merge >/dev/null
  fi
}

delete_repo_ruleset() {
  local repo="$1" id
  id="$(gh api "repos/$ORG/$repo/rulesets" \
    --jq ".[] | select(.name == \"$REPO_RULESET_NAME\") | .id" 2>/dev/null || true)"
  [[ -n "$id" ]] || return 1
  gh api --method DELETE "repos/$ORG/$repo/rulesets/$id" >/dev/null
}

case "$mode" in
  apply)
    gh api "repos/$ORG/$SOURCE_REPO/contents/$REQUIRED_PATH?ref=${REQUIRED_REF#refs/heads/}" --jq '.sha' >/dev/null \
      || { echo "required workflow missing on $REQUIRED_REF in $SOURCE_REPO — merge it first" >&2; exit 1; }

    # apply order (idempotent; safe to re-run):
    #   1. create/update the org ruleset — protection is enabled FIRST so main is
    #      never unprotected; the new required workflow immediately becomes the
    #      producer of `validate / validate`.
    #   2. delete the per-repo rulesets (now redundant — the org ruleset carries the
    #      same required check + branch rules).
    #   3. retire the per-repo dispatcher files (the old producer of the check).
    #   4. enforce the per-repo `allow_auto_merge` setting.
    # The brief overlap between steps 1 and 3 is the accepted cost: existing check
    # runs are unaffected, so no open PR loses its green; only a PR that is PUSHED
    # inside the window could momentarily carry two `validate / validate` runs, and
    # a re-push clears it (the #38 duplicate-check lesson). `set -e` stops the run
    # on any failure, and every step is re-runnable.
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
      delete_repo_ruleset "$repo" && echo "$repo: removed redundant per-repo ruleset" || true
    done

    for repo in "${repos[@]}"; do
      has_dispatcher "$repo" || continue
      retire_dispatcher "$repo" && echo "$repo: retired dispatcher"
    done

    for repo in "${repos[@]}"; do
      ensure_auto_merge "$repo"
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
      echo "$state" | jq -e '[.rules[].type] | index("non_fast_forward") != null and index("deletion") != null and index("creation") != null' >/dev/null \
        || { echo "org ruleset is missing a branch-protection rule" >&2; fail=1; }
      echo "$state" | jq -e --argjson app "$APP_ID" \
        '[.bypass_actors[]|select(.actor_id==$app)] | length > 0' >/dev/null \
        || { echo "org ruleset is missing the $APP_SLUG app bypass" >&2; fail=1; }
    fi
    for repo in "${repos[@]}"; do
      id="$(gh api "repos/$ORG/$repo/rulesets" \
        --jq ".[] | select(.name == \"$REPO_RULESET_NAME\") | .id" 2>/dev/null || true)"
      [[ -z "$id" ]] || { echo "$repo: redundant per-repo ruleset still present" >&2; fail=1; }
      if has_dispatcher "$repo"; then
        echo "$repo: per-repo dispatcher still present" >&2; fail=1
      fi
      auto="$(gh api "repos/$ORG/$repo" --jq '.allow_auto_merge' 2>/dev/null || true)"
      [[ "$auto" == "true" ]] || { echo "$repo: allow_auto_merge must be true" >&2; fail=1; }
    done
    [[ "$fail" == 0 ]] && echo "org-wide required workflow + main protection verified"
    exit "$fail"
    ;;
esac
