#!/usr/bin/env bash
set -euo pipefail

# strip-config-version.sh — delete the schema-versioning-removal cutover's retired
# authored `version:` stamp from every repo's `charly.yml` in ONE org-wide pass, with
# a MINIMAL DIFF (the rest of each file stays byte-identical).
#
# WHY THIS EXISTS. The schema-versioning-removal cutover removes the `version:`
# field from the authored config. 393 opencharly repos still carry it on `main`.
# The host leg of that removal (opencharly/charly#716) is NOT landed, so NO released
# charly accepts or needs the strip — and `charly migrate` REFORMATS the whole file:
# measured on the corpus, ~100 cosmetic lines of churn per file, including
# trailing-whitespace changes INSIDE `description:` block scalars. Across ~393 repos
# that is an unreviewable diff for a one-field removal. This script strips with a
# MINIMAL-DIFF, parser-safe line filter instead (scripts/_strip-filter.py): it deletes
# ONLY the stamp lines, leaving every other byte untouched.
#
# WHY SEPARATELY FROM scripts/org-ruleset.sh: the commit writes to a protected
# `main`, so it must be authored by a ruleset BYPASS actor. The `charly-auto-merge`
# App IS that actor (the same one the retire-per-repo-candy-gates and
# retire-per-repo-dispatchers cutovers use), so it authors the commit; the
# operator-run scripts/org-ruleset.sh deliberately adds NO human bypass to the ruleset
# (that would loosen main protection). Unlike those cutovers this writes `charly.yml`
# (NOT `.github/workflows/*`), so it needs the App's `contents: write` bypass — not the
# separate `workflows: write` GitHub Apps permission. This script is invoked by
# `.github/workflows/strip-config-version.yml`, which mints the App token and exports
# it as `GH_TOKEN`. Shell (not inline github-script) so it is covered by the same
# offline mock-`gh` test pattern as the retire-per-repo-candy-gates precedent.
#
# SAFETY — THE ONE RULE THAT MATTERS. A line is deleted ONLY when its content matches
# `^ {0,8}version:` (indent 0..8, then `version:`, optionally with a trailing
# `  # comment`). That is exactly the document stamp (indent 0) and an entity-body
# stamp (indent 8, and indent 4 in the two 2-space manifests). A `version:` line
# INDENTED 16 OR MORE is a fenced YAML example INSIDE a `description: |` block scalar
# and is PRESERVED — deleting it would corrupt documentation (measured: 9 repos, e.g.
# layer-charly-hermes's `                version: 2026.156.1921   # mandatory CalVer`,
# which MUST survive). The filter additionally keeps block-scalar context and REFUSES
# LOUDLY (never silently mis-strips) if a matched line ever appears inside such a
# scalar. The rest of the file is byte-identical.
#
# Idempotent: a file with no strippable line is counted `skipped`, never written. A
# file with no `charly.yml` is counted `absent`. A non-404 probe error is FATAL — it
# must never read as "absent" and silently leave a stamp behind. One repo's transient
# fetch/put failure is counted `failed` and the wave CONTINUES (the #142 lesson: one
# repo must never abort the whole org wave); the summary lists the failed repos and
# the script exits non-zero so it is never silent. A 403 "Resource not accessible by
# integration" is a PERMISSION error and aborts immediately with the remediation,
# never a per-repo churn.
#
# DRY RUN. Set DRY_RUN=1 to fetch + filter + report what WOULD change, WITHOUT
# committing anything. Pass repo names as arguments to restrict the wave.
#
# usage: GH_TOKEN=<app with contents:write> $0 [<repo> ...]
#        DRY_RUN=1 GH_TOKEN=... $0 layer-charly-hermes pod-wayvnc ...

readonly MAX_FAILURES="${STRIP_MAX_FAILURES:-20}"
readonly CONFIG_PATH="charly.yml"
readonly COMMIT_MESSAGE="chore(schema): drop the retired config version: stamp (org-wide cutover)"
readonly FILTER="$(dirname "${BASH_SOURCE[0]}")/_strip-filter.py"

# shellcheck source=lib-org.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-org.sh"

