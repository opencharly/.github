#!/usr/bin/env bash
set -euo pipefail

# bootstrap-repo-main.sh — create the initial protected `main` on EMPTY org repos.
#
# THE GAP THIS CLOSES. The ONE org ruleset (scripts/org-ruleset.sh) targets
# `refs/heads/main` on `~ALL` repos and carries the ordinary branch rules
# (required status check `validate / validate`, no force-push, no deletion, no
# CREATION of new refs). A brand-new repo has no `main` yet, so EVERY path an
# operator has to create one is blocked:
#
#   * `git push origin main`            -> GH013 "Cannot create ref due to
#                                          creations being restricted"
#   * repo auto_init at create time     -> the repo's own initial commit is ALSO
#                                          blocked; the repo stays empty (the
#                                          default-branch NAME is set, no ref exists)
#   * `POST branches/{b}/rename` to main -> 422 "repository rules do not permit
#                                          renaming branch ... to 'main'"
#   * `PUT /repos/.../contents/...`      -> TWO measured outcomes, by repo state:
#         - repo with NO refs at all     -> 409 "Cannot create ref due to
#                                          creations being restricted" (the creation
#                                          rule blocks the first ref; measured on an
#                                          empty repo, with and without `branch=main`)
#         - repo WITH other refs but no
#           `main`, `branch=main` given  -> 404 "Branch main not found" (the contents
#                                          API looks the branch up before the creation
#                                          rule; measured on a repo with one
#                                          `feat/...` ref)
#       Either way the first `main` cannot be created through the contents API.
#
# The ruleset's ONLY bypass actor is the `charly-auto-merge` App. A repo with no
# `main` is also a repo on which the required workflow can never run (the workflow
# file does not exist on the default branch), so the required check can never be
# produced — a genuine deadlock. The App is the one actor that can create the ref,
# exactly as it is the one actor that can commit the CHANGELOG on a protected
# `main` (the retire-per-repo-dispatchers.sh precedent).
#
# WHY THE GIT-DATA API, NOT THE CONTENTS API. The contents API cannot create the
# FIRST `main` at all (measured: 409 on a repo with no refs, 404 on a repo with
# other refs but no `main`) — so it cannot create the first ref. `POST /git/refs`
# creates a ref from an existing commit SHA with no such precondition — the App
# token creates `refs/heads/main` pointing at the repo's current default-branch HEAD
# (the operator's already-pushed `feat/...` branch). The operator then sets the
# repo's default branch to `main` (a repo-settings PATCH, which needs the operator's
# admin token — the App token gets 403 "Resource not accessible by integration"
# there; measured).
#
# NON-DESTRUCTIVE: an existing `main` is left UNTOUCHED (skipped), so a re-run is
# a no-op and this can never move a protected branch. A repo with NO non-main ref
# to point `main` at is SKIPPED with a clear message (push a commit first).
#
# usage: GH_TOKEN=<app with contents:write> [OPENCHARLY_ORG=opencharly] $0 [<repo> ...]
#   With no repo arguments it bootstraps EVERY org repo that has no `main` ref.
#   For each repo it creates `main` for, it ALSO installs the per-repo tag-on-merge caller on
#   that branch (asserted by reading the file back) and prints the three repository SETTINGS
#   the App token cannot set — until those are applied the repo sits outside the org gate
#   (#180). The final line reports them as `needs_operator_settings=<n>`.

readonly MAX_FAILURES="${BOOTSTRAP_MAX_FAILURES:-20}"

# shellcheck source=lib-org.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-org.sh"

command -v gh >/dev/null
[[ -n "${GH_TOKEN:-}" ]] || { echo "GH_TOKEN is required (the bypass-actor App token)" >&2; exit 1; }

