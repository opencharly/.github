#!/usr/bin/env bash
set -euo pipefail

# retire-per-repo-candy-gates.sh — delete every repo's redundant HAND-ROLLED
# `.github/workflows/deploy.yml` candy gate (`name: candy`, job `build`) in ONE
# org-wide pass, in favour of the ONE org reusable
# `.github/workflows/candy-validate.yml` (clones charly at `vars.CHARLY_VERSION`).
#
# WHY THIS EXISTS. ~376 repos carried a copy-pasted deploy.yml that CI-time-cloned
# `opencharly/charly` at a HAND-PINNED tag and ran `charly box validate`. 298 were
# frozen at `v2026.238.1242` and 16 distinct pins existed; nothing advanced them,
# so the schema-versioning-removal cutover left every version-strip PR failing its
# OWN repo CI (`schema … is required (found ""). Run: charly migrate`). The fix is
# ONE org-level source: the reusable `candy-validate.yml`, whose single knob is the
# org variable `vars.CHARLY_VERSION`. This script retires the stale per-repo copies.
#
# WHY SEPARATELY FROM scripts/org-ruleset.sh: the deletion writes to a protected
# `main`, so the commit must be authored by a ruleset BYPASS actor. It also writes
# `.github/workflows/*`, which needs GitHub Apps' `workflows: write` permission
# (distinct from `contents: write`). The `charly-auto-merge` App is the ruleset
# bypass actor, so it must ALSO hold `workflows: write`, or every delete returns 403
# "Resource not accessible by integration". This script is invoked by
# `.github/workflows/retire-per-repo-candy-gates.yml`, which mints the App token and
# exports it as `GH_TOKEN`. Shell (not inline github-script) so it is covered by the
# same offline mock-`gh` test pattern as the dispatcher-retirement precedent.
#
# SAFETY — THE ONE RULE THAT MATTERS. A `.github/workflows/deploy.yml` is deleted
# ONLY when its parsed top-level `name:` is EXACTLY `candy`. `name: marketplace`,
# `name: docs`, and every other real gate are NEVER touched — a name mismatch is
# SKIPPED, never deleted. The class this retires is the hand-rolled candy validate
# stub (verified: 376 of 378 deploy.yml files are `name: candy`; the other two are
# `marketplace` and `docs`). Matching on the parsed name, not the path, is what keeps
# a repo whose real gate happens to live at deploy.yml safe.
#
# Idempotent: an already-absent stub is skipped. A non-404 API error is FATAL — it
# must never read as "absent" and silently leave a stale gate. A 403 is a PERMISSION
# error (the token cannot write workflow files) and aborts immediately with the
# remediation, never a per-repo churn.
#
# usage: GH_TOKEN=<app with contents:write + workflows:write> $0

readonly MAX_FAILURES="${RETIRE_MAX_FAILURES:-20}"
readonly STUB_PATH=".github/workflows/deploy.yml"
readonly STUB_NAME="candy"
# The stub's content signature: every one of the 376 hand-rolled gates ran
# `charly box validate`. Requiring it (on top of the parsed name) means a
# hypothetical REAL gate that happens to be named `candy` is not swept.
readonly STUB_CMD="charly box validate"

# shellcheck source=lib-org.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-org.sh"

command -v gh >/dev/null
[[ -n "${GH_TOKEN:-}" ]] || { echo "GH_TOKEN is required (the bypass-actor App/PAT)" >&2; exit 1; }

repos_out="$(discover_repos)" || { echo "FATAL: gh repo list (targets) failed" >&2; exit 1; }
[[ -n "$repos_out" ]] || { echo "no active repositories discovered for $ORG" >&2; exit 1; }
mapfile -t repos <<<"$repos_out"

# stub_meta <repo> — print `<sha>\t<name>\t<is_stub>`, the blob SHA (the delete
# target's concurrency guard), the parsed top-level `name:`, and `1` when the file
# also carries the stub's content signature `charly box validate`.
# Returns non-zero LOUDLY on any fetch/decode failure: a transient error must never
# read as "not the candy stub" and silently leave a stale gate in place (the same
# fail-closed doctrine as `api_status`). A file with no `name:` line yields an empty
# name field, which never equals STUB_NAME (so the file is skipped, never deleted).
stub_meta() {
  local repo="$1" body text sha name is_stub
  body="$(gh api "repos/$ORG/$repo/contents/$STUB_PATH" 2>/dev/null)" || return 1
  sha="$(printf '%s' "$body" | jq -r '.sha // empty')" || return 1
  [[ -n "$sha" ]] || return 1
  text="$(printf '%s' "$body" | jq -r '.content // empty' | base64 -d 2>/dev/null)" || return 1
  name="$(printf '%s' "$text" | grep -m1 '^name:' | sed 's/^name:[[:space:]]*//' | tr -d '\r')" || true
  is_stub=0
  if grep -qF -- "$STUB_CMD" <<<"$text"; then is_stub=1; fi
  printf '%s\t%s\t%s\n' "$sha" "$name" "$is_stub"
}

deleted=0 absent=0 skipped=0 failed=0
for repo in "${repos[@]}"; do
  code="$(api_status "repos/$ORG/$repo/contents/$STUB_PATH")"
  case "$code" in
    404) absent=$((absent+1)); continue ;;
    200) ;;
    *) echo "FATAL: $repo contents probe -> HTTP $code" >&2; exit 1 ;;
  esac
  # Fetch the blob SHA + the parsed name TOGETHER, fail-closed.
  if ! meta="$(stub_meta "$repo")"; then
    echo "FATAL: $repo deploy.yml metadata fetch failed — refusing to read it as 'not the candy stub'" >&2
    exit 1
  fi
  sha="${meta%%$'\t'*}"
  rest="${meta#*$'\t'}"; name="${rest%%$'\t'*}"; is_stub="${rest#*$'\t'}"
  # SAFETY GATE: only the hand-rolled stub is ever deleted — BOTH the parsed
  # `name: candy` AND the `charly box validate` content signature must hold.
  # Anything else (a real gate, a renamed stub, a different manifest) is SKIPPED.
  if [[ "$name" != "$STUB_NAME" || "$is_stub" != 1 ]]; then
    echo "$repo: deploy.yml name='$name' stub-signature=$is_stub (not the hand-rolled candy stub) — skipped, never touched"
    skipped=$((skipped+1)); continue
  fi
  # Gate the counters on the delete's EXIT STATUS, never on `resp` being non-empty:
  # `2>&1` captures the error text on failure, so a non-empty `resp` alone would count
  # the same repo as BOTH retired and failed.
  if resp="$(gh api --method DELETE "repos/$ORG/$repo/contents/$STUB_PATH" \
      -f message="chore: retire the hand-rolled per-repo candy gate (org-wide candy-validate reusable)" \
      -f sha="$sha" -f branch=main --jq '.commit.sha' 2>&1)"; then
    echo "$repo: retired $STUB_PATH"
    deleted=$((deleted+1))
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
done
echo "retired=$deleted absent=$absent skipped=$skipped failed=$failed"
[[ "$failed" == 0 ]]
