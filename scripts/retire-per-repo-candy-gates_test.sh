#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT

# alpha carries the hand-rolled `name: candy` stub (must be deleted);
# beta carries no deploy.yml (must be skipped as absent);
# gamma carries a REAL gate (`name: marketplace`) at the same path (must NEVER be
# touched — this is the safety rule the path-only class of bug would break);
# delta is named `candy` but has NO `charly box validate` signature — a renamed /
# different gate that must ALSO never be touched (the content-signature guard).
printf '# Gate the candy manifest against the pinned charly.\nname: candy\nrun: charly box validate\n' >"$STATE/deploy_alpha"
printf '# Build and gate the marketplace corpus.\nname: marketplace\n'  >"$STATE/deploy_gamma"
printf 'name: candy\nrun: echo hello\n' >"$STATE/deploy_delta"
: >"$STATE/transcript"

gh() {
  if [[ "$1 $2" == "repo list" ]]; then printf 'alpha\nbeta\ngamma\ndelta\n'; return; fi
  [[ "$1" == api ]] || return 90
  shift
  local method=GET include=0 jqexpr="" path=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --method) method="$2"; shift 2 ;;
      --include) include=1; shift ;;
      --jq) jqexpr="$2"; shift 2 ;;
      *) [[ -z "$path" ]] && path="$1"; shift ;;
    esac
  done

  [[ "$path" =~ ^repos/test/(alpha|beta|gamma|delta)/contents/\.github/workflows/deploy\.yml$ ]] || return 91
  local repo="${BASH_REMATCH[1]}"
  local present=0
  [[ -f "$STATE/deploy_$repo" ]] && present=1

  if [[ "$method" == DELETE ]]; then
    if [[ "${FORCE_PERM_FAIL:-}" == 1 ]]; then
      printf 'gh: Resource not accessible by integration (HTTP 403)\n'; return 1
    fi
    if [[ "${FORCE_DELETE_FAIL:-}" == 1 ]]; then
      printf 'gh: Server Error (HTTP 500)\n'; return 1
    fi
    rm -f "$STATE/deploy_$repo"
    printf 'deleted %s\n' "$repo" >>"$STATE/transcript"
    printf 'commit\n'; return 0
  fi

  # GET (existence probe HTTP status; else the full JSON object: sha + content)
  if [[ "${FORCE_API_FAIL:-}" == 1 ]]; then
    [[ $include == 1 ]] && printf 'HTTP/2.0 500 X\r\n\r\n'
    return 1
  fi
  if [[ $present == 1 ]]; then
    if [[ $include == 1 ]]; then printf 'HTTP/2.0 200 OK\r\n\r\n'; return 0; fi
    if [[ "${FORCE_CONTENT_FAIL:-}" == 1 ]]; then
      # A malformed/empty body with no .sha — the metadata fetch must fail closed.
      printf '{"content":""}\n'; return 0
    fi
    printf '{"sha":"deadbeef","content":"%s"}\n' "$(base64 -w0 <"$STATE/deploy_$repo")"
    return 0
  fi
  [[ $include == 1 ]] && printf 'HTTP/2.0 404 Not Found\r\n\r\n'
  return 1
}
export -f gh
export STATE

# happy path: alpha retired; beta absent; gamma (a real gate) and delta (a candy-
# named gate with no validate signature) NEVER touched.
GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/retire-per-repo-candy-gates.sh" >/dev/null
grep -qx 'deleted alpha' "$STATE/transcript" || { echo "FAIL: alpha candy stub not deleted" >&2; exit 1; }
grep -q 'deleted gamma' "$STATE/transcript" && { echo "FAIL: gamma carries a real gate — must NEVER be deleted" >&2; exit 1; }
[[ -f "$STATE/deploy_gamma" ]] || { echo "FAIL: gamma's real deploy.yml was removed" >&2; exit 1; }
grep -q 'deleted delta' "$STATE/transcript" && { echo "FAIL: delta is candy-named without the validate signature — must NEVER be deleted" >&2; exit 1; }
[[ -f "$STATE/deploy_delta" ]] || { echo "FAIL: delta's differently-signatured deploy.yml was removed" >&2; exit 1; }

# idempotent: a second run deletes nothing (alpha now absent).
: >"$STATE/transcript"
GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/retire-per-repo-candy-gates.sh" >/dev/null
[[ -s "$STATE/transcript" ]] && { echo "FAIL: second run must be a no-op" >&2; exit 1; }

# a real API error must ABORT, never read as "absent".
if FORCE_API_FAIL=1 GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/retire-per-repo-candy-gates.sh" >/dev/null 2>&1; then
  echo "FAIL: must abort on a non-404 probe failure" >&2; exit 1
fi

# a delete failure must fail the run AND count the repo as failed-only — never as
# both retired and failed (the `2>&1` error text must not be read as success).
printf 'name: candy\nrun: charly box validate\n' >"$STATE/deploy_alpha"
out="$(FORCE_DELETE_FAIL=1 GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/retire-per-repo-candy-gates.sh" 2>&1)" && {
  echo "FAIL: must fail when a delete fails" >&2; exit 1; }
grep -q "retired=0 absent=1 skipped=2 failed=1" <<<"$out" \
  || { echo "FAIL: delete-failure counters must be retired=0 absent=1 skipped=2 failed=1 (got: $(grep 'retired=' <<<"$out"))" >&2; exit 1; }

# a 403 permission error (token cannot write workflow files) must ABORT immediately
# with the remediation, never churn through the remaining repos.
out="$(FORCE_PERM_FAIL=1 GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/retire-per-repo-candy-gates.sh" 2>&1)" && {
  echo "FAIL: must abort on a 403 permission error" >&2; exit 1; }
grep -q "workflows: write" <<<"$out" || { echo "FAIL: 403 abort must name the missing permission" >&2; exit 1; }

# a metadata/name-fetch failure must ABORT (fail-closed) — it must never read as
# "not the candy stub" and silently leave the stale gate in place.
printf 'name: candy\nrun: charly box validate\n' >"$STATE/deploy_alpha"
if FORCE_CONTENT_FAIL=1 GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/retire-per-repo-candy-gates.sh" >/dev/null 2>&1; then
  echo "FAIL: must abort when the deploy.yml metadata/name fetch fails" >&2; exit 1
fi

echo "retire-per-repo-candy-gates_test: all assertions passed"
