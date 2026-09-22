#!/usr/bin/env bash
# lib-org.sh — shared helpers for the org-wide cutover scripts
# (org-ruleset.sh and retire-per-repo-dispatchers.sh). SOURCE this file; do not run.
#
# Every read here runs under the CALLER's `set -e`, and the two `mapfile ... < <(...)`
# discoveries additionally assert the `gh repo list` call SUCCEEDED — a failure inside
# the process substitution is otherwise invisible to `set -e` (the subshell's status is
# not propagated and `mapfile` returns 0 on empty input), so a 401/403/rate-limit/
# network error would silently yield an EMPTY list. For `repos` that would abort on the
# count guard; for `excludes` it would build `exclude: []` and apply the ruleset to
# forks/archived repos too. Both are guarded below.

readonly ORG="${OPENCHARLY_ORG:-opencharly}"
readonly SOURCE_REPO=".github"
readonly DISPATCHER_PATH=".github/workflows/pr-validator.yml"
readonly SOURCE_DISPATCHER_PATH=".github/workflows/pr-validator-dispatcher.yml"

# discover_repos — active, non-fork, `main`-default repos (the target set).
discover_repos() {
  local out
  out="$(gh repo list "$ORG" --limit 1000 \
    --json name,isArchived,isFork,defaultBranchRef \
    --jq '.[] | select(.isArchived == false and .isFork == false and .defaultBranchRef.name == "main") | .name')" \
    || { echo "FATAL: gh repo list (targets) failed" >&2; exit 1; }
  printf '%s\n' "$out" | sed '/^$/d' | sort
}

# discover_excludes — everything NOT in the target set (archived, fork, non-main).
discover_excludes() {
  local out
  out="$(gh repo list "$ORG" --limit 1000 \
    --json name,isArchived,isFork,defaultBranchRef \
    --jq '.[] | select((.isArchived == true) or (.isFork == true) or (.defaultBranchRef.name != "main")) | .name')" \
    || { echo "FATAL: gh repo list (excludes) failed" >&2; exit 1; }
  printf '%s\n' "$out" | sed '/^$/d' | sort
}

# dispatcher_path_for <repo> — the SOURCE repo uses the `-dispatcher.yml` stub.
dispatcher_path_for() {
  [[ "$1" == "$SOURCE_REPO" ]] && echo "$SOURCE_DISPATCHER_PATH" || echo "$DISPATCHER_PATH"
}

# api_status <path> — the HTTP status of a GET; 000 on a transport/other failure.
api_status() {
  local resp
  resp="$(gh api --include "$1" 2>&1 || true)"
  printf '%s\n' "$resp" | awk 'NR==1 { print $2; exit }'
}
