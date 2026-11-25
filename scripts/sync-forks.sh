#!/usr/bin/env bash
set -euo pipefail

# sync-forks.sh — fast-forward a first-party fork from its upstream, with the App token.
#
# WHY THIS EXISTS. org ruleset B (scripts/org-ruleset.sh) carries the `workflows` rule in
# every fork, so its required `validate / validate` is produced by the ORG's required
# workflow — no per-fork caller is copied. That rule also blocks DIRECT PUSHES, which is
# why a USER-token `gh repo sync` fails with "Required workflow … is not satisfied"
# (measured, opencharly/.github#179). The `charly-auto-merge` App is the ruleset's ONE
# bypass actor, and its protected-main CHANGELOG writes already prove it bypasses the rule,
# so mirror sync moves here: one dotgithub-owned workflow, no per-repo file, no weakening
# of the gate.
#
# WHAT IT WILL NOT DO. It never forces: a non-fast-forward sync is REPORTED, never retried
# and never `--force`d (R3). A conflict is a real state to read, not something to paper over.
#
# usage: GH_TOKEN=<App token> [SYNC_REPOS="a,b"] $0
#   SYNC_REPOS — optional allow-list; empty = every active fork.
#
# The script prints one line per fork and exits 1 if ANY sync failed, so the workflow's
# status is the answer.

# shellcheck source=lib-org.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-org.sh"

command -v gh >/dev/null
[[ -n "${GH_TOKEN:-}" ]] || { echo "GH_TOKEN is required (the charly-auto-merge App token)" >&2; exit 1; }

rows="$(discover_forks)" || { echo "FATAL: discover_forks failed" >&2; exit 1; }
[[ -n "$rows" ]] || { echo "no active forks discovered — nothing to sync"; exit 0; }
rows="$(filter_fork_rows "$rows" "${SYNC_REPOS:-}")"
[[ -n "$rows" ]] || { echo "the SYNC_REPOS allow-list selected no fork"; exit 0; }

synced=0 failed=0
while IFS=$'\t' read -r repo default; do
  [[ -z "$repo" ]] && continue
  default="${default:-main}"

  parent="$(gh api "repos/$ORG/$repo" --jq '.parent.full_name // empty')" \
    || { echo "$repo: parent read FAILED" >&2; failed=$((failed+1)); continue; }
  [[ -n "$parent" ]] || { echo "$repo: not a fork — refusing to sync" >&2; failed=$((failed+1)); continue; }

  upstream="$(gh api "repos/$parent/branches/$default" --jq '.commit.sha' 2>/dev/null || true)"
  [[ -n "$upstream" ]] || { echo "$repo: upstream $parent has no branch '$default'" >&2; failed=$((failed+1)); continue; }

  # One call, no retry. A 409 (conflict) or any other refusal arrives as non-zero plus the
  # API's own message; it is REPORTED, never forced.
  resp="$(gh api --method POST "repos/$ORG/$repo/merge-upstream" -f branch="$default" 2>&1)" || true
  mtype="$(printf '%s' "$resp" | jq -r '.merge_type // empty' 2>/dev/null || true)"
  case "$mtype" in
    fast-forward|merge)
      head="$(gh api "repos/$ORG/$repo/branches/$default" --jq '.commit.sha')"
      if [[ "$mtype" == fast-forward ]]; then
        [[ "$head" == "$upstream" ]] \
          || { echo "$repo: read-back head $head != upstream $upstream" >&2; failed=$((failed+1)); continue; }
      else
        status="$(gh api "repos/$ORG/$repo/compare/$upstream...$head" --jq '.status')"
        [[ "$status" == ahead || "$status" == identical ]] \
          || { echo "$repo: merge landed but compare status is '$status'" >&2; failed=$((failed+1)); continue; }
      fi
      echo "$repo: synced $default ($mtype -> $head)"
      synced=$((synced+1)) ;;
    *)
      echo "$repo: NOT synced on $default — $resp" >&2
      failed=$((failed+1)) ;;
  esac
done <<<"$rows"

echo "sync-forks: synced=$synced failed=$failed"
[[ "$failed" == 0 ]]
