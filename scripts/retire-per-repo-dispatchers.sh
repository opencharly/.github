#!/usr/bin/env bash
set -euo pipefail

# retire-per-repo-dispatchers.sh — delete every repo's redundant per-repo validator
# dispatcher stub, in ONE org-wide pass.
#
# WHY THIS EXISTS SEPARATELY FROM scripts/org-ruleset.sh: the deletion writes to a
# protected `main`, so the commit must be authored by a ruleset BYPASS actor. It also
# writes `.github/workflows/*`, which needs GitHub Apps' `workflows: write` permission
# (distinct from `contents: write`). The `charly-auto-merge` App is the ruleset bypass
# actor, so it must ALSO hold `workflows: write`, or every delete returns 403
# "Resource not accessible by integration". This script is invoked by
# `.github/workflows/retire-per-repo-dispatchers.yml`, which mints the App token and
# exports it as `GH_TOKEN`. It is a shell script (not inline github-script) so it is
# covered by the same offline mock-`gh` test pattern as the owner script.
#
# The org required workflow becomes the sole producer of the required
# `validate / validate` check, so every repo's stub is redundant — and while it
# remains, a PR carries TWO same-name check runs, which keeps mergeability BLOCKED
# despite PASS (the measured #38 lesson). Run this BEFORE scripts/org-ruleset.sh
# apply, which refuses while any dispatcher survives.
#
# Idempotent: an already-absent stub is skipped. A non-404 API error is FATAL — it
# must never read as "absent" and silently leave a duplicate producer. A 403 is a
# PERMISSION error (the token cannot write workflow files) and aborts immediately with
# the remediation, never a per-repo churn.
#
# usage: GH_TOKEN=<app with contents:write + workflows:write> SCOPE=targets|forks $0
#
# SCOPE=forks is the SECOND call site. A FORK must not carry a `pr-validator.yml`
# either: org ruleset B requires the org required workflow, so a surviving fork copy is a
# DUPLICATE PRODUCER of `validate / validate` (the same #38 hazard). The fork's default
# branch may be `stable`/`master`, so the deletion targets THAT branch, not `main`. The
# default scope stays `discover_repos` — widening it would delete the installed fork
# callers and re-create the deadlock.

readonly MAX_FAILURES="${RETIRE_MAX_FAILURES:-20}"

# shellcheck source=lib-org.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-org.sh"

command -v gh >/dev/null
[[ -n "${GH_TOKEN:-}" ]] || { echo "GH_TOKEN is required (the bypass-actor App/PAT)" >&2; exit 1; }

SCOPE="${SCOPE:-targets}"
case "$SCOPE" in
  targets|forks) ;;
  *) echo "SCOPE must be targets|forks" >&2; exit 2 ;;
esac

# Rows are `<name>\t<default>`: the default branch is where the file lives and the branch
# the App must write. Targets are `main` by definition; a fork may keep stable/master.
if [[ "$SCOPE" == forks ]]; then
  rows="$(discover_forks)" || { echo "FATAL: gh repo list (forks) failed" >&2; exit 1; }
  [[ -n "$rows" ]] || { echo "no active forks discovered — nothing to retire"; exit 0; }
else
  names="$(discover_repos)" || { echo "FATAL: gh repo list (targets) failed" >&2; exit 1; }
  [[ -n "$names" ]] || { echo "no active repositories discovered for $ORG" >&2; exit 1; }
  rows="$(printf '%s\n' "$names" | awk 'NF { print $0 "\tmain" }')"
fi

deleted=0 skipped=0 failed=0
while IFS=$'\t' read -r repo default; do
  [[ -z "$repo" ]] && continue
  default="${default:-main}"
  path="$(dispatcher_path_for "$repo")"
  code="$(api_status "repos/$ORG/$repo/contents/$path")"
  case "$code" in
    404) skipped=$((skipped+1)); continue ;;
    200) ;;
    *) echo "FATAL: $repo contents probe -> HTTP $code" >&2; exit 1 ;;
  esac
  # The blob SHA is the delete target's concurrency guard.
  sha="$(gh api "repos/$ORG/$repo/contents/$path" --jq .sha)"
  # Gate the counters on the delete's EXIT STATUS, never on `resp` being non-empty:
  # `2>&1` captures the error text on failure, so a non-empty `resp` alone would count
  # the same repo as BOTH retired and failed.
  if resp="$(gh api --method DELETE "repos/$ORG/$repo/contents/$path" \
      -f message="chore: retire the per-repo validator dispatcher (org-wide required workflow)" \
      -f sha="$sha" -f branch="$default" --jq '.commit.sha' 2>&1)"; then
    echo "$repo: retired $path (on $default)"; deleted=$((deleted+1))
  else
    if [[ "$resp" == *"Resource not accessible by integration"* ]]; then
      echo "FATAL: the token cannot write workflow files (403 on $repo)." >&2
      echo "The App used for this cutover must hold BOTH 'contents: write' (ruleset bypass actor)" >&2
      echo "AND 'workflows: write' (GitHub Apps permission, required by DELETE on .github/workflows/*)." >&2
      exit 1
    fi
    echo "ERROR: $repo deleteFile failed: $resp" >&2; failed=$((failed+1))
    [[ "$failed" -gt "$MAX_FAILURES" ]] && { echo "too many failures — aborting" >&2; exit 1; }
  fi
done <<<"$rows"
echo "scope=$SCOPE retired=$deleted absent=$skipped failed=$failed"
[[ "$failed" == 0 ]]