# The CANONICAL per-repo dispatcher this script installs on a freshly bootstrapped `main`.
# It is THIS repo's own template — the same file the org's `check-action-runtimes.py` audits,
# so a new repo starts on the pinned immutable Node 24 action rather than on a stale copy
# (measured 2026-10-12: the ~438 per-repo copies in the org still carry the mutable
# `actions/github-script@v7`; that drift is filed separately and is NOT repaired here).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALLER_TEMPLATE="$HERE/../.github/workflows/tag-on-merge-dispatcher.yml"
[[ -f "$CALLER_TEMPLATE" ]] || { echo "missing caller template: $CALLER_TEMPLATE" >&2; exit 1; }
CALLER_PATH=".github/workflows/tag-on-merge.yml"

# all_repos — every non-archived, non-fork org repo (INDEPENDENT of whether it has
# a main ref — discover_repos filters on defaultBranchRef==main and would exclude
# exactly the empty repos this script exists for).
all_repos() {
  gh repo list "$ORG" --limit 1000 \
    --json name,isArchived,isFork \
    --jq '.[] | select(.isArchived == false and .isFork == false) | .name' \
    | sed '/^$/d' | sort
}

# first_other_ref <repo> — the SHA of any non-main branch to seed `main` from.
# Prefers the repo's default branch when it is not `main`. Prints nothing + returns
# 1 when the repo has no other ref (nothing to point main at).
first_other_ref() {
  local repo="$1" default sha
  default="$(gh api "repos/$ORG/$repo" --jq .default_branch 2>/dev/null || true)"
  if [[ -n "$default" && "$default" != "main" ]]; then
    if sha="$(gh api "repos/$ORG/$repo/git/ref/heads/$default" --jq .object.sha 2>/dev/null)"; then
      # Only a COMMIT can seed a branch (a tag object cannot).
      [[ -n "$sha" ]] && { printf '%s\n' "$sha"; return 0; }
    fi
  fi
  # Fall back to any branch that is not main.
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    local branch="${ref#refs/heads/}"
    [[ "$branch" == "main" ]] && continue
    if sha="$(gh api "repos/$ORG/$repo/git/ref/heads/$branch" --jq .object.sha 2>/dev/null)"; then
      [[ -n "$sha" ]] && { printf '%s\n' "$sha"; return 0; }
    fi
  done < <(gh api "repos/$ORG/$repo/git/matching-refs/heads" --jq '.[].ref' 2>/dev/null || true)
  return 1
}

# install_tag_caller <repo> — put the org's CURRENT per-repo tag-on-merge dispatcher on the
# repo's `main` via the contents API, which the App CAN do (its installation carries
# `contents: write`, and commits to protected `main` are what its ruleset bypass exists for —
# the same capability the `tag-on-merge` reusable already uses to write `CHANGELOG/<CalVer>.md`).
#
# WHY IT MATTERS (opencharly/.github#180): `tag-on-merge.yml` arrives with the repo's first
# PR in the manual flow, and neither of its triggers can fire for that FIRST merge — the
# `workflow_run` of `charly/pr-validator` completed before the file existed on `main`, and
# GitHub creates ZERO runs for an auto-merge squash — so a new repo's first landing silently
# gets no tag and no CHANGELOG. Installing the caller at bootstrap time, before any PR
# exists, is what makes the first merge tag.
#
# Idempotent: an existing file is left untouched. The post-condition is ASSERTED by reading
# the file back, so a silent failure to install can never read as success.
install_tag_caller() {
  local repo="$1" b64 out sha
  b64="$(base64 -w0 "$CALLER_TEMPLATE")"
  if gh api "repos/$ORG/$repo/contents/$CALLER_PATH?ref=main" --jq .sha >/dev/null 2>&1; then
    echo "$repo: $CALLER_PATH already present — untouched"
    return 0
  fi
  if ! out="$(gh api --method PUT "repos/$ORG/$repo/contents/$CALLER_PATH" \
      -f message="ci: install the org tag-on-merge dispatcher (opencharly/.github#180)" \
      -f content="$b64" -f branch=main --jq .commit.sha 2>&1)"; then
    echo "ERROR: $repo could not install $CALLER_PATH: $out" >&2
    return 1
  fi
  if ! sha="$(gh api "repos/$ORG/$repo/contents/$CALLER_PATH?ref=main" --jq .sha 2>/dev/null)" || [[ -z "$sha" ]]; then
    echo "ERROR: $repo reported commit $out for $CALLER_PATH but the read-back found nothing on main" >&2
    return 1
  fi
  echo "$repo: installed $CALLER_PATH (blob $sha)"
  return 0
}

