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

# list_config_paths <repo> — print `<status>` (ok | truncated | failed) then, when
# ok, every `charly.yml` blob path in the repo, ROOT OR NESTED, one per line. Uses
# the git TREES API recursively (`git/trees/main?recursive=1`) so a nested
# candy/box/tools/packaging/check/testdata manifest is discovered, not just the
# root file. Paths are the tree's blob paths (e.g. `candy/plugin-box/charly.yml`);
# the recursive listing includes testdata fixtures (e.g. charly/testdata/...), which
# is intended — the retired stamp must go from EVERY authored manifest.
#
# ALWAYS returns 0 (the caller branches on the status line):
#  - ok        — the tree was read; the paths follow (possibly none, meaning the
#                repo has no charly.yml — the caller counts it `absent`).
#  - truncated — the recursive API could not return the whole tree. This is a
#                SILENT-MISS risk: an unseen nested manifest would be left stamped.
#                The caller MUST treat it as FATAL, never as "no charly.yml".
#  - failed    — a transport/API error; a per-repo failure the wave CONTINUES past.
list_config_paths() {
  local repo="$1" json
  if ! json="$(gh api "repos/$ORG/$repo/git/trees/main?recursive=1" 2>/dev/null)"; then
    printf 'failed\n'; return 0
  fi
  if [[ "$(jq -r '.truncated // false' <<<"$json" 2>/dev/null)" == "true" ]]; then
    printf 'truncated\n'; return 0
  fi
  printf 'ok\n'
  jq -r '[.tree[] | select(.type == "blob") | .path | select((split("/") | last) == "charly.yml")] | .[]' <<<"$json" 2>/dev/null || true
}

# api_status <path> — the HTTP status of a GET; empty on a transport/other failure.
api_status() {
  local resp
  resp="$(gh api --include "$1" 2>&1 || true)"
  # Read the status from the FIRST line but do NOT `exit` awk: under `pipefail` a
  # response body larger than the 64 KiB pipe buffer (every charly.yml over ~64 KB —
  # measured on distro-arch, 100 KB) makes awk close the pipe while printf is still
  # writing, so printf dies with SIGPIPE (141) and the whole pipeline — hence this
  # function under `set -e` — FAILS. Letting awk consume the whole input costs nothing
  # (it prints only line 1) and keeps the function SIGPIPE-safe for any body size.
  printf '%s\n' "$resp" | awk 'NR==1 { print $2 }'
}
