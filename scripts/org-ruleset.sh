#!/usr/bin/env bash
set -euo pipefail

# org-ruleset.sh — the SINGLE OWNER of the org-wide PR-validator configuration, the
# main-branch protection, and the per-repo settings, applied from TWO org rulesets built
# by ONE payload builder.
#
# THE ONE ORG-LEVEL SPEC, TWO SCOPES. On GitHub Team an organization branch ruleset can
# carry BOTH the `workflows` rule ("Require workflows to pass", naming a workflow in
# ANOTHER repo at a pinned ref) AND the ordinary branch rules (required status checks, no
# force-push, no deletion, no creation). The rules are identical for every repo; only the
# repository condition and the ref differ:
#   A — the existing ruleset: active non-fork `main`-default repos, refs/heads/main;
#   B — the fork ruleset: the active FORKS, ref ~DEFAULT_BRANCH (a fork may keep upstream's
#       `stable`/`master` as its default).
# Both carry the `workflows` rule naming the SAME required workflow, so a fork's
# `validate / validate` is produced by opencharly/.github's own required workflow — NO
# per-fork caller is copied into the repository. That is the point of B: reuse the org's
# config instead of distributing copies of it.
#
# WHY B IS SCOPED TO THE FORKS EXPLICITLY. The `workflows` rule blocks DIRECT PUSHES
# (measured, opencharly/.github#179: a user-token `gh repo sync` fails with "Required
# workflow … is not satisfied"). Forks are vendored upstreams kept in step by a
# fast-forward sync, so the fork sync runs through the charly-auto-merge App (the ruleset
# bypass actor) via .github/workflows/sync-forks.yml. A required-status-check rule gates
# MERGES, not pushes, so the branch rules themselves are safe on a fork.
#
# THE PER-FORK FILES. The ONLY per-fork file is the canonical tag-on-merge caller
# (`.github/workflows/tag-on-merge.yml`), because GitHub has no org-level post-merge
# mechanism; it is installed and reconciled by reconcile-tag-on-merge-callers.yml
# (SCOPE=forks). A leftover per-fork `pr-validator.yml` is a DUPLICATE PRODUCER, and this
# script REFUSES to apply until retire-per-repo-dispatchers.yml (SCOPE=forks) removed it.
# Nothing else is copied into a fork.
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
readonly FORK_RULESET_NAME="fork required workflow & main protection"
readonly REPO_RULESET_NAME="main branch protection"
readonly REQUIRED_PATH=".github/workflows/org-wide-pr-validator-required.yml"
readonly REQUIRED_REF="${REQUIRED_REF:-refs/heads/main}"
readonly CONTEXT="validate / validate"
readonly APP_SLUG="charly-auto-merge"
# ~DEFAULT_BRANCH covers main, master and stable in one pattern, and keeps covering a fork
# that later renames its default. The fork set's defaults are asserted to be one of those
# three, so the pattern can never silently protect an artifact branch.
readonly FORK_REFS='["~DEFAULT_BRANCH"]'
readonly FORK_CALLER_PATH=".github/workflows/tag-on-merge.yml"

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
repos_out="$(discover_repos)" || { echo "FATAL: repo discovery (targets) failed" >&2; exit 1; }
[[ -n "$repos_out" ]] || { echo "no active repositories discovered for $ORG" >&2; exit 1; }
mapfile -t repos <<<"$repos_out"

# EXCLUDE set for the org ruleset's `repository_name` condition: everything that is
# NOT a target (archived, fork, or a non-`main` default branch). `~ALL` targets every
# repo, so the non-targets must be named out explicitly to mirror the old scope. An
# API failure here (an empty result is legitimate, so emptiness is NOT the signal) is
# fatal — otherwise `exclude` would be `[]` and the ruleset would target forks and
# archived repos too.
excludes_out="$(discover_excludes)" || { echo "FATAL: repo discovery (excludes) failed" >&2; exit 1; }
# An empty exclude set is LEGITIMATE (no forks/archived repos), so it must produce an
# EMPTY array — not `mapfile <<<"$empty"`, which yields one empty element and would
# emit `[""]` (targeting a repo named "") instead of `[]`.
excludes=()
if [[ -n "$excludes_out" ]]; then mapfile -t excludes <<<"$excludes_out"; fi