# operator_remedy <repo>… — the three repository SETTINGS the App cannot make, with the exact
# commands. The App's installation carries no `administration` permission (measured live:
# permissions are actions/contents/deployments/issues/merge_queues/metadata/packages/pages/
# pull_requests/repository_custom_properties/workflows — never administration), so
# `PATCH /repos/...` is 403 "Resource not accessible by integration". Until these are set the
# repo is OUTSIDE the org gate: no required `validate / validate`, no CalVer tag, no CHANGELOG.
# `org-ruleset.sh verify` now FAILS on that state rather than reporting a clean org.
operator_remedy() {
  local repo
  [[ $# -gt 0 ]] || return 0
  echo
  echo "OPERATOR ACTION REQUIRED — the App token cannot set repository settings:" >&2
  for repo in "$@"; do
    echo "  gh api --method PATCH repos/$ORG/$repo -f default_branch=main" >&2
    echo "  gh api --method PATCH repos/$ORG/$repo -f allow_auto_merge=true" >&2
    echo "  gh api --method PATCH repos/$ORG/$repo -f delete_branch_on_merge=true" >&2
  done
  echo "  (verify refuses a clean membership until default_branch is main — opencharly/.github#180)" >&2
}

if [[ $# -gt 0 ]]; then
  repos=("$@")
else
  if ! repos_out="$(all_repos)"; then echo "FATAL: gh repo list failed" >&2; exit 1; fi
  [[ -n "$repos_out" ]] || { echo "no active repositories discovered for $ORG" >&2; exit 1; }
  mapfile -t repos <<<"$repos_out"
fi

created=0 skipped=0 failed=0
needs_settings=()
for repo in "${repos[@]}"; do
  # Already has main? Never move a protected branch.
  if gh api "repos/$ORG/$repo/git/ref/heads/main" --jq .object.sha >/dev/null 2>&1; then
    echo "$repo: main exists — skipped"
    skipped=$((skipped+1))
    continue
  fi

  if ! seed="$(first_other_ref "$repo")"; then
    echo "$repo: no non-main ref to seed main from (push a commit first) — skipped"
    skipped=$((skipped+1))
    continue
  fi

  # Create refs/heads/main from the seed SHA. The App token is the ruleset bypass
  # actor, so this is permitted where an operator push is not.
  if resp="$(gh api --method POST "repos/$ORG/$repo/git/refs" \
      -f ref=refs/heads/main -f sha="$seed" --jq '.ref' 2>&1)"; then
    echo "$repo: created refs/heads/main -> $seed"
    created=$((created+1))
    # The ref is not enough: install the tag-on-merge dispatcher on it (so the FIRST
    # merge can be tagged) and record the settings the App cannot set for the operator.
    if install_tag_caller "$repo"; then
      needs_settings+=("$repo")
    else
      failed=$((failed+1))
      [[ "$failed" -gt "$MAX_FAILURES" ]] && { echo "too many failures — aborting" >&2; exit 1; }
    fi
  else
    echo "ERROR: $repo create refs/heads/main failed: $resp" >&2
    failed=$((failed+1))
    [[ "$failed" -gt "$MAX_FAILURES" ]] && { echo "too many failures — aborting" >&2; exit 1; }
  fi
done

operator_remedy "${needs_settings[@]+"${needs_settings[@]}"}"
echo "bootstrap-repo-main: created=$created absent_or_seeded=$skipped failed=$failed needs_operator_settings=${#needs_settings[@]}"
[[ "$failed" -eq 0 ]]
