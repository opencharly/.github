#!/usr/bin/env bash
# lib-org.sh — shared helpers for the org-wide cutover scripts
# (org-ruleset.sh and retire-per-repo-dispatchers.sh). SOURCE this file; do not run.
#
# IMPORTANT — how discovery failures are surfaced. The discovery functions RETURN a
# non-zero status on failure and print NOTHING; callers must invoke them via command
# substitution and check the status:
#
#     if ! out="$(discover_repos)"; then echo FATAL >&2; exit 1; fi
#     mapfile -t repos <<<"$out"
#
# A guard placed INSIDE a `mapfile ... < <(fn)` process substitution is dead: the
# subshell's exit status is not propagated and `mapfile` returns 0 on empty input, so
# a 401/403/rate-limit/network failure would silently yield an EMPTY list. For the
# exclude set (legitimately empty when there are no forks/archived repos) emptiness is
# not a failure signal — only the exit status is. Hence the status is checked at the
# call site, under `set -o pipefail`.

readonly ORG="${OPENCHARLY_ORG:-opencharly}"
readonly SOURCE_REPO=".github"
readonly DISPATCHER_PATH=".github/workflows/pr-validator.yml"
readonly SOURCE_DISPATCHER_PATH=".github/workflows/pr-validator-dispatcher.yml"

# discover_repos — active, non-fork, `main`-default repos (the target set).
discover_repos() {
  gh repo list "$ORG" --limit 1000 \
    --json name,isArchived,isFork,defaultBranchRef \
    --jq '.[] | select(.isArchived == false and .isFork == false and .defaultBranchRef.name == "main") | .name' \
    | sed '/^$/d' | sort
}

# discover_excludes — everything NOT in the target set (archived, fork, non-main).
discover_excludes() {
  gh repo list "$ORG" --limit 1000 \
    --json name,isArchived,isFork,defaultBranchRef \
    --jq '.[] | select((.isArchived == true) or (.isFork == true) or (.defaultBranchRef.name != "main")) | .name' \
    | sed '/^$/d' | sort
}

# dispatcher_path_for <repo> — the SOURCE repo uses the `-dispatcher.yml` stub.
dispatcher_path_for() {
  [[ "$1" == "$SOURCE_REPO" ]] && echo "$SOURCE_DISPATCHER_PATH" || echo "$DISPATCHER_PATH"
}

# api_status <path> — the HTTP status of a GET; empty on a transport/other failure.
api_status() {
  local resp
  resp="$(gh api --include "$1" 2>&1 || true)"
  printf '%s\n' "$resp" | awk 'NR==1 { print $2; exit }'
}