# FORK set: active forks as `<name>\t<default>`. An empty set is legitimate (an org with no
# forks) and must NOT be a failure signal — only the discovery STATUS is. The ruleset
# condition needs the names; the default branch is needed to probe legacy protection and to
# assert the ref pattern covers it.
forks_out="$(discover_forks)" || { echo "FATAL: repo discovery (forks) failed" >&2; exit 1; }
forks=()
fork_names=()
if [[ -n "$forks_out" ]]; then
  while IFS=$'\t' read -r fname fdefault; do
    [[ -z "$fname" ]] && continue
    forks+=("$fname"$'\t'"$fdefault")
    fork_names+=("$fname")
  done <<<"$forks_out"
fi
exclude_json() { json_string_list "${excludes[@]}"; }

# ruleset_payload <name> <repository-include-json> <repository-exclude-json> <refs-json>
# THE ONE BUILDER for both org rulesets (R2). The rules — the required workflow, the strict
# required check, the branch protections and the App bypass — are identical; only the
# repository condition, the ref and the name are parameters.
ruleset_payload() {
  local name="$1" repo_include="$2" repo_exclude="$3" refs="$4"
  cat <<JSON
{
  "name": "$name",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "repository_name": {"include": $repo_include, "exclude": $repo_exclude, "protected": false},
    "ref_name": {"include": $refs, "exclude": []}
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

ruleset_id_by_name() {
  gh api "orgs/$ORG/rulesets" \
    --jq ".[] | select(.name == \"$1\") | .id"
}

existing_id() { ruleset_id_by_name "$RULESET_NAME"; }

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

# verify_ruleset_common <label> <state-json> <repository-include-json> <repository-exclude-json> <refs-json>
# THE ONE assertion set for BOTH org rulesets (R2). Prints each finding and returns 1 on
# any mismatch; the caller accumulates. Nothing here is A-specific: A and B differ only in
# their scope, so a rule that matters to one matters to both.
verify_ruleset_common() {
  local label="$1" state="$2" inc="$3" exc="$4" refs="$5" rc=0
  echo "$state" | jq -e '.enforcement == "active"' >/dev/null || { echo "$label: not active" >&2; rc=1; }
  echo "$state" | jq -e --argjson inc "$inc" '.conditions.repository_name.include == $inc' >/dev/null \
    || { echo "$label: repository_name.include does not match the derived set" >&2; rc=1; }
  echo "$state" | jq -e '.conditions.repository_name.protected == false' >/dev/null \
    || { echo "$label: repository_name.protected must be false" >&2; rc=1; }
  echo "$state" | jq -e --argjson exc "$exc" '.conditions.repository_name.exclude == $exc' >/dev/null \
    || { echo "$label: repository_name.exclude does not match the derived set" >&2; rc=1; }
  echo "$state" | jq -e --argjson refs "$refs" '.conditions.ref_name.include == $refs and .conditions.ref_name.exclude == []' >/dev/null \
    || { echo "$label: ref_name does not match the declared refs" >&2; rc=1; }
  echo "$state" | jq -e --arg p "$REQUIRED_PATH" \
    '[.rules[]|select(.type=="workflows")|.parameters.workflows[].path] | index($p) != null' >/dev/null \
    || { echo "$label: does not require $REQUIRED_PATH" >&2; rc=1; }
  echo "$state" | jq -e --arg ctx "$CONTEXT" \
    '[.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context] | index($ctx) != null' >/dev/null \
    || { echo "$label: does not require the '$CONTEXT' check" >&2; rc=1; }
  echo "$state" | jq -e '[.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks] | first | length == 1' >/dev/null \
    || { echo "$label: must require EXACTLY ONE check" >&2; rc=1; }
  echo "$state" | jq -e '[.rules[]|select(.type=="required_status_checks")|.parameters.strict_required_status_checks_policy] | first == true' >/dev/null \
    || { echo "$label: must be strict (head up-to-date before merge)" >&2; rc=1; }
  echo "$state" | jq -e '[.rules[].type] | index("non_fast_forward") != null and index("deletion") != null and index("creation") != null' >/dev/null \
    || { echo "$label: missing a branch-protection rule" >&2; rc=1; }
  echo "$state" | jq -e '[.rules[].type] | index("pull_request") == null' >/dev/null \
    || { echo "$label: must NOT require pull-request reviews (the validator is the gate)" >&2; rc=1; }
  echo "$state" | jq -e --argjson app "$APP_ID" \
    '[.bypass_actors[]|select(.actor_id==$app)] | length > 0' >/dev/null \
    || { echo "$label: missing the $APP_SLUG app bypass" >&2; rc=1; }
  echo "$state" | jq -e '[.bypass_actors[]|select(.actor_type=="OrganizationAdmin")] | length == 0' >/dev/null \
    || { echo "$label: must not add a human bypass" >&2; rc=1; }
  return "$rc"
}

case "$mode" in
  apply)
    # The required workflow must exist on the pinned ref the ruleset names.
    gh api "repos/$ORG/$SOURCE_REPO/contents/$REQUIRED_PATH?ref=${REQUIRED_REF#refs/heads/}" --jq .sha >/dev/null \
      || { echo "required workflow missing on $REQUIRED_REF in $SOURCE_REPO — merge it first" >&2; exit 1; }

    # apply order (idempotent; safe to re-run):
    #   1. FORKS FIRST: set their per-repo settings, refuse a surviving duplicate
    #      producer, remove every non-canonical repo-scoped branch ruleset and any legacy
    #      protection on the fork's DEFAULT branch. A fork's allow_auto_merge must be true
    #      BEFORE the required check exists, or an approved PR renders as a FAILED check
    #      (opencharly/.github#212).
    #   2. refuse while any TARGET repo still carries a dispatcher (the #38 POISON).
    #   3. create/update ruleset A for the non-fork `main`-default targets.
    #   4. delete the target per-repo rulesets, remove legacy protection, set settings.
    #   5. create/update ruleset B for the forks from the SAME payload builder. No active
    #      forks -> delete B rather than leave a ruleset targeting nothing.
    for entry in "${forks[@]+"${forks[@]}"}"; do
      repo="${entry%%$'\t'*}"
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
      # Mirror the org targets: allow_update_branch is false there, so it is false here.
      aub="$(gh api "repos/$ORG/$repo" --jq '.allow_update_branch')"
      if [[ "$aub" != "false" ]]; then
        gh api --method PATCH "repos/$ORG/$repo" -f allow_update_branch=false --jq .allow_update_branch >/dev/null
        echo "$repo: aligned allow_update_branch=false with the org targets"
      fi
    done

    fork_stragglers=0
    for entry in "${forks[@]+"${forks[@]}"}"; do
      repo="${entry%%$'\t'*}"
      has_dispatcher "$repo" && { echo "REFUSING: $repo still carries a per-fork validator copy" >&2; fork_stragglers=$((fork_stragglers+1)); }
    done
    if [[ "$fork_stragglers" != 0 ]]; then
      echo "retire them first: gh workflow run retire-per-repo-dispatchers.yml -f scope=forks" >&2
      exit 1
    fi

    for entry in "${forks[@]+"${forks[@]}"}"; do
      repo="${entry%%$'\t'*}"; fdefault="${entry##*$'\t'}"
      fork_ruleset_ids_raw="$(gh api "repos/$ORG/$repo/rulesets" --jq '.[].id')" \
        || { echo "FATAL: $repo repo-rulesets read failed" >&2; exit 1; }
      fork_ruleset_ids=()
      [[ -n "$fork_ruleset_ids_raw" ]] && mapfile -t fork_ruleset_ids <<<"$fork_ruleset_ids_raw"
      for rid in "${fork_ruleset_ids[@]+"${fork_ruleset_ids[@]}"}"; do
        [[ -z "$rid" ]] && continue
        tgt="$(gh api "repos/$ORG/$repo/rulesets/$rid" --jq .target)"
        case "$tgt" in
          branch)
            gh api --method DELETE "repos/$ORG/$repo/rulesets/$rid" >/dev/null
            echo "$repo: removed non-canonical repo ruleset $rid" ;;
          tag)
            echo "$repo: keeping tag-target repo ruleset $rid" ;;
          *)
            echo "FATAL: $repo repo ruleset $rid has an unclassifiable target '$tgt'" >&2; exit 1 ;;
        esac
      done
      legacy="$(api_status "repos/$ORG/$repo/branches/$fdefault/protection")"
      case "$legacy" in
        404) ;;
        200)
          gh api --method DELETE "repos/$ORG/$repo/branches/$fdefault/protection" >/dev/null
          echo "$repo: removed legacy branch protection on $fdefault" ;;
        *) echo "FATAL: $repo legacy-protection probe on $fdefault -> HTTP $legacy" >&2; exit 1 ;;
      esac
    done

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
      gh api --method PUT "orgs/$ORG/rulesets/$id" --input <(ruleset_payload "$RULESET_NAME" '["~ALL"]' "$(exclude_json)" '["refs/heads/main"]') --jq .id >/dev/null
      echo "org ruleset updated ($id)"
    else
      id="$(gh api --method POST "orgs/$ORG/rulesets" --input <(ruleset_payload "$RULESET_NAME" '["~ALL"]' "$(exclude_json)" '["refs/heads/main"]') --jq .id)"
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

    fid="$(ruleset_id_by_name "$FORK_RULESET_NAME")"
    if [[ "${#fork_names[@]}" -eq 0 ]]; then
      if [[ -n "$fid" ]]; then
        gh api --method DELETE "orgs/$ORG/rulesets/$fid" >/dev/null
        echo "fork ruleset deleted (no active forks)"
      fi
    elif [[ -n "$fid" ]]; then
      gh api --method PUT "orgs/$ORG/rulesets/$fid" --input <(ruleset_payload "$FORK_RULESET_NAME" "$(json_string_list "${fork_names[@]}")" '[]' "$FORK_REFS") --jq .id >/dev/null
      echo "fork ruleset updated ($fid)"
    else
      fid="$(gh api --method POST "orgs/$ORG/rulesets" --input <(ruleset_payload "$FORK_RULESET_NAME" "$(json_string_list "${fork_names[@]}")" '[]' "$FORK_REFS") --jq .id)"
      echo "fork ruleset created ($fid)"
    fi
    ;;
  verify)
    fail=0
    id="$(existing_id)"
    [[ -n "$id" ]] || { echo "no org ruleset named '$RULESET_NAME'" >&2; fail=1; }
    if [[ -n "$id" ]]; then
      state="$(gh api "orgs/$ORG/rulesets/$id")"
      # A's scope is `~ALL` minus the derived non-targets, on refs/heads/main.
      verify_ruleset_common "org ruleset" "$state" '["~ALL"]' "$(exclude_json)" '["refs/heads/main"]' || fail=1
    fi

    fid="$(ruleset_id_by_name "$FORK_RULESET_NAME")"
    if [[ "${#fork_names[@]}" -eq 0 ]]; then
      [[ -z "$fid" ]] || { echo "fork ruleset must be absent when there are no active forks" >&2; fail=1; }
    else
      [[ -n "$fid" ]] || { echo "no fork ruleset named '$FORK_RULESET_NAME'" >&2; fail=1; }
      if [[ -n "$fid" ]]; then
        state="$(gh api "orgs/$ORG/rulesets/$fid")"
        # B's scope is the EXPLICIT fork set (never ~ALL), on ~DEFAULT_BRANCH, with the
        # SAME rules as A — including the workflows rule.
        verify_ruleset_common "fork ruleset" "$state" "$(json_string_list "${fork_names[@]}")" '[]' "$FORK_REFS" || fail=1
      fi
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

    # THE FORK SET. The same contract, judged over discover_forks: the ruleset covers it,
    # no repo-scoped branch ruleset survives (#225's blind spot, now read over the fork
    # set), the tag-on-merge caller is present, the settings hold, and no legacy protection
    # survives on the fork's DEFAULT branch (which is not `main` for three today).
    for entry in "${forks[@]+"${forks[@]}"}"; do
      repo="${entry%%$'\t'*}"; fdefault="${entry##*$'\t'}"
      case "$fdefault" in
        main|master|stable) ;;
        *) echo "$repo: default branch '$fdefault' is not main/master/stable — the ~DEFAULT_BRANCH fork gate cannot be trusted" >&2; fail=1 ;;
      esac
      fork_ruleset_ids_raw="$(gh api "repos/$ORG/$repo/rulesets" --jq '.[].id')" \
        || { echo "FATAL: $repo repo-rulesets read failed" >&2; fail=1; fork_ruleset_ids_raw=""; }
      fork_ruleset_ids=()
      [[ -n "$fork_ruleset_ids_raw" ]] && mapfile -t fork_ruleset_ids <<<"$fork_ruleset_ids_raw"
      for rid in "${fork_ruleset_ids[@]+"${fork_ruleset_ids[@]}"}"; do
        [[ -z "$rid" ]] && continue
        tgt="$(gh api "repos/$ORG/$repo/rulesets/$rid" --jq .target)"
        case "$tgt" in
          branch) echo "$repo: repo-scoped branch ruleset $rid still present" >&2; fail=1 ;;
          tag)    echo "$repo: tag-target repo ruleset $rid (kept)" ;;
          *)      echo "$repo: unclassifiable repo ruleset $rid target=$tgt" >&2; fail=1 ;;
        esac
      done
      code="$(api_status "repos/$ORG/$repo/contents/$FORK_CALLER_PATH")"
      case "$code" in
        200) ;;
        404) echo "$repo: no tag-on-merge caller ($FORK_CALLER_PATH)" >&2; fail=1 ;;
        *) echo "FATAL: $repo caller probe -> HTTP $code" >&2; fail=1 ;;
      esac
      auto="$(gh api "repos/$ORG/$repo" --jq '.allow_auto_merge')"
      [[ "$auto" == "true" ]] || { echo "$repo: allow_auto_merge must be true" >&2; fail=1; }
      dbom="$(gh api "repos/$ORG/$repo" --jq '.delete_branch_on_merge')"
      [[ "$dbom" == "true" ]] || { echo "$repo: delete_branch_on_merge must be true" >&2; fail=1; }
      aub="$(gh api "repos/$ORG/$repo" --jq '.allow_update_branch')"
      [[ "$aub" == "false" ]] || { echo "$repo: allow_update_branch must be false (mirrors the org targets)" >&2; fail=1; }
      legacy="$(api_status "repos/$ORG/$repo/branches/$fdefault/protection")"
      [[ "$legacy" == "404" ]] || { echo "$repo: legacy branch protection still present on $fdefault (HTTP $legacy)" >&2; fail=1; }
    done

    # AN ARCHIVED FORK IS NOT A LANDING TARGET, and must be NAMED rather than look skipped.
    archived_forks="$(discover_archived_forks)" || { echo "FATAL: archived-fork discovery failed" >&2; fail=1; }
    for f in $archived_forks; do
      [[ -n "$f" ]] && echo "$f: archived fork — outside the fork gate (no pushes, no PRs)"
    done

    # MEMBERSHIP INTEGRITY (opencharly/.github#180). The loop above asserts the contract
    # over the TARGET set — and the target set is DEFINED by `defaultBranchRef == "main"`,
    # so a repo that keeps a non-`main` default is silently outside it: no required
    # `validate / validate` check, no CalVer tag, no CHANGELOG — and this verify, iterating
    # the target set, could never say so. Measured on the live org while this arm was
    # written: `plugin-task-old-16365` and `plugin-task-zzbootstrap` default to
    # `feat/plugin-task` and carry ZERO rules on `main`, where `charly` carries five.
    #
    # THIS ARM'S SCOPE IS THE NON-FORK SET. A fork is gated by ruleset B and judged by the
    # fork loop above, NOT here; an archived repo is excluded (computed, never declared). A
    # non-`main` default in this set is a defect UNLESS it is declared with a reason in
    # lib-org.sh's declared_non_main_defaults(). The read is STATUS-CHECKED before the
    # loop: under `set -e` a failed discovery behind a process substitution feeds the
    # loop nothing and would read as a clean membership — the silent pass this arm exists
    # to prevent.
    #
    # It goes through lib-org.sh's discover_membership, i.e. the SAME paged, count-checked
    # discovery the target set uses (opencharly/.github#290). It used its own
    # `gh repo list --limit 1000`, which was the listing that 502s at this org's size — so
    # this arm could fail on its own while the rest of the run succeeded, and the two
    # reads could disagree about which repos exist.
    if ! membership="$(discover_membership)"; then
      echo "org membership: the repo listing FAILED — refusing to report a clean membership from a failed read" >&2
      fail=1
    else
      declared="$(declared_non_main_defaults | awk -F'\t' '!/^#/ && NF {print $1}')"
      while IFS=$'\t' read -r mrepo mdefault; do
        [[ -z "$mrepo" ]] && continue
        [[ "$mdefault" == "main" ]] && continue
        # An EMPTY repo has no refs at all: the GraphQL `defaultBranchRef` is `{"name":""}`
        # (measured on `zz-probe3-7319`), so the value arrives EMPTY, not "null". It cannot
        # merge anything, so the gate's absence has no consequence until it has a branch —
        # and the moment it does, this arm fails. Named, never silently skipped.
        if [[ -z "$mdefault" ]]; then
          echo "$mrepo: no default branch yet (empty repo) — outside the gate until it has one"
          continue
        fi
        if grep -qx -- "$mrepo" <<<"$declared"; then
          echo "$mrepo: default branch '$mdefault' — declared by design"
          continue
        fi
        # The remedy depends on whether there is a `main` to default TO: a repo that was
        # never bootstrapped has no such ref, so the PATCH alone would fail.
        if gh api "repos/$ORG/$mrepo/git/ref/heads/main" --jq .object.sha >/dev/null 2>&1; then
          echo "$mrepo: default branch is '$mdefault' but a 'main' ref exists — it is in discover_excludes: NO required validate/validate check and NO CalVer tag. Fix: gh api --method PATCH repos/$ORG/$mrepo -f default_branch=main" >&2
        else
          echo "$mrepo: default branch is '$mdefault' and there is NO 'main' ref — the repo was never bootstrapped (no required validate/validate check, no CalVer tag). Fix: run scripts/bootstrap-repo-main.sh (the App creates the ref), then PATCH default_branch=main; archive it instead if it is not a landing target" >&2
        fi
        fail=1
      done <<<"$membership"
    fi

    [[ "$fail" == 0 ]] && echo "org-wide + fork required workflow, protection and settings verified"
    exit "$fail"
    ;;
esac
