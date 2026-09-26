#!/usr/bin/env bash
set -euo pipefail

# distribute-rerun-listener.sh — install the `rerun`-label listener into every repo, in ONE
# org-wide pass.
#
# WHY A DISTRIBUTOR (not the org required workflow). The org gate is a REQUIRED workflow (the
# org ruleset `workflows` rule). MEASURED: a required workflow acts ONLY on the default
# push-driven pull_request types (`opened`/`synchronize`/`reopened`) and IGNORES `on.types`
# for anything else — a body edit did NOT fire it even with `edited` listed, and a
# draft->ready transition did NOT fire it even with `ready_for_review` listed (which was
# already there). A PLAIN per-repo workflow with the same `types:` DOES fire, so the
# `rerun`-label listener MUST be a plain per-repo file — it cannot live in the required
# workflow, and the required workflow cannot be made to see `labeled`.
#
# WHAT IT INSTALLS. `.github/workflows/rerun-listener.yml`, copied VERBATIM from the repo-root
# source `org-wide-rerun-listener.yml`. Adding a `rerun` label to a PR re-runs this head's
# FAILED `charly/pr-validator` run; a re-run reuses the SAME GITHUB_SHA and updates THAT run's
# `validate / validate` check run IN PLACE (no duplicate same-name check run), clearing the
# POISON state and re-reading the corrected body — the sanctioned, capability-free way to
# clear a body-only BLOCK with NO empty commit.
#
# WHY IT IS A WORKFLOW: writing `.github/workflows/*` needs GitHub Apps' `workflows: write`
# permission (distinct from `contents: write`), and the commit lands on a protected `main`, so
# it must be authored by the ruleset BYPASS actor (the `charly-auto-merge` App). The calling
# workflow mints that App token and exports it as GH_TOKEN.
#
# IDEMPOTENT: an installed file with IDENTICAL content is skipped (no churn); a differing file
# is UPDATED (PUT with the current blob SHA); an absent file is CREATED. A non-2xx other than
# 404 is FATAL (never silently read as "absent").
#
# usage: GH_TOKEN=<app with contents:write + workflows:write> [OPENCHARLY_ORG=opencharly] $0

readonly MAX_FAILURES="${DISTRIBUTE_MAX_FAILURES:-20}"
readonly LISTENER_PATH=".github/workflows/rerun-listener.yml"
readonly SOURCE_LISTENER="org-wide-rerun-listener.yml"

# shellcheck source=lib-org.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-org.sh"

command -v gh >/dev/null
[[ -n "${GH_TOKEN:-}" ]] || { echo "GH_TOKEN is required (the bypass-actor App/PAT)" >&2; exit 1; }
[[ -f "$SOURCE_LISTENER" ]] || { echo "FATAL: source template $SOURCE_LISTENER not found (run from the repo root)" >&2; exit 1; }
tmpl_b64="$(base64 -w0 < "$SOURCE_LISTENER")"

repos_out="$(discover_repos)" || { echo "FATAL: gh repo list (targets) failed" >&2; exit 1; }
[[ -n "$repos_out" ]] || { echo "no active repositories discovered for $ORG" >&2; exit 1; }
mapfile -t repos <<<"$repos_out"

# listener_state <repo> — prints "<sha>\t<content_b64>" (sha empty when ABSENT). A genuine
# 404 is "absent" (install); any OTHER non-200 probe result is FATAL (never silently read as
# absent — that would attempt a CREATE PUT against an existing file).
listener_state() {
  local repo="$1" code body
  code="$(api_status "repos/$ORG/$repo/contents/$LISTENER_PATH")"
  case "$code" in
    200)
      body="$(gh api "repos/$ORG/$repo/contents/$LISTENER_PATH")"
      printf '%s\t%s\n' \
        "$(printf '%s' "$body" | jq -r '.sha // ""')" \
        "$(printf '%s' "$body" | jq -r '.content // ""' | tr -d '\n')"
      ;;
    404) printf '\t\n' ;;
    *)   echo "FATAL: $repo contents probe -> HTTP ${code:-none}" >&2; exit 1 ;;
  esac
}

created=0 updated=0 unchanged=0 failed=0
for repo in "${repos[@]}"; do
  state="$(listener_state "$repo")"
  sha="${state%%$'\t'*}"; existing_b64="${state#*$'\t'}"
  if [[ -n "$sha" && "$existing_b64" == "$tmpl_b64" ]]; then
    unchanged=$((unchanged+1)); continue
  fi
  if [[ -n "$sha" ]]; then
    args=(-f message="chore: update the rerun-listener workflow (org-wide)" -f content="$tmpl_b64" -f sha="$sha" -f branch=main)
    action="updated"
  else
    args=(-f message="chore: install the rerun-listener workflow (org-wide)" -f content="$tmpl_b64" -f branch=main)
    action="created"
  fi
  if resp="$(gh api --method PUT "repos/$ORG/$repo/contents/$LISTENER_PATH" "${args[@]}" --jq '.commit.sha' 2>&1)"; then
    echo "$repo: $action $LISTENER_PATH"
    [[ "$action" == "created" ]] && created=$((created+1)) || updated=$((updated+1))
  else
    if [[ "$resp" == *"Resource not accessible by integration"* ]]; then
      echo "FATAL: the token cannot write workflow files (403 on $repo)." >&2
      echo "The App must hold BOTH 'contents: write' (ruleset bypass) AND 'workflows: write'." >&2
      exit 1
    fi
    echo "ERROR: $repo PUT failed: $resp" >&2; failed=$((failed+1))
    [[ "$failed" -gt "$MAX_FAILURES" ]] && { echo "too many failures — aborting" >&2; exit 1; }
  fi
done
echo "created=$created updated=$updated unchanged=$unchanged failed=$failed"
[[ "$failed" == 0 ]]