command -v gh >/dev/null
command -v jq >/dev/null
command -v python3 >/dev/null
[[ -x "$FILTER" || -f "$FILTER" ]] || { echo "FATAL: filter not found: $FILTER" >&2; exit 1; }
[[ -n "${GH_TOKEN:-}" ]] || { echo "GH_TOKEN is required (the bypass-actor App/PAT)" >&2; exit 1; }

DRY_RUN="${DRY_RUN:-0}"

if [[ $# -gt 0 ]]; then
  repos=("$@")
else
  repos_out="$(discover_repos)" || { echo "FATAL: gh repo list (targets) failed" >&2; exit 1; }
  [[ -n "$repos_out" ]] || { echo "no active repositories discovered for $ORG" >&2; exit 1; }
  mapfile -t repos <<<"$repos_out"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# fetch_config <repo> <outfile> — write the DECODED charly.yml to <outfile> (byte
# exact, including the trailing newline) and print one line `<status>\t<sha>`:
#   status ∈ ok | vanished | failed; sha is empty unless ok.
#  - ok       — the blob's text was read (sha is the PUT's concurrency guard).
#  - vanished — the file is absent NOW (HTTP 404): deleted between the caller's probe
#               and this fetch, i.e. a concurrent run of this same ORG-WIDE wave.
#               Idempotent, NOT a failure — count absent.
#  - failed   — a transient/technical fetch or decode error. Record the repo as
#               failed, NEVER write it, NEVER abort the whole wave.
# ALWAYS returns 0 (the caller branches on the leading status field).
#
# The Contents API omits inline `.content` for blobs > 1 MB (returns `.encoding:
# "none"`) — measured live: layer-charly-internals/charly.yml is 1,038,418 bytes, so
# its base64 body exceeds 1 MB. When the inline body decodes empty we fall back to the
# git blob API (`git/blobs/<sha>`) so a large charly.yml is still filtered, not failed.
fetch_config() {
  local repo="$1" out="$2" json sha b64 blob
  : > "$out"  # never leave a prior repo's bytes to be mistaken for this one's
  if json="$(gh api "repos/$ORG/$repo/contents/$CONFIG_PATH" 2>&1)"; then :; else
    if printf '%s' "$json" | grep -qE 'HTTP 404|"status": *"404"'; then
      printf 'vanished\t\n'; return 0
    fi
    printf 'failed\t\n'; return 0
  fi
  sha="$(printf '%s' "$json" | jq -r '.sha // empty' 2>/dev/null)" || sha=""
  [[ -n "$sha" ]] || { printf 'failed\t\n'; return 0; }
  b64="$(printf '%s' "$json" | jq -r '.content // empty' 2>/dev/null)" || b64=""
  if [[ -n "$b64" ]] && printf '%s' "$b64" | base64 -d > "$out" 2>/dev/null && [[ -s "$out" ]]; then
    printf 'ok\t%s\n' "$sha"; return 0
  fi
  # Inline content absent (> 1 MB) or undecodable — read the git blob instead.
  if ! blob="$(gh api "repos/$ORG/$repo/git/blobs/$sha" 2>/dev/null)"; then
    printf 'failed\t\n'; return 0
  fi
  b64="$(printf '%s' "$blob" | jq -r '.content // empty' 2>/dev/null)" || b64=""
  if [[ -n "$b64" ]] && printf '%s' "$b64" | base64 -d > "$out" 2>/dev/null && [[ -s "$out" ]]; then
    printf 'ok\t%s\n' "$sha"; return 0
  fi
  printf 'failed\t\n'
}

stripped=0 absent=0 skipped=0 failed=0
declare -a failed_repos=()
for repo in "${repos[@]}"; do
  code="$(api_status "repos/$ORG/$repo/contents/$CONFIG_PATH")"
  case "$code" in
    404) absent=$((absent+1)); continue ;;
    200) ;;
    *) echo "FATAL: $repo contents probe -> HTTP $code" >&2; exit 1 ;;
  esac

  text="$TMP/orig"; new="$TMP/new"; report="$TMP/report"
  meta="$(fetch_config "$repo" "$text")"
  status="${meta%%$'\t'*}"; sha="${meta#*$'\t'}"
  if [[ "$status" == "vanished" ]]; then
    echo "$repo: charly.yml vanished between probe and fetch (already handled by a concurrent run) — counted absent"
    absent=$((absent+1)); continue
  fi
  if [[ "$status" == "failed" ]]; then
    echo "$repo: charly.yml fetch failed — SKIPPED (technical), never written" >&2
    failed_repos+=("$repo"); failed=$((failed+1))
    [[ "$failed" -gt "$MAX_FAILURES" ]] && { echo "too many failures — aborting" >&2; exit 1; }
    continue
  fi

  # Filter: stdout = the stripped file, stderr = STRIPPED <n> | ABSENT | NOT_UTF8 |
  # REFUSED:.... A REFUSED/NOT_UTF8 is a hard per-repo failure (never a silent skip).
  if ! python3 "$FILTER" < "$text" > "$new" 2> "$report"; then
    echo "$repo: charly.yml filter refused/failed ($(tr -d '\n' < "$report")) — SKIPPED (technical), never written" >&2
    failed_repos+=("$repo"); failed=$((failed+1))
    [[ "$failed" -gt "$MAX_FAILURES" ]] && { echo "too many failures — aborting" >&2; exit 1; }
    continue
  fi
  if [[ "$(cat "$report")" == "ABSENT" ]]; then
    # No strippable stamp (already clean, or none ever) — never written.
    skipped=$((skipped+1)); continue
  fi

  if [[ "$DRY_RUN" == 1 ]]; then
    echo "$repo: WOULD strip from $CONFIG_PATH ($(cat "$report")):"
    diff --old-line-format='  -%L' --new-line-format='  +%L' --unchanged-line-format='' "$text" "$new" || true
    stripped=$((stripped+1)); continue
  fi

  # Build the PUT body with `jq -Rs` (raw-slurp the base64 from stdin) and feed it via
  # `--input -`: the base64 never touches argv, which would blow the OS ARG_MAX on a
  # > 1 MB content field (layer-charly-internals/charly.yml is 1,038,418 bytes → a
  # 1.39 MB base64). `-Rs` keeps the base64 byte-exact (no trailing newline).
  base64 -w0 < "$new" > "$TMP/b64" || { echo "ERROR: $repo base64 encode failed" >&2; failed_repos+=("$repo"); failed=$((failed+1)); continue; }
  # Gate the counter on the PUT's EXIT STATUS, never on `resp` being non-empty: `2>&1`
  # captures error text on failure, so a non-empty `resp` alone would double-count.
  if resp="$(jq -Rs --arg message "$COMMIT_MESSAGE" --arg sha "$sha" \
        '{message:$message, content:., sha:$sha, branch:"main"}' < "$TMP/b64" \
        | gh api --method PUT "repos/$ORG/$repo/contents/$CONFIG_PATH" --input - --jq '.commit.sha' 2>&1)"; then
    echo "$repo: stripped $CONFIG_PATH ($(cat "$report"))"
    stripped=$((stripped+1))
  else
    if [[ "$resp" == *"Resource not accessible by integration"* ]]; then
      echo "FATAL: the token cannot write charly.yml (403 on $repo): $resp" >&2
      echo "The App used for this cutover must hold 'contents: write' — the ruleset bypass" >&2
      echo "actor's permission for a commit to protected main. (The same charly-auto-merge" >&2
      echo "App also holds 'workflows: write' from the retire-per-repo-candy-gates cutover;" >&2
      echo "charly.yml is not a workflow file, so 'contents: write' alone is what this write needs.)" >&2
      exit 1
    fi
    echo "ERROR: $repo updateFile failed: $resp" >&2
    failed_repos+=("$repo"); failed=$((failed+1))
    [[ "$failed" -gt "$MAX_FAILURES" ]] && { echo "too many failures — aborting" >&2; exit 1; }
  fi
done

if [[ "$DRY_RUN" == 1 ]]; then
  echo "DRY_RUN: would_strip=$stripped absent=$absent skipped=$skipped failed=$failed"
else
  echo "stripped=$stripped absent=$absent skipped=$skipped failed=$failed"
fi
if [[ "$failed" -gt 0 ]]; then
  echo "FAILED repos (fetch/filter/write failed — NOT written, re-run to retry):" >&2
  printf '  %s\n' "${failed_repos[@]}" >&2
fi
[[ "$failed" == 0 ]]
