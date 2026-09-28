#!/usr/bin/env bash
set -euo pipefail

# retire-per-repo-candy-gates.sh — delete every repo's redundant HAND-ROLLED
# `.github/workflows/deploy.yml` candy gate (`name: candy`, job `build`) in ONE
# org-wide pass, in favour of the ONE org reusable
# `.github/workflows/candy-validate.yml` (clones charly at `vars.CHARLY_VERSION`).
#
# WHY THIS EXISTS. ~376 repos carried a copy-pasted deploy.yml that CI-time-cloned
# `opencharly/charly` at a HAND-PINNED tag and ran `charly box validate`. 298 were
# frozen at `v2026.238.1242`, and 16 distinct charly pins existed (374 stubs at an inline
# `v2026.*` tag — 15 distinct tags; plugin-herdr/pod-herdr at a submodule gitlink
# `v2026.251.0841` — the 16th); nothing advanced them, so the
# schema-versioning-removal cutover left every version-strip PR failing its
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

# stub_meta <repo> — print one line `<status>\t<sha>\t<name>\t<is_stub>`:
#   status ∈ ok | vanished | failed; sha/name/is_stub are empty/0 unless ok.
#  - ok       — the blob's metadata + text were read and classified (sha is the
#               delete target's concurrency guard).
#  - vanished — the file is absent NOW (HTTP 404): it was deleted between the
#               caller's probe and this fetch, i.e. a concurrent run of this same
#               ORG-WIDE wave. This is idempotent, NOT a failure — count absent.
#  - failed   — a transient/technical fetch or decode error. Record the repo as
#               failed, NEVER delete it, NEVER abort the whole wave; the end-of-run
#               summary lists the failed repos and the script exits non-zero so it
#               is never silent.
# ALWAYS returns 0 (the caller branches on the leading status field). A file with no
# `name:` line yields an empty name, which never equals STUB_NAME (skipped, never
# deleted) — the fail-closed SAFETY gate is unchanged.
#
# A 404 here is the one case the pre-fix script could not tell apart from a real
# failure, and it aborted the entire ~300-repo wave on a single already-retired repo
# (run 36455597712: layer-camsnap's deploy.yml was deleted at 17:05:37Z by the
# concurrent run 36455573679 whose probe had raced one second ahead).
#
# The Contents API omits inline `.content` for blobs > 1 MB (returns `.encoding:
# "none"`); when the inline body decodes empty we fall back to the git blob API
# (`git/blobs/<sha>`) so a large deploy.yml is still classified, not failed.
stub_meta() {
  local repo="$1" out body text sha name is_stub blob
  if out="$(gh api "repos/$ORG/$repo/contents/$STUB_PATH" 2>&1)"; then
    body="$out"
  else
    if printf '%s' "$out" | grep -qE 'HTTP 404|"status": *"404"'; then
      printf 'vanished\t\t\t0\n'; return 0
    fi
    printf 'failed\t\t\t0\n'; return 0
  fi
  sha="$(printf '%s' "$body" | jq -r '.sha // empty' 2>/dev/null)" || sha=""
  [[ -n "$sha" ]] || { printf 'failed\t\t\t0\n'; return 0; }
  text="$(printf '%s' "$body" | jq -r '.content // empty' 2>/dev/null | base64 -d 2>/dev/null)" || text=""
  if [[ -z "$text" ]]; then
    # > 1 MB (inline content omitted) or an undecodable inline body — read the blob.
    if ! blob="$(gh api "repos/$ORG/$repo/git/blobs/$sha" 2>/dev/null)"; then
      printf 'failed\t\t\t0\n'; return 0
    fi
    text="$(printf '%s' "$blob" | jq -r '.content // empty' 2>/dev/null | base64 -d 2>/dev/null)" || text=""
  fi
  name="$(printf '%s' "$text" | grep -m1 '^name:' | sed 's/^name:[[:space:]]*//' | tr -d '\r')" || true
  is_stub=0
  if grep -qF -- "$STUB_CMD" <<<"$text"; then is_stub=1; fi
  printf 'ok\t%s\t%s\t%s\n' "$sha" "$name" "$is_stub"
}

deleted=0 absent=0 skipped=0 failed=0
declare -a failed_repos=()
for repo in "${repos[@]}"; do
  code="$(api_status "repos/$ORG/$repo/contents/$STUB_PATH")"
  case "$code" in
    404) absent=$((absent+1)); continue ;;
    200) ;;
    *) echo "FATAL: $repo contents probe -> HTTP $code" >&2; exit 1 ;;
  esac
  # Fetch the blob SHA + the parsed name TOGETHER. A `failed` status is recorded
  # per-repo and the loop CONTINUES — one repo's transient error must never abort the
  # whole org-wide wave; the summary lists it and the script exits non-zero.
  meta="$(stub_meta "$repo")"
  status="${meta%%$'\t'*}"; rest="${meta#*$'\t'}"
  if [[ "$status" == "vanished" ]]; then
    # Deleted between our probe and this fetch — a concurrent run of this same wave.
    # Idempotent: count it absent, never fail.
    echo "$repo: deploy.yml vanished between probe and fetch (already retired by a concurrent run) — counted absent"
    absent=$((absent+1)); continue
  fi
  if [[ "$status" == "failed" ]]; then
    echo "$repo: deploy.yml metadata fetch failed — SKIPPED (technical), never deleted" >&2
    failed_repos+=("$repo"); failed=$((failed+1))
    [[ "$failed" -gt "$MAX_FAILURES" ]] && { echo "too many metadata failures — aborting" >&2; exit 1; }
    continue
  fi
  sha="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  name="${rest%%$'\t'*}"; is_stub="${rest#*$'\t'}"
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
    failed_repos+=("$repo")
    [[ "$failed" -gt "$MAX_FAILURES" ]] && { echo "too many failures — aborting" >&2; exit 1; }
  fi
done
echo "retired=$deleted absent=$absent skipped=$skipped failed=$failed"
if [[ "$failed" -gt 0 ]]; then
  echo "FAILED repos (metadata or delete fetch failed — NOT deleted, re-run to retry):" >&2
  printf '  %s\n' "${failed_repos[@]}" >&2
fi
[[ "$failed" == 0 ]]
